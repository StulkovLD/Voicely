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

private extension MLMultiArray {
    var elementCount: Int {
        shape.reduce(1) { $0 * Int(truncating: $1) }
    }

    func flatIndex(for indices: [Int]) -> Int {
        zip(indices, strides).reduce(0) { partial, pair in
            partial + pair.0 * Int(truncating: pair.1)
        }
    }

    func float(atFlatIndex index: Int) -> Float {
        // CoreML exposes Int8 multi-arrays starting with the macOS 26 SDK.
        // Compare the stable Objective-C raw value so this target still
        // compiles with Xcode 16.4 while decoding Int8 on newer runtimes.
        if dataType.rawValue == (0x20000 | 8) {
            let ptr = dataPointer.bindMemory(to: Int8.self, capacity: elementCount)
            return Float(ptr[index])
        }

        switch dataType {
        case .float32:
            let ptr = dataPointer.bindMemory(to: Float32.self, capacity: elementCount)
            return ptr[index]
        case .float16:
            let ptr = dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
            return Float(Float16(bitPattern: ptr[index]))
        case .double:
            let ptr = dataPointer.bindMemory(to: Double.self, capacity: elementCount)
            return Float(ptr[index])
        case .int32:
            let ptr = dataPointer.bindMemory(to: Int32.self, capacity: elementCount)
            return Float(ptr[index])
        default:
            return self[index].floatValue
        }
    }

    func float(at indices: [Int]) -> Float {
        float(atFlatIndex: flatIndex(for: indices))
    }

