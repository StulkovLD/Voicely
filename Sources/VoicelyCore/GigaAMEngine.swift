@preconcurrency import AVFoundation
import Accelerate
import CoreML
import Foundation

struct GigaAMTokenDecoder {
    static func decode(tokenIDs: [Int], pieces: [String]) -> String {
        let raw = tokenIDs.compactMap { id in
            guard id >= 0, id < pieces.count else { return nil }
            return pieces[id]
        }.joined()
        return normalize(raw)
    }

    private static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var text = raw.replacingOccurrences(of: "▁", with: " ")
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([«(\[])[ ]+"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([»)\]])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GigaAMModelInfo: Decodable {
    let numClasses: Int
    let blankID: Int
    let predHidden: Int
    let predRnnLayers: Int
    let encHidden: Int
    let vocabSize: Int
    let charwise: Bool
    let melNFFT: Int
    let melWinLength: Int
    let melHopLength: Int
    let melCenter: Bool

    private enum CodingKeys: String, CodingKey {
        case numClasses = "num_classes"
        case blankID = "blank_id"
        case predHidden = "pred_hidden"
        case predRnnLayers = "pred_rnn_layers"
        case encHidden = "enc_hidden"
        case vocabSize = "vocab_size"
        case charwise
        case melNFFT = "mel_n_fft"
        case melWinLength = "mel_win_length"
        case melHopLength = "mel_hop_length"
        case melCenter = "mel_center"
    }
}

private struct GigaAMConvertInfo: Decodable {
    let windowSec: Int
    let melFrames: Int

    private enum CodingKeys: String, CodingKey {
        case windowSec = "window_sec"
        case melFrames = "mel_frames"
    }
}

/// Core ML model instances are published once after loading and never mutated.
/// GigaAMEngine serializes runtime publication and admits one transcription at
/// a time, so crossing the loader Task boundary cannot create concurrent model
/// mutation. Keep this invariant if runtime ownership changes.
private struct GigaAMRuntime: @unchecked Sendable {
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    let pieces: [String]
    let info: GigaAMModelInfo
    let convert: GigaAMConvertInfo
}

private enum GigaAMConstants {
    static let supportedLanguage = "ru"
    static let maxSymbolsPerFrame = 10
    static let computeUnits: MLComputeUnits = .cpuAndGPU
    static let windowSamples = 30 * 16000
    static let minNonSilentRMS: Float = 0.005
    /// A tail shorter than one mel window (20 ms) yields no frames; feeding it
    /// to the front-end would abort the whole transcription instead.
    static let minTailSamples = 320
}

/// A cancellation epoch invalidates work already in flight without poisoning
/// the next request. Tokens are request-scoped and never reset globally.
final class GigaAMRequestCancellation: @unchecked Sendable {
    typealias Token = UInt64

    private let lock = NSLock()
    private var epoch: Token = 0

    func begin() -> Token {
        lock.withLock { epoch }
    }

    func cancelCurrentRequests() {
        lock.withLock { epoch &+= 1 }
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.withLock { epoch == token }
    }

    func check(_ token: Token) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }
}

final class GigaAMEngine: @unchecked Sendable, TranscriberEngine, SampleTranscribing, PreloadableTranscriberEngine, CancelableTranscriberEngine, DownloadReportingTranscriberEngine, LanguageSessionResettable {
    private let model: WhisperModel
    private let onProgress: (@Sendable (TranscriberStatus) -> Void)?
    private let stateLock = NSLock()
    private let requestCancellation = GigaAMRequestCancellation()

    private var runtime: GigaAMRuntime?
    private var isLoading = false
    private var isDownloadInProgress = false
    private var isTranscribing = false
    private var activeLoadTask: Task<GigaAMRuntime, Error>?

    var isCurrentlyDownloading: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isDownloadInProgress
    }

    init(model: WhisperModel, onProgress: (@Sendable (TranscriberStatus) -> Void)? = nil) {
        self.model = model
        self.onProgress = onProgress
    }

    func preload() async throws {
        try GigaAMPlatformReadiness.requireSupported()
        let token = requestCancellation.begin()
        _ = try await ensureRuntimeLoaded(cancellationToken: token)
    }

    func cancel() {
        let loadTask: Task<GigaAMRuntime, Error>?
        requestCancellation.cancelCurrentRequests()
        stateLock.lock()
        isDownloadInProgress = false
        loadTask = activeLoadTask
        stateLock.unlock()
        loadTask?.cancel()
        vlog("GigaAM: cancel requested")
    }

