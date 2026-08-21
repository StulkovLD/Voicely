@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// MARK: - Parakeet TDT v3 engine
//
// NVIDIA Parakeet TDT 0.6B v3 (25 European languages, RU and EN included)
// through FluidAudio's CoreML/ANE pipeline. Unlike the GigaAM engines, all of
// the heavy lifting lives in FluidAudio: model download (ModelHub → our model
// directory), long-form chunking with seam repair, and TDT decoding with
// per-token timings. This engine adapts that API to Voicely's
// `TranscriberEngine`/`SampleTranscribing` contracts and regroups token
// timings into timestamped segments.
//
// MODEL WEIGHTS / ATTRIBUTION (CC-BY-4.0):
// The Parakeet TDT 0.6B v3 weights are NVIDIA's, converted to CoreML by
// FluidInference (parakeet-tdt-0.6b-v3-coreml). CC-BY-4.0 requires
// attribution: the "About" window MUST credit NVIDIA Parakeet.

private enum ParakeetConstants {
    /// Same silence gate as the GigaAM engines: a dictation of pure silence
    /// must fail fast instead of hallucinating.
    static let minNonSilentRMS: Float = 0.005
    /// A pause between two words longer than this starts a new timestamped
    /// segment even mid-sentence, so long monologues still get usable
    /// timecodes.
    static let segmentPauseGap: TimeInterval = 1.0
    /// Word endings that close a segment. Parakeet v3 punctuates natively, so
    /// sentence boundaries arrive inside the token stream itself.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
}

