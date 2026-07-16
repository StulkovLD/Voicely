@preconcurrency import AVFoundation
import CoreML
import Foundation

/// Charwise CTC greedy decode: argmax labels per frame, collapse repeats,
/// drop blanks, join vocab characters. The vocab has no word-piece markers —
/// the space character is an ordinary vocab entry.
enum GigaAMCTCDecoder {
    static func decode(frameLabels: [Int], vocab: [String], blankID: Int) -> String {
        var pieces: [String] = []
        var previous = -1
        for label in frameLabels {
            if label != previous, label != blankID, label >= 0, label < vocab.count {
                pieces.append(vocab[label])
            }
            previous = label
        }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GigaAMCTCModelInfo: Decodable {
    let numClasses: Int
    let blankID: Int
    let vocabSize: Int
    let languages: [String]
    let melNFFT: Int
    let melWinLength: Int
    let melHopLength: Int
    let subsamplingFactor: Int

    private enum CodingKeys: String, CodingKey {
        case numClasses = "num_classes"
        case blankID = "blank_id"
        case vocabSize = "vocab_size"
        case languages
        case melNFFT = "mel_n_fft"
        case melWinLength = "mel_win_length"
        case melHopLength = "mel_hop_length"
        case subsamplingFactor = "subsampling_factor"
    }
}

private struct GigaAMCTCConvertInfo: Decodable {
    let windowSec: Int
    let melFrames: Int
    let encFrames: Int

    private enum CodingKeys: String, CodingKey {
        case windowSec = "window_sec"
        case melFrames = "mel_frames"
        case encFrames = "enc_frames"
    }
}

/// See GigaAMRuntime for the publication invariant: the model is published
/// once under the state lock and only one transcription runs at a time.
private struct GigaAMCTCRuntime: @unchecked Sendable {
    let model: MLModel
    let vocab: [String]
    let info: GigaAMCTCModelInfo
    let convert: GigaAMCTCConvertInfo
}

private enum GigaAMCTCConstants {
    static let computeUnits: MLComputeUnits = .cpuAndGPU
    static let windowSamples = 30 * 16000
    static let minNonSilentRMS: Float = 0.005
    static let packageName = "GigaAMMultilingualCTC.mlpackage"
    /// A tail shorter than one mel window (20 ms) yields no frames; feeding it
    /// to the front-end would abort the whole transcription instead.
    static let minTailSamples = 320
}

final class GigaAMCTCEngine: @unchecked Sendable, TranscriberEngine, SampleTranscribing, PreloadableTranscriberEngine, CancelableTranscriberEngine, DownloadReportingTranscriberEngine, LanguageSessionResettable {
    private let model: WhisperModel
    private let onProgress: (@Sendable (TranscriberStatus) -> Void)?
    private let punctuator: PunctuationRestorer?
    private let stateLock = NSLock()
    private let requestCancellation = GigaAMRequestCancellation()

    private var runtime: GigaAMCTCRuntime?
    private var isLoading = false
    private var isDownloadInProgress = false
    private var isTranscribing = false
    private var activeLoadTask: Task<GigaAMCTCRuntime, Error>?

    var isCurrentlyDownloading: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isDownloadInProgress
    }

    init(
        model: WhisperModel,
        onProgress: (@Sendable (TranscriberStatus) -> Void)? = nil,
        punctuator: PunctuationRestorer? = nil
    ) {
        self.model = model
        self.onProgress = onProgress
        self.punctuator = punctuator
    }

    func preload() async throws {
        try GigaAMPlatformReadiness.requireSupported()
        let token = requestCancellation.begin()
        _ = try await ensureRuntimeLoaded(cancellationToken: token)
    }

    func cancel() {
        let loadTask: Task<GigaAMCTCRuntime, Error>?
        requestCancellation.cancelCurrentRequests()
        stateLock.lock()
        isDownloadInProgress = false
        loadTask = activeLoadTask
        stateLock.unlock()
        loadTask?.cancel()
        vlog("GigaAM CTC: cancel requested")
    }

    func resetLanguageSession() {
        // The multilingual CTC model transcribes whatever language it hears;
        // there is no detect-then-latch session state to clear.
    }

    func transcribe(audio: AVAudioPCMBuffer, translate: Bool = false, language: String? = nil) async throws -> String {
        let normalized = try GigaAMDSP.normalizeTo16kMono(audio)
        guard let channelData = normalized.floatChannelData?[0] else {
            throw TranscriberError.whisperKitFailed("No audio data in buffer")
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(normalized.frameLength)))
        let result = try await transcribeSamples(samples, translate: translate, language: language)
        return result.text
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        try validateRequest(translate: translate, language: language)
        let alreadyTranscribing = trySetTranscribing(true)
        guard !alreadyTranscribing else { throw TranscriberError.engineBusy }
        defer { _ = trySetTranscribing(false) }
        let cancellationToken = requestCancellation.begin()

        guard !samples.isEmpty else { throw TranscriberError.recordingTooShort }
        let rms = GigaAMDSP.peakWindowRMS(samples)
        if rms < GigaAMCTCConstants.minNonSilentRMS {
            throw TranscriberError.silentAudio
        }

        var allSegments: [WhisperSegment] = []
        var cursor = 0
        let chunkSize = GigaAMCTCConstants.windowSamples
        while cursor < samples.count {
            try checkCancellation(cancellationToken)
            let end = min(cursor + chunkSize, samples.count)
            if end - cursor < GigaAMCTCConstants.minTailSamples, !allSegments.isEmpty {
                break
            }
            let chunk = Array(samples[cursor..<end])
            let offsetSec = Double(cursor) / 16000.0
            let chunkResult = try await transcribeSingleWindow(
                chunk,
                offsetSec: offsetSec,
                cancellationToken: cancellationToken
            )
            allSegments.append(contentsOf: chunkResult.segments)
            cursor = end
        }

        let text = allSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = Self.dominantScriptLanguage(text)

        // GigaAM Multilingual emits lowercase without punctuation; restore it
        // when a punctuator is wired. Never let this fail transcription.
        guard let punctuator, !text.isEmpty else {
            return WhisperTranscription(text: text, segments: allSegments, detectedLanguage: language)
        }
        let restoredText = (try? await punctuator.restore(text, language: language)) ?? text
        let restoredSegments = try await restoreSegments(allSegments, punctuator: punctuator, language: language)
        return WhisperTranscription(text: restoredText, segments: restoredSegments, detectedLanguage: language)
    }