    func resetLanguageSession() {
        // GigaAM v3 e2e RNNT is Russian-only in this integration path, so there
        // is no detect-then-latch session state to clear.
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
        if rms < GigaAMConstants.minNonSilentRMS {
            throw TranscriberError.silentAudio
        }

        var allSegments: [WhisperSegment] = []
        var cursor = 0
        let chunkSize = GigaAMConstants.windowSamples
        while cursor < samples.count {
            try checkCancellation(cancellationToken)
            let end = min(cursor + chunkSize, samples.count)
            if end - cursor < GigaAMConstants.minTailSamples, !allSegments.isEmpty {
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
        return WhisperTranscription(text: text, segments: allSegments, detectedLanguage: text.isEmpty ? nil : GigaAMConstants.supportedLanguage)
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
            windowSamples: GigaAMConstants.windowSamples
        )
        try checkCancellation(cancellationToken)

        let encodedOut = try await runtime.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": features,
            "length": try GigaAMDSP.makeInt32Array(shape: [1], values: [Int32(trueFrames)])
        ]))
        guard let encoded = encodedOut.featureValue(for: "encoded")?.multiArrayValue,
              let encodedLenArray = encodedOut.featureValue(for: "encoded_len")?.multiArrayValue else {
            throw TranscriberError.whisperKitFailed("GigaAM encoder outputs missing")
        }
        let encodedLen = max(0, min(runtime.convert.melFrames / 4 + 1, encodedLenArray.intValue(at: [0])))
        if encodedLen == 0 {
            return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
        }

        var emitted: [Int] = []
        var h = [Float](repeating: 0, count: runtime.info.predHidden)
        var c = [Float](repeating: 0, count: runtime.info.predHidden)
        var lastToken = runtime.info.blankID

        for frame in 0..<encodedLen {
            try checkCancellation(cancellationToken)
            let encT = Self.extractFrame(encoded, frame: frame, hiddenSize: runtime.info.encHidden)
            for _ in 0..<GigaAMConstants.maxSymbolsPerFrame {
                let decoderOut = try await runtime.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "token": try GigaAMDSP.makeInt32Array(shape: [1, 1], values: [Int32(lastToken)]),
                    "h_in": try GigaAMDSP.makeFloat32Array(shape: [1, 1, runtime.info.predHidden], values: h),
                    "c_in": try GigaAMDSP.makeFloat32Array(shape: [1, 1, runtime.info.predHidden], values: c)
                ]))
                guard let decOut = decoderOut.featureValue(for: "dec_out")?.multiArrayValue,
                      let hOut = decoderOut.featureValue(for: "h_out")?.multiArrayValue,
                      let cOut = decoderOut.featureValue(for: "c_out")?.multiArrayValue else {
                    throw TranscriberError.whisperKitFailed("GigaAM decoder outputs missing")
                }
                let decT = Self.extractVector(decOut, count: runtime.info.predHidden)

                let jointOut = try await runtime.joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "enc_t": try GigaAMDSP.makeFloat32Array(shape: [1, runtime.info.encHidden], values: encT),
                    "dec_t": try GigaAMDSP.makeFloat32Array(shape: [1, runtime.info.predHidden], values: decT)
                ]))
                guard let logits = jointOut.featureValue(for: "logits")?.multiArrayValue else {
                    throw TranscriberError.whisperKitFailed("GigaAM joint outputs missing")
                }
                let nextToken = Self.argmax(logits, count: runtime.info.numClasses)
                if nextToken == runtime.info.blankID {
                    break
                }
                emitted.append(nextToken)
                h = Self.extractVector(hOut, count: runtime.info.predHidden)
                c = Self.extractVector(cOut, count: runtime.info.predHidden)
                lastToken = nextToken
            }
        }

        let rawText = GigaAMTokenDecoder.decode(tokenIDs: emitted, pieces: runtime.pieces)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Transcriber.isHallucinationText(text) else {
            return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
        }
        let segment = WhisperSegment(start: offsetSec, end: offsetSec + durationSec, text: text)
        return WhisperTranscription(text: text, segments: [segment], detectedLanguage: GigaAMConstants.supportedLanguage)
    }

    private func validateRequest(translate: Bool, language: String?) throws {
        if translate {
            throw TranscriberError.notAvailable
        }
        if let language, !language.isEmpty, language.lowercased() != GigaAMConstants.supportedLanguage {
            throw TranscriberError.notAvailable
        }
    }

    private func ensureRuntimeLoaded(
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> GigaAMRuntime {
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
                // Publish before the epoch check: the runtime is good even if
                // this request has since been cancelled, and the next dictation
                // must not pay for the load a second time.
                finishLoading(runtime)
                try checkCancellation(cancellationToken)
            } catch {
                finishLoading(nil)
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

    private func currentRuntime() -> GigaAMRuntime? {
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
        _ task: Task<GigaAMRuntime, Error>,
        cancellationToken: GigaAMRequestCancellation.Token
    ) {
        stateLock.lock()
        activeLoadTask = task
        stateLock.unlock()
        if !requestCancellation.isCurrent(cancellationToken) { task.cancel() }
    }

    /// Publish a loaded runtime regardless of which epoch asked for it.
    /// See `GigaAMCTCEngine.finishLoading` — same hazard, same reasoning: a
    /// cancelled request must not throw away a model that finished loading.
    private func finishLoading(_ runtime: GigaAMRuntime?) {
        stateLock.lock()
        if let runtime {
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
        engine: GigaAMEngine,
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> GigaAMRuntime {
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
        let preflightCompiledCacheReady = GigaAMCompiledCache.isReady(compiledRoot: compiledRoot)

        let downloader = GigaAMAssetDownloader(fileSystem: fileSystem)
        let installResult: GigaAMAssetInstallResult
        engine.setDownloading(true)
        do {
            installResult = try await downloader.ensureAssets(
                in: sourceRoot,
                additionalRequiredBytes: preflightCompiledCacheReady
                    ? 0
                    : GigaAMAssetCatalog.totalExpectedByteCount,
                onBytes: { bytes, totalBytes in
                    guard totalBytes > 0 else { return }
                    let progress = Double(bytes) / Double(totalBytes)
                    onProgress?(.downloadingModel(progress: min(0.95, progress)))
                }
            )
            engine.setDownloading(false)
        } catch {
            engine.setDownloading(false)
            throw error
        }
        try engine.checkCancellation(cancellationToken)
        try GigaAMSecureStorage.hardenTree(at: sourceRoot)

        _ = installResult
        let compiledCacheWasReady = GigaAMCompiledCache.isReady(compiledRoot: compiledRoot)
        let mustRebuildCompiledCache = !compiledCacheWasReady

        if mustRebuildCompiledCache {
            if FileManager.default.fileExists(atPath: compiledRoot.path)
                || (try? FileManager.default.attributesOfItem(atPath: compiledRoot.path)) != nil {
                try FileManager.default.removeItem(at: compiledRoot)
            }
        }
        try fileSystem.createPrivateDirectory(at: compiledRoot)
        onProgress?(.loadingModel)

        let decoder = JSONDecoder()
        let pieces = try decoder.decode([String].self, from: Data(contentsOf: sourceRoot.appendingPathComponent("tokens.json")))
        let info = try decoder.decode(GigaAMModelInfo.self, from: Data(contentsOf: sourceRoot.appendingPathComponent("model_info.json")))
        let convert = try decoder.decode(GigaAMConvertInfo.self, from: Data(contentsOf: sourceRoot.appendingPathComponent("convert_info.json")))

        let config = MLModelConfiguration()
        config.computeUnits = GigaAMConstants.computeUnits
        let encoderModel = try loadCompiledModel(
            packageURL: sourceRoot.appendingPathComponent("GigaAMv3Encoder.mlpackage"),
            compiledRoot: compiledRoot,
            configuration: config,
            allowCompilation: mustRebuildCompiledCache
        )
        let decoderModel = try loadCompiledModel(
            packageURL: sourceRoot.appendingPathComponent("GigaAMv3DecoderStep.mlpackage"),
            compiledRoot: compiledRoot,
            configuration: config,
            allowCompilation: mustRebuildCompiledCache
        )
        let jointModel = try loadCompiledModel(
            packageURL: sourceRoot.appendingPathComponent("GigaAMv3JointStep.mlpackage"),
            compiledRoot: compiledRoot,
            configuration: config,
            allowCompilation: mustRebuildCompiledCache
        )
        try engine.checkCancellation(cancellationToken)
        if mustRebuildCompiledCache {
            try GigaAMCompiledCache.seal(compiledRoot: compiledRoot)
        }
        guard GigaAMCompiledCache.isReady(compiledRoot: compiledRoot) else {
            throw GigaAMAssetDownloadError.insecureTopology(compiledRoot.path)
        }
        return GigaAMRuntime(
            encoder: encoderModel,
            decoder: decoderModel,
            joint: jointModel,
            pieces: pieces,
            info: info,
            convert: convert
        )
    }

    private static func loadCompiledModel(
        packageURL: URL,
        compiledRoot: URL,
        configuration: MLModelConfiguration,
        allowCompilation: Bool
    ) throws -> MLModel {
        try FileManager.default.createDirectory(at: compiledRoot, withIntermediateDirectories: true)
        let compiledURL = compiledRoot.appendingPathComponent(
            packageURL.deletingPathExtension().lastPathComponent + ".mlmodelc"
        )
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            guard allowCompilation else {
                throw GigaAMAssetDownloadError.insecureTopology(compiledURL.path)
            }
            let temporaryCompiledURL = try MLModel.compileModel(at: packageURL)
            if FileManager.default.fileExists(atPath: compiledURL.path) {
                try? FileManager.default.removeItem(at: compiledURL)
            }
            try FileManager.default.moveItem(at: temporaryCompiledURL, to: compiledURL)
        }
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    private static func extractFrame(_ encoded: MLMultiArray, frame: Int, hiddenSize: Int) -> [Float] {
        (0..<hiddenSize).map { encoded.float(at: [0, $0, frame]) }
    }

    private static func extractVector(_ array: MLMultiArray, count: Int) -> [Float] {
        if array.shape.count == 2 {
            return (0..<count).map { array.float(at: [0, $0]) }
        }
        return (0..<count).map { array.float(at: [0, 0, $0]) }
    }

    private static func argmax(_ logits: MLMultiArray, count: Int) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for i in 0..<count {
            let value: Float
            if logits.shape.count == 2 {
                value = logits.float(at: [0, i])
            } else {
                value = logits.float(at: [0, 0, i])
            }
            if value > bestValue {
                bestValue = value
                bestIndex = i
            }
        }
        return bestIndex
    }

}