    func intValue(at indices: [Int]) -> Int {
        Int(round(Double(float(at: indices))))
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
        let normalized = try Self.normalizeTo16kMono(audio)
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
        let rms = Self.peakWindowRMS(samples)
        if rms < GigaAMConstants.minNonSilentRMS {
            throw TranscriberError.silentAudio
        }

        var allSegments: [WhisperSegment] = []
        var cursor = 0
        let chunkSize = GigaAMConstants.windowSamples
        while cursor < samples.count {
            try checkCancellation(cancellationToken)
            let end = min(cursor + chunkSize, samples.count)
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

        let (features, trueFrames) = try Self.makeFeatures(from: samples, info: runtime.info, convert: runtime.convert)
        try checkCancellation(cancellationToken)

        let encodedOut = try await runtime.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "features": features,
            "length": try Self.makeInt32Array(shape: [1], values: [Int32(trueFrames)])
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
                    "token": try Self.makeInt32Array(shape: [1, 1], values: [Int32(lastToken)]),
                    "h_in": try Self.makeFloat32Array(shape: [1, 1, runtime.info.predHidden], values: h),
                    "c_in": try Self.makeFloat32Array(shape: [1, 1, runtime.info.predHidden], values: c)
                ]))
                guard let decOut = decoderOut.featureValue(for: "dec_out")?.multiArrayValue,
                      let hOut = decoderOut.featureValue(for: "h_out")?.multiArrayValue,
                      let cOut = decoderOut.featureValue(for: "c_out")?.multiArrayValue else {
                    throw TranscriberError.whisperKitFailed("GigaAM decoder outputs missing")
                }
                let decT = Self.extractVector(decOut, count: runtime.info.predHidden)

                let jointOut = try await runtime.joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "enc_t": try Self.makeFloat32Array(shape: [1, runtime.info.encHidden], values: encT),
                    "dec_t": try Self.makeFloat32Array(shape: [1, runtime.info.predHidden], values: decT)
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

    private func finishLoading(
        _ runtime: GigaAMRuntime?,
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
                    : GigaAMAssetCatalog.totalExpectedByteCount
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

    private static func makeFeatures(
        from samples: [Float],
        info: GigaAMModelInfo,
        convert: GigaAMConvertInfo
    ) throws -> (MLMultiArray, Int) {
        guard !samples.isEmpty else { throw TranscriberError.recordingTooShort }
        let usableCount = min(samples.count, GigaAMConstants.windowSamples)
        if usableCount < info.melWinLength {
            throw TranscriberError.recordingTooShort
        }

        var padded = [Float](repeating: 0, count: GigaAMConstants.windowSamples)
        padded.withUnsafeMutableBufferPointer { dest in
            samples.prefix(usableCount).withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dest.baseAddress else { return }
                dstBase.update(from: srcBase, count: usableCount)
            }
        }

        let trueFrames = max(1, ((usableCount - info.melWinLength) / info.melHopLength) + 1)
        let frameCount = convert.melFrames
        let melBins = 64
        let powerBins = info.melNFFT / 2 + 1
        let filterBank = buildMelFilterBank(sampleRate: 16000, nFFT: info.melNFFT, melBins: melBins)
        let window = buildHannWindow(count: info.melWinLength)
        let dft: vDSP.DiscreteFourierTransform<Float>
        do {
            dft = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: info.melNFFT,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            throw TranscriberError.whisperKitFailed("Failed to create DFT for GigaAM mel frontend")
        }

        let logFloor = Float(log(1e-9))
        var featureValues = [Float](repeating: logFloor, count: melBins * frameCount)
        var realInput = [Float](repeating: 0, count: info.melNFFT)
        var imagInput = [Float](repeating: 0, count: info.melNFFT)
        var realOutput = [Float](repeating: 0, count: info.melNFFT)
        var imagOutput = [Float](repeating: 0, count: info.melNFFT)
        var power = [Float](repeating: 0, count: powerBins)

        for frame in 0..<frameCount {
            let start = frame * info.melHopLength
            let slice = padded[start..<(start + info.melWinLength)]
            var idx = 0
            for value in slice {
                realInput[idx] = value * window[idx]
                idx += 1
            }
            if idx < info.melNFFT {
                for i in idx..<info.melNFFT { realInput[i] = 0 }
            }
            imagInput.withUnsafeMutableBufferPointer { buffer in
                buffer.initialize(repeating: 0)
            }
            dft.transform(inputReal: realInput, inputImaginary: imagInput, outputReal: &realOutput, outputImaginary: &imagOutput)
            for bin in 0..<powerBins {
                let real = realOutput[bin]
                let imag = imagOutput[bin]
                power[bin] = real * real + imag * imag
            }
            for mel in 0..<melBins {
                let weights = filterBank[mel]
                var energy: Float = 0
                for bin in 0..<powerBins {
                    energy += weights[bin] * power[bin]
                }
                let logged = Float(log(Double(min(1e9 as Float, max(1e-9 as Float, energy)))))
                featureValues[mel * frameCount + frame] = logged
            }
        }

        return (try makeFloat32Array(shape: [1, melBins, frameCount], values: featureValues), trueFrames)
    }

    private static func buildHannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [Float](repeating: 1, count: max(1, count)) }
        let denominator = Float(count)
        return (0..<count).map { i in
            0.5 - 0.5 * cosf((2.0 * .pi * Float(i)) / denominator)
        }
    }

    private static func buildMelFilterBank(sampleRate: Int, nFFT: Int, melBins: Int) -> [[Float]] {
        let nyquist = Float(sampleRate) / 2.0
        let fftBins = nFFT / 2 + 1
        let melMin: Float = hzToMel(0)
        let melMax: Float = hzToMel(nyquist)
        let melPoints = (0..<(melBins + 2)).map { i -> Float in
            let ratio = Float(i) / Float(melBins + 1)
            return melMin + ratio * (melMax - melMin)
        }
        let hzPoints = melPoints.map(melToHz)
        let freqs = (0..<fftBins).map { Float($0) * Float(sampleRate) / Float(nFFT) }

        return (0..<melBins).map { band in
            let left = hzPoints[band]
            let center = hzPoints[band + 1]
            let right = hzPoints[band + 2]
            return freqs.map { freq in
                if freq < left || freq > right { return 0 }
                if freq <= center {
                    return (freq - left) / max(center - left, .leastNonzeroMagnitude)
                }
                return (right - freq) / max(right - center, .leastNonzeroMagnitude)
            }
        }
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10f(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
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

    private static func makeFloat32Array(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let count = array.elementCount
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
        if values.count == count {
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ptr.update(from: base, count: count)
            }
        } else {
            for i in 0..<count { ptr[i] = 0 }
            for (index, value) in values.enumerated() where index < count {
                ptr[index] = value
            }
        }
        return array
    }

    private static func makeInt32Array(shape: [Int], values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        let count = array.elementCount
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count { ptr[i] = 0 }
        for (index, value) in values.enumerated() where index < count {
            ptr[index] = value
        }
        return array
    }

    private static func normalizeTo16kMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let targetRate: Double = 16000
        let needsConversion = abs(buffer.format.sampleRate - targetRate) >= 1
            || buffer.format.channelCount != 1
            || buffer.format.commonFormat != .pcmFormatFloat32
            || buffer.format.isInterleaved
        if !needsConversion {
            return buffer
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriberError.whisperKitFailed("Failed to create 16kHz mono format")
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw TranscriberError.whisperKitFailed("Failed to create audio converter")
        }
        let ratio = targetRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            throw TranscriberError.whisperKitFailed("Failed to create resampling buffer")
        }
        var error: NSError?
        let input = SingleBufferAudioConverterInput(buffer)
        converter.convert(to: output, error: &error) { _, outStatus in
            input.provide(status: outStatus)
        }
        if let error {
            throw TranscriberError.whisperKitFailed("Resampling failed: \(error)")
        }
        return output
    }

    private static func peakWindowRMS(_ samples: [Float], windowSize: Int = 8000) -> Float {
        guard !samples.isEmpty else { return 0 }
        let win = max(1, min(windowSize, samples.count))
        var best: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(i + win, samples.count)
            let slice = samples[i..<end]
            var sum: Float = 0
            for s in slice { sum += s * s }
            let rms = sqrtf(sum / Float(max(1, end - i)))
            if rms > best { best = rms }
            i += win
        }
        return best
    }
}