    /// Punctuate each segment independently so timestamped file/call transcripts
    /// carry punctuation too. Per-segment context is smaller than the whole
    /// text, which is acceptable for dictation-length windows.
    private func restoreSegments(
        _ segments: [WhisperSegment],
        punctuator: PunctuationRestorer,
        language: String?
    ) async throws -> [WhisperSegment] {
        guard segments.count > 1 else {
            guard let only = segments.first, !only.text.isEmpty else { return segments }
            let restored = (try? await punctuator.restore(only.text, language: language)) ?? only.text
            return [WhisperSegment(start: only.start, end: only.end, text: restored)]
        }
        var out: [WhisperSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            let restored = seg.text.isEmpty ? seg.text
                : ((try? await punctuator.restore(seg.text, language: language)) ?? seg.text)
            out.append(WhisperSegment(start: seg.start, end: seg.end, text: restored))
        }
        return out
    }

    /// Script-based language attribution: the charwise model has no language
    /// output, but the emitted alphabet identifies the script reliably.
    /// Central-Asian Cyrillic extensions map to kk/ky/uz ambiguously, so they
    /// return nil rather than a guess.
    static func dominantScriptLanguage(_ text: String) -> String? {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            switch scalar {
            case "a"..."z":
                latin += 1
            case "\u{0456}", "\u{0493}", "\u{049B}", "\u{04A3}", "\u{04AF}",
                 "\u{04B1}", "\u{04BB}", "\u{04D9}", "\u{04E9}":
                // і ғ қ ң ү ұ һ ә ө — kk/ky/uz cannot be told apart.
                return nil
            case "\u{0430}"..."\u{044F}", "\u{0451}":
                cyrillic += 1
            default:
                break
            }
        }
        if cyrillic > latin { return "ru" }
        if latin > cyrillic { return "en" }
        return nil
    }

    private func transcribeSingleWindow(
        _ samples: [Float],
        offsetSec: Double,
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> WhisperTranscription {
        let runtime = try await ensureRuntimeLoaded(cancellationToken: cancellationToken)
        try checkCancellation(cancellationToken)

        let durationSec = Double(samples.count) / 16000.0
        guard durationSec > 0 else { return WhisperTranscription(text: "", segments: [], detectedLanguage: nil) }

        let (features, trueFrames) = try GigaAMDSP.makeFeatures(
            from: samples,
            melNFFT: runtime.info.melNFFT,
            melWinLength: runtime.info.melWinLength,
            melHopLength: runtime.info.melHopLength,
            melFrames: runtime.convert.melFrames,
            windowSamples: GigaAMCTCConstants.windowSamples
        )
        try checkCancellation(cancellationToken)

        let output = try await runtime.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": features,
            "length": try GigaAMDSP.makeInt32Array(shape: [1], values: [Int32(trueFrames)])
        ]))
        guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue else {
            throw TranscriberError.whisperKitFailed("GigaAM CTC output missing")
        }

        // The exporter cannot compute the valid encoder length in fp16, so the
        // caller derives it with integer math from the true mel frame count.
        // (trueFrames - 1) / factor + 1 matches the encoder's own output
        // length, verified empirically across boundary values against the
        // PyTorch reference.
        let encLen = max(0, min(
            runtime.convert.encFrames,
            (trueFrames - 1) / runtime.info.subsamplingFactor + 1
        ))
        if encLen == 0 {
            return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
        }

        var frameLabels: [Int] = []
        frameLabels.reserveCapacity(encLen)
        for frame in 0..<encLen {
            var bestIndex = 0
            var bestValue = -Float.infinity
            for cls in 0..<runtime.info.numClasses {
                let value = logProbs.float(at: [0, frame, cls])
                if value > bestValue {
                    bestValue = value
                    bestIndex = cls
                }
            }
            frameLabels.append(bestIndex)
        }

        let text = GigaAMCTCDecoder.decode(
            frameLabels: frameLabels,
            vocab: runtime.vocab,
            blankID: runtime.info.blankID
        )
        guard !text.isEmpty, !Transcriber.isHallucinationText(text) else {
            return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
        }
        let segment = WhisperSegment(start: offsetSec, end: offsetSec + durationSec, text: text)
        return WhisperTranscription(text: text, segments: [segment], detectedLanguage: nil)
    }

    private func validateRequest(translate: Bool, language: String?) throws {
        let normalizedLanguage = (language?.isEmpty == true) ? nil : language
        if model.requestValidationError(
            translateToEnglish: translate,
            language: normalizedLanguage
        ) != nil {
            throw TranscriberError.notAvailable
        }
    }

    private func ensureRuntimeLoaded(
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> GigaAMCTCRuntime {
        try GigaAMPlatformReadiness.requireSupported()
        try checkCancellation(cancellationToken)
        if let runtime = currentRuntime() { return runtime }
        if tryStartLoading() {
            let task = Task {
                try await Self.loadRuntime(
                    model: model,
                    onProgress: onProgress,
                    engine: self,
                    cancellationToken: cancellationToken
                )
            }
            setActiveLoadTask(task, cancellationToken: cancellationToken)
            do {
                let runtime = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try checkCancellation(cancellationToken)
                finishLoading(runtime, cancellationToken: cancellationToken)
            } catch {
                finishLoading(nil, cancellationToken: cancellationToken)
                throw error
            }
        } else {
            var waited: UInt64 = 0
            let maxWait: UInt64 = 300_000_000_000
            while currentRuntime() == nil && isLoadInProgress() && waited < maxWait {
                try await Task.sleep(nanoseconds: 100_000_000)
                waited += 100_000_000
                try checkCancellation(cancellationToken)
            }
            if currentRuntime() == nil && !isLoadInProgress() {
                // The loader this request observed may belong to an older,
                // cancelled epoch. The current request becomes the next loader
                // instead of inheriting modelNotReady from that operation.
                try checkCancellation(cancellationToken)
                return try await ensureRuntimeLoaded(
                    cancellationToken: cancellationToken
                )
            }
        }
        guard let runtime = currentRuntime() else {
            throw TranscriberError.modelNotReady
        }
        return runtime
    }

    private func currentRuntime() -> GigaAMCTCRuntime? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtime
    }

    private func isLoadInProgress() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLoading
    }

    private func tryStartLoading() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard runtime == nil, !isLoading else { return false }
        isLoading = true
        return true
    }

    private func setActiveLoadTask(
        _ task: Task<GigaAMCTCRuntime, Error>,
        cancellationToken: GigaAMRequestCancellation.Token
    ) {
        stateLock.lock()
        activeLoadTask = task
        stateLock.unlock()
        if !requestCancellation.isCurrent(cancellationToken) { task.cancel() }
    }

    private func finishLoading(
        _ runtime: GigaAMCTCRuntime?,
        cancellationToken: GigaAMRequestCancellation.Token
    ) {
        let mayPublish = requestCancellation.isCurrent(cancellationToken)
        stateLock.lock()
        if mayPublish {
            self.runtime = runtime
        }
        isLoading = false
        isDownloadInProgress = false
        activeLoadTask = nil
        stateLock.unlock()
    }

    private func setDownloading(_ value: Bool) {
        stateLock.lock()
        isDownloadInProgress = value
        stateLock.unlock()
    }

    private func trySetTranscribing(_ value: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let was = isTranscribing
        isTranscribing = value
        return was
    }

    private func checkCancellation(_ token: GigaAMRequestCancellation.Token) throws {
        try requestCancellation.check(token)
    }

    private static func loadRuntime(
        model: WhisperModel,
        onProgress: (@Sendable (TranscriberStatus) -> Void)?,
        engine: GigaAMCTCEngine,
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> GigaAMCTCRuntime {
        try GigaAMPlatformReadiness.requireSupported()
        try engine.checkCancellation(cancellationToken)

        let root = model.modelDirectory
        let sourceRoot = root.appendingPathComponent("source")
        let compiledRoot = root.appendingPathComponent("compiled")
        let fileSystem = FoundationGigaAMAssetFileSystem()
        try fileSystem.createPrivateDirectory(at: root)
        try GigaAMSecureStorage.requireDirectory(root)
        let interprocessLock = try GigaAMInterprocessLock(modelRoot: root)
        defer { withExtendedLifetime(interprocessLock) {} }
        try engine.checkCancellation(cancellationToken)
        try fileSystem.createPrivateDirectory(at: sourceRoot)
        let preflightCompiledCacheReady = GigaAMCompiledCache.isReady(
            compiledRoot: compiledRoot,
            policy: .multilingualCTC
        )

        let downloader = GigaAMAssetDownloader(
            assets: GigaAMMultilingualAssetCatalog.assets,
            revision: GigaAMMultilingualAssetCatalog.revision,
            fileSystem: fileSystem,
            resolveURL: { GigaAMMultilingualAssetCatalog.resolveURL(for: $0) }
        )
        let installResult: GigaAMAssetInstallResult
        engine.setDownloading(true)
        do {
            installResult = try await downloader.ensureAssets(
                in: sourceRoot,
                additionalRequiredBytes: preflightCompiledCacheReady
                    ? 0
                    : GigaAMMultilingualAssetCatalog.totalExpectedByteCount
            ) { completed, total in
                let progress = total > 0 ? Double(completed) / Double(total) : 1
                onProgress?(.downloadingModel(progress: min(0.95, progress)))
            }
            engine.setDownloading(false)
        } catch {
            engine.setDownloading(false)
            throw error
        }
        try engine.checkCancellation(cancellationToken)
        try GigaAMSecureStorage.hardenTree(at: sourceRoot)

        _ = installResult
        // ensureAssets never touches compiledRoot and the interprocess lock is
        // held throughout, so the preflight answer is still valid — re-hashing
        // the ~440 MB compiled tree here would add seconds for no information.
        let mustRebuildCompiledCache = !preflightCompiledCacheReady

        if mustRebuildCompiledCache {
            if FileManager.default.fileExists(atPath: compiledRoot.path)
                || (try? FileManager.default.attributesOfItem(atPath: compiledRoot.path)) != nil {
                try FileManager.default.removeItem(at: compiledRoot)
            }
        }
        try fileSystem.createPrivateDirectory(at: compiledRoot)
        onProgress?(.loadingModel)

        let decoder = JSONDecoder()
        let vocab = try decoder.decode([String].self, from: Data(contentsOf: sourceRoot.appendingPathComponent("tokens.json")))
        let info = try decoder.decode(GigaAMCTCModelInfo.self, from: Data(contentsOf: sourceRoot.appendingPathComponent("model_info.json")))
        let convert = try decoder.decode(GigaAMCTCConvertInfo.self, from: Data(contentsOf: sourceRoot.appendingPathComponent("convert_info.json")))
        guard vocab.count == info.vocabSize, info.blankID == info.numClasses - 1 else {
            throw GigaAMAssetDownloadError.insecureTopology(sourceRoot.path)
        }

        let config = MLModelConfiguration()
        config.computeUnits = GigaAMCTCConstants.computeUnits
        let compiledURL = compiledRoot.appendingPathComponent("GigaAMMultilingualCTC.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            guard mustRebuildCompiledCache else {
                throw GigaAMAssetDownloadError.insecureTopology(compiledURL.path)
            }
            let temporaryCompiledURL = try await MLModel.compileModel(
                at: sourceRoot.appendingPathComponent(GigaAMCTCConstants.packageName)
            )
            if FileManager.default.fileExists(atPath: compiledURL.path) {
                try? FileManager.default.removeItem(at: compiledURL)
            }
            try FileManager.default.moveItem(at: temporaryCompiledURL, to: compiledURL)
        }
        let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
        try engine.checkCancellation(cancellationToken)
        if mustRebuildCompiledCache {
            // seal validates the fresh tree internally; the preflight already
            // validated the reused one.
            try GigaAMCompiledCache.seal(compiledRoot: compiledRoot, policy: .multilingualCTC)
        }
        return GigaAMCTCRuntime(model: mlModel, vocab: vocab, info: info, convert: convert)
    }
}