final class ParakeetEngine: @unchecked Sendable, TranscriberEngine, SampleTranscribing,
    PreloadableTranscriberEngine, CancelableTranscriberEngine,
    DownloadReportingTranscriberEngine, LanguageSessionResettable
{
    private let model: WhisperModel
    private let onProgress: (@Sendable (TranscriberStatus) -> Void)?
    private let stateLock = NSLock()
    private let requestCancellation = GigaAMRequestCancellation()

    private var manager: AsrManager?
    private var isLoading = false
    private var isDownloadInProgress = false
    private var activeLoadTask: Task<AsrManager, Error>?

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
        let token = requestCancellation.begin()
        _ = try await ensureManagerLoaded(cancellationToken: token)
    }

    func cancel() {
        let loadTask: Task<AsrManager, Error>?
        requestCancellation.cancelCurrentRequests()
        stateLock.lock()
        isDownloadInProgress = false
        loadTask = activeLoadTask
        stateLock.unlock()
        loadTask?.cancel()
        vlog("Parakeet: cancel requested")
    }

    func resetLanguageSession() {
        // Parakeet v3 is multilingual per utterance; there is no
        // detect-then-latch session state to clear.
    }

    func transcribe(
        audio: AVAudioPCMBuffer,
        translate: Bool = false,
        language: String? = nil
    ) async throws -> String {
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
        if translate {
            throw TranscriberError.notAvailable
        }
        guard !samples.isEmpty else { throw TranscriberError.recordingTooShort }
        let rms = GigaAMDSP.peakWindowRMS(samples)
        if rms < ParakeetConstants.minNonSilentRMS {
            throw TranscriberError.silentAudio
        }

        let cancellationToken = requestCancellation.begin()
        let manager = try await ensureManagerLoaded(cancellationToken: cancellationToken)
        try checkCancellation(cancellationToken)

        onProgress?(.processing)

        // Unknown language codes fall back to autodetection rather than
        // failing: the model is multilingual either way, the hint only prunes
        // mismatched scripts during decoding.
        let hint = language.flatMap { Language(rawValue: $0.lowercased()) }

        let result: ASRResult
        do {
            var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            result = try await manager.transcribe(samples, decoderState: &decoderState, language: hint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.whisperKitFailed("Parakeet: \(error.localizedDescription)")
        }
        try checkCancellation(cancellationToken)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Transcriber.isHallucinationText(text) else {
            return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
        }

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        let duration = Double(samples.count) / 16000.0
        let segments = Self.makeSegments(words: words, fallbackText: text, duration: duration)
        return WhisperTranscription(text: text, segments: segments, detectedLanguage: nil)
    }

    // MARK: - Segmenting word timings

    /// Regroup word timings into timestamped segments: a segment closes when a
    /// word ends a sentence (Parakeet punctuates natively) or when the pause
    /// before the next word exceeds `segmentPauseGap`. When the model returned
    /// no timings at all, the whole transcript becomes one segment spanning the
    /// input, so downstream timecode consumers degrade honestly instead of
    /// dropping text.
    static func makeSegments(
        words: [WordTiming],
        fallbackText: String,
        duration: Double
    ) -> [WhisperSegment] {
        guard !words.isEmpty else {
            guard !fallbackText.isEmpty else { return [] }
            return [WhisperSegment(start: 0, end: duration, text: fallbackText)]
        }

        var segments: [WhisperSegment] = []
        var currentWords: [String] = []
        var segmentStart = words[0].startTime
        var segmentEnd = words[0].startTime

        func flush() {
            let text = currentWords.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(WhisperSegment(start: segmentStart, end: segmentEnd, text: text))
        }

        for (index, word) in words.enumerated() {
            if currentWords.isEmpty {
                segmentStart = word.startTime
            }
            currentWords.append(word.word)
            segmentEnd = word.endTime

            let endsSentence = word.word.last.map {
                ParakeetConstants.sentenceTerminators.contains($0)
            } ?? false
            let nextGap: TimeInterval =
                index + 1 < words.count ? words[index + 1].startTime - word.endTime : 0
            if endsSentence || nextGap > ParakeetConstants.segmentPauseGap {
                flush()
                currentWords = []
            }
        }
        flush()
        return segments
    }

    // MARK: - Loading

    private func ensureManagerLoaded(
        cancellationToken: GigaAMRequestCancellation.Token
    ) async throws -> AsrManager {
        try checkCancellation(cancellationToken)
        if let manager = currentManager() { return manager }
        if tryStartLoading() {
            let task = Task {
                try await Self.loadManager(
                    model: model,
                    onProgress: onProgress,
                    engine: self
                )
            }
            setActiveLoadTask(task, cancellationToken: cancellationToken)
            do {
                let manager = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                // Publish before the epoch check: the manager is good even if
                // this request has since been cancelled, and the next dictation
                // must not pay for the load a second time.
                finishLoading(manager)
                try checkCancellation(cancellationToken)
            } catch {
                finishLoading(nil)
                throw error
            }
        } else {
            var waited: UInt64 = 0
            let maxWait: UInt64 = 300_000_000_000
            while currentManager() == nil && isLoadInProgress() && waited < maxWait {
                try await Task.sleep(nanoseconds: 100_000_000)
                waited += 100_000_000
                try checkCancellation(cancellationToken)
            }
            if currentManager() == nil && !isLoadInProgress() {
                try checkCancellation(cancellationToken)
                return try await ensureManagerLoaded(cancellationToken: cancellationToken)
            }
        }
        guard let manager = currentManager() else {
            throw TranscriberError.modelNotReady
        }
        return manager
    }

    private static func loadManager(
        model: WhisperModel,
        onProgress: (@Sendable (TranscriberStatus) -> Void)?,
        engine: ParakeetEngine
    ) async throws -> AsrManager {
        engine.setDownloading(true)
        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(
                to: model.modelDirectory,
                version: .v3,
                progressHandler: { progress in
                    switch progress.phase {
                    case .compiling:
                        onProgress?(.loadingModel)
                    case .listing, .downloading:
                        onProgress?(.downloadingModel(
                            progress: min(0.95, progress.fractionCompleted)))
                    }
                }
            )
            engine.setDownloading(false)
        } catch {
            engine.setDownloading(false)
            throw error
        }
        onProgress?(.loadingModel)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }

    // MARK: - Locked state

    private func currentManager() -> AsrManager? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return manager
    }

    private func isLoadInProgress() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isLoading
    }

    private func tryStartLoading() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard manager == nil, !isLoading else { return false }
        isLoading = true
        return true
    }

    private func setActiveLoadTask(
        _ task: Task<AsrManager, Error>,
        cancellationToken: GigaAMRequestCancellation.Token
    ) {
        stateLock.lock()
        activeLoadTask = task
        stateLock.unlock()
        if !requestCancellation.isCurrent(cancellationToken) { task.cancel() }
    }

    /// Publish a loaded manager regardless of which epoch asked for it.
    /// See `GigaAMEngine.finishLoading` — same hazard, same reasoning: a
    /// cancelled request must not throw away a model that finished loading.
    private func finishLoading(_ manager: AsrManager?) {
        stateLock.lock()
        if let manager {
            self.manager = manager
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

    private func checkCancellation(_ token: GigaAMRequestCancellation.Token) throws {
        try requestCancellation.check(token)
    }
}
