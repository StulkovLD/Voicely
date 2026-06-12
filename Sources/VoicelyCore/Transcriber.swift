@preconcurrency import Speech
import AVFoundation
import Foundation
@preconcurrency import WhisperKit

// MARK: - Debug Log

// NOTE (#107): vlog() opens/seeks/closes the file handle on every call.
// This is acceptable because it only runs in DEBUG builds and is not called
// in hot loops. If profiling shows I/O overhead, refactor to a retained handle.
private func vlog(_ message: String) {
    #if DEBUG
    let line = "[\(Date())] \(message)\n"
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Voicely")
    let path = logDir.appendingPathComponent("debug.log").path
    // Ensure log directory exists
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
    }
    #endif
}

// MARK: - Protocol

public protocol TranscriberEngine: Sendable {
    func transcribe(audio: AVAudioPCMBuffer, translate: Bool, language: String?) async throws -> String
}

// MARK: - Model Selection

public struct WhisperModel: Sendable, Equatable {
    public let variant: String
    public let displayName: String
    public let sizeLabel: String
    public let sizeBytes: UInt64
    public let minRAMGB: UInt64

    public static let all: [WhisperModel] = [
        WhisperModel(variant: "large-v3_turbo", displayName: "Large V3 Turbo", sizeLabel: "~3 GB", sizeBytes: 3_200_000_000, minRAMGB: 16),
        WhisperModel(variant: "large-v3-v20240930_turbo_632MB", displayName: "Large V3 Turbo Q", sizeLabel: "~632 MB", sizeBytes: 650_000_000, minRAMGB: 8),
        WhisperModel(variant: "small", displayName: "Small", sizeLabel: "~460 MB", sizeBytes: 460_000_000, minRAMGB: 4),
        WhisperModel(variant: "base", displayName: "Base", sizeLabel: "~140 MB", sizeBytes: 140_000_000, minRAMGB: 4),
    ]

    public static var systemRAMGB: UInt64 {
        ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
    }

    public static func available() -> [WhisperModel] {
        let ram = systemRAMGB
        return all.filter { $0.minRAMGB <= ram }
    }

    /// Available disk space in bytes, or nil if the check fails.
    private static var availableDiskBytes: UInt64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        guard let free = attrs?[.systemFreeSize] as? UInt64 else { return nil }
        return free
    }

    public static func recommended() -> WhisperModel {
        let ram = systemRAMGB
        let disk = availableDiskBytes

        // #34: Pick by RAM first, then verify disk space (need 1.5x for download + extraction)
        let candidate: WhisperModel
        if ram >= 16 {
            candidate = all[0] // large-v3_turbo - best quality
        } else {
            candidate = all[1] // quantized turbo - fits 8 GB
        }

        // If disk space is available and sufficient, use the candidate
        if let disk, disk >= candidate.sizeBytes * 3 / 2 {
            return candidate
        }

        // Disk check failed or insufficient - fall back to a smaller model that fits
        if let disk {
            for model in all where model.minRAMGB <= ram {
                if disk >= model.sizeBytes * 3 / 2 {
                    return model
                }
            }
        }

        // Filesystem check failed entirely - return RAM-based candidate (best effort)
        return candidate
    }

    /// Model directory on disk.
    public var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(variant)")
    }

    /// Filesystem path of `modelDirectory`. Public so the headless CLI can report
    /// whether a model is already downloaded (`voicely status`) without exposing
    /// the internal URL helper.
    public var modelDirectoryPath: String { modelDirectory.path }

    public static func == (lhs: WhisperModel, rhs: WhisperModel) -> Bool {
        lhs.variant == rhs.variant
    }
}

// MARK: - Progress Status

public enum TranscriberStatus: Sendable {
    case downloadingModel(progress: Double)
    case loadingModel
    case processing
    case finalizing

    public var message: String {
        switch self {
        case .downloadingModel(let progress):
            return "Downloading voice model... \(Int(min(1.0, max(0.0, progress)) * 100))%"
        case .loadingModel:
            return "Preparing model..."
        case .processing:
            return "Transcribing..."
        case .finalizing:
            return ""
        }
    }

    public var progress: Double {
        if case .downloadingModel(let p) = self { return p }
        return 0
    }
}

// MARK: - Factory

@MainActor
public final class Transcriber {
    private var engine: (any TranscriberEngine)?
    private let locale: Locale
    public private(set) var selectedModel: WhisperModel
    public var translateToEnglish = false

    /// Forced transcription language ("ru"/"en") set from the Language menu.
    /// `nil` = auto-detect with a per-session latch (Fix 1.1). When set, every
    /// decode is hard-forced to this language with no detection. Pushed onto
    /// the engine before each call (mirrors how `translateToEnglish` is passed).
    public var preferredLanguage: String?

    public var onProgress: (@Sendable (TranscriberStatus) -> Void)?

    public init(locale: Locale = .current) {
        self.locale = locale
        // Restore saved model or use RAM-based recommendation
        if let saved = UserDefaults.standard.string(forKey: "whisperModel"),
           let model = WhisperModel.all.first(where: { $0.variant == saved }),
           model.minRAMGB <= WhisperModel.systemRAMGB {
            self.selectedModel = model
        } else {
            self.selectedModel = WhisperModel.recommended()
        }
    }

    /// Exposes the underlying engine so specialized call paths (file
    /// transcription) can conditionally cast to feature-specific protocols
    /// like `SampleTranscribing`. Nil until the engine has been loaded.
    public var currentEngine: (any TranscriberEngine)? { engine }

    /// Change model. Resets engine so next transcription downloads/loads new model.
    public func selectModel(_ model: WhisperModel) {
        guard model != selectedModel || engine == nil else { return }
        cancelCurrentTask()
        selectedModel = model
        engine = nil
        UserDefaults.standard.set(model.variant, forKey: "whisperModel")
        vlog("Model changed to '\(model.variant)'")
    }

    /// Resolve engine. WhisperKit is primary (SFSpeechRecognizer broken on macOS 26).
    private func resolveEngine() -> any TranscriberEngine {
        if let engine = self.engine { return engine }

        vlog("Using WhisperKit, model: \(selectedModel.variant) (RAM: \(WhisperModel.systemRAMGB) GB)")
        let e = WhisperKitEngine(model: selectedModel, onProgress: onProgress)
        self.engine = e
        return e
    }

    /// Push the current forced-language preference onto the engine so the
    /// engine's decode-option logic (Fix 1.1) sees it. Call right after
    /// resolving the engine in each transcription entry point.
    private func syncEnginePreferences(_ engine: any TranscriberEngine) {
        (engine as? WhisperKitEngine)?.preferredLanguage = preferredLanguage
    }

    /// Reset all language latches (dictation + sample path + every call
    /// channel). Call at the start of each dictation/call/file session so a
    /// fresh detect-then-latch cycle runs (Fix 1.1). Does not change
    /// `preferredLanguage`. No-op until the engine has been created.
    public func resetLanguageSession() {
        (engine as? WhisperKitEngine)?.resetLanguageSession()
    }

    /// Whether a download is currently in progress.
    public var isDownloading: Bool {
        guard let whisper = engine as? WhisperKitEngine else { return false }
        return whisper.isCurrentlyDownloading
    }

    /// Cancel any in-progress download, model load, or transcription.
    public func cancelCurrentTask() {
        guard let whisper = engine as? WhisperKitEngine else { return }
        whisper.cancel()
    }

    /// Cancel and reset engine without deleting downloaded model files.
    public func cancelAndReset() {
        cancelCurrentTask()
        engine = nil
    }

    /// Cancel download and clean up partial files. Resets engine so next attempt starts fresh.
    public func cancelAndCleanup() {
        cancelCurrentTask()
        // Delete partial model files
        let dir = selectedModel.modelDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            vlog("Deleting partial model directory: \(dir.path)")
            try? FileManager.default.removeItem(at: dir)
        }
        // Also clean .cache directory used during download
        let cacheDir = dir.deletingLastPathComponent().appendingPathComponent(".cache")
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            vlog("Deleting download cache: \(cacheDir.path)")
            try? FileManager.default.removeItem(at: cacheDir)
        }
        engine = nil
    }

    // MARK: - Preload

    /// Download and load model on first launch so it's ready when user dictates.
    public func preloadModel() async throws {
        let engine = resolveEngine()
        guard let whisper = engine as? WhisperKitEngine else { return }
        do {
            try await whisper.preload()
            vlog("Model preloaded successfully")
        } catch {
            // Fix 1.2: do NOT delete here. Deletion of a corrupted model now
            // happens only at the proven-corruption site (WhisperKit(config)
            // load failure inside loadWhisperKit). Deleting on every preload
            // error wiped a good ~3 GB model on transient network failures and
            // broke offline start.
            throw error
        }
    }

    // MARK: - Transcription

    public func transcribe(audio: AVAudioPCMBuffer?) async throws -> String {
        guard let audio = audio else { return "" }

        // WhisperKit doesn't need Speech Recognition permission (runs on CoreML).
        // Authorization check skipped - only microphone permission is required (handled by Recorder).

        onProgress?(.processing)

        let resolved = resolveEngine()
        syncEnginePreferences(resolved)
        // language: nil — the engine drives language selection: it forces
        // `preferredLanguage` when set, otherwise auto-detects on the first
        // window and latches for the rest of the session (Fix 1.1).
        let raw: String
        do {
            raw = try await resolved.transcribe(audio: audio, translate: translateToEnglish, language: nil)
        } catch let error as TranscriberError {
            // Fix 1.2: do NOT delete the model directory here. A network
            // failure (.modelDownloadFailed) must never wipe the ~3 GB model —
            // that broke offline start. Proven CoreML corruption is handled at
            // the load site inside loadWhisperKit (WhisperKit(config) failure).
            throw error
        } catch {
            throw TranscriberError.whisperKitFailed(error.localizedDescription)
        }

        let audioDuration = Double(audio.frameLength) / audio.format.sampleRate
        onProgress?(.finalizing)
        return Self.filterHallucinations(raw, audioDuration: audioDuration)
    }

    /// Transcribe a single channel, returning speaker-labelled segments.
    /// Language is latched per speaker (Fix 1.1): the first window of this
    /// speaker's session detects the language, and every later window of the
    /// same speaker reuses it — so the other party speaking a different
    /// language never flips this speaker's detected language mid-call.
    ///
    /// `startOffsetSec` is added to every segment's start/end so callers can
    /// stitch chunks onto a call-wide timeline.
    public func transcribeChannel(
        samples: [Float],
        sampleRate: Double,
        speaker: CallSpeaker,
        startOffsetSec: Double
    ) async throws -> [DialogueSegment] {
        guard !samples.isEmpty else { return [] }
        let engine = resolveEngine()
        syncEnginePreferences(engine)
        guard let whisper = engine as? WhisperKitEngine else { return [] }

        let resampled = try Self.resampleSamples(samples, fromRate: sampleRate, toRate: 16000)
        guard !resampled.isEmpty else { return [] }

        onProgress?(.processing)

        let result: WhisperTranscription
        do {
            result = try await whisper.transcribeChannelSamples(
                resampled,
                translate: translateToEnglish,
                speaker: speaker
            )
        } catch TranscriberError.silentAudio {
            return []
        } catch TranscriberError.recordingTooShort {
            return []
        }

        onProgress?(.finalizing)

        return result.segments.compactMap { seg -> DialogueSegment? in
            let clean = Self.filterHallucinations(seg.text, audioDuration: Double(seg.end - seg.start))
            guard !clean.isEmpty else { return nil }
            return DialogueSegment(
                speaker: speaker,
                start: seg.start + startOffsetSec,
                end: seg.end + startOffsetSec,
                text: clean,
                language: result.detectedLanguage
            )
        }
    }

    /// Resample a raw Float32 sample array via AVAudioConverter. Extracted so
    /// `transcribeChannel` can accept [Float] directly without callers having
    /// to construct PCMBuffers.
    private static func resampleSamples(
        _ samples: [Float],
        fromRate: Double,
        toRate: Double
    ) throws -> [Float] {
        if abs(fromRate - toRate) < 1 { return samples }
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: fromRate, channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: toRate, channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw TranscriberError.whisperKitFailed("resample setup failed") }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        if let p = srcBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    p.initialize(from: base, count: samples.count)
                }
            }
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw TranscriberError.whisperKitFailed("resample converter init failed")
        }
        let ratio = toRate / fromRate
        let outFrames = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outFrames) else {
            throw TranscriberError.whisperKitFailed("resample output alloc failed")
        }
        var err: NSError?
        var consumed = false
        converter.convert(to: dstBuf, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if let err { throw TranscriberError.whisperKitFailed("resample failed: \(err)") }
        guard let data = dstBuf.floatChannelData?[0] else {
            throw TranscriberError.whisperKitFailed("resample output missing data")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(dstBuf.frameLength)))
    }

    // MARK: - Model Directory Cleanup

    /// Delete model directory so next attempt starts clean.
    /// `nonisolated`: pure FileManager work with no main-actor state, so the
    /// non-isolated WhisperKitEngine load path can call it after a proven
    /// corruption (Fix 1.2) without hopping to the main actor.
    nonisolated static func deleteModelDirectory(for model: WhisperModel) {
        let dir = model.modelDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        vlog("Deleting corrupted model directory: \(dir.path)")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Hallucination filter

    nonisolated static let hallucinations: Set<String> = [
        // Common WhisperKit hallucinations on silent/noisy audio
        "Thank you.", "Thank you", "Thanks for watching!",
        "Thanks for watching.", "Thank you for watching.",
        "Thank you so much.", "Thank you very much.",
        "Subscribe to my channel.", "Like and subscribe.", "Please subscribe.",
        "Bye.", "Bye-bye.", "Goodbye.", "Bye",
        "you", "You.", "...", ".",
        "Спасибо.", "Спасибо за просмотр!",
        "Субтитры сделал DimaTorzworworwork",
        "Субтитры сделаны",
        "Субтитры делал",
        "Продолжение следует...",
        "Редактор субтитров А.Семкин",
        "Переведено и отредактировано",
        "Music", "music", "♪", "♫",
        "Музыка",
    ]

    private static func filterHallucinations(_ text: String, audioDuration: Double) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if isHallucinationText(trimmed) { return "" }
        return trimmed
    }

    /// Whether a trimmed string is a known WhisperKit hallucination (the
    /// "Продолжение следует…" / "Subtitles by…" filler models emit on silence
    /// or trailing music). Shared so the SEGMENT path (transcribeSamplesCore,
    /// which feeds diarized "Speaker N" / timestamped / call transcripts) filters
    /// the same fillers as the joined-string dictation path — otherwise they
    /// leak into diarized output. `nonisolated` so the engine can call it.
    nonisolated static func isHallucinationText(_ trimmed: String) -> Bool {
        if hallucinations.contains(trimmed) { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("субтитры") || lower.hasPrefix("редактор субтитров") { return true }
        if lower.hasPrefix("переведено") || lower.hasPrefix("subtitles by") { return true }
        // Prefix (not exact) so trailing-punctuation variants are caught too:
        // "Продолжение следует", "…следует.", "…следует…" (unicode ellipsis).
        if lower.hasPrefix("продолжение следует") { return true }
        return false
    }
}

// MARK: - Errors

public enum TranscriberError: Error, LocalizedError {
    case notAvailable
    case notAuthorized
    case whisperKitFailed(String)
    case modelDownloadFailed(String)
    case silentAudio
    case recordingTooShort
    case transcriptionTimedOut
    case modelNotReady
    case engineBusy
    case insufficientDiskSpace(needed: UInt64, available: UInt64)

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Speech recognition is not available for this language"
        case .notAuthorized:
            return "Speech recognition not authorized - enable in System Settings > Privacy & Security > Speech Recognition"
        case .whisperKitFailed:
            return "Voice recognition failed. Please try again."
        case .modelDownloadFailed(let detail):
            return "Could not download voice model. \(detail)"
        case .silentAudio:
            return "No speech detected. Check that your microphone is on and try again."
        case .recordingTooShort:
            return "Recording too short. Hold the key while you speak."
        case .transcriptionTimedOut:
            return "Transcription timed out. Try a shorter recording."
        case .modelNotReady:
            return "Voice model is still loading. Please wait and try again."
        case .engineBusy:
            return "Voice engine is busy. Retrying."
        case .insufficientDiskSpace(let needed, let available):
            let neededGB = Double(needed) / 1_000_000_000
            let availGB = Double(available) / 1_000_000_000
            let fmt = { (gb: Double) -> String in String(format: "%.1f GB", gb) }
            return "Not enough disk space. Need \(fmt(neededGB)) free, have \(fmt(availGB)). Free up space and try again."
        }
    }
}

// MARK: - Transcription result with segments

/// One decoded segment with start/end timestamps relative to the audio
/// fed into `transcribeSamples`. Always `Double` so downstream callers
/// (SRT generation, progress math) don't need to juggle Float precision.
public struct WhisperSegment: Sendable, Equatable {
    public let start: Double  // seconds from start of input
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Richer transcription result used by file transcription. The existing
/// dictation path still uses the string-returning overload.
public struct WhisperTranscription: Sendable, Equatable {
    public let text: String                 // joined segment texts
    public let segments: [WhisperSegment]
    public let detectedLanguage: String?

    public init(text: String, segments: [WhisperSegment], detectedLanguage: String?) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
    }
}

/// Minimal protocol so tests can substitute a fake transcriber without
/// standing up a real WhisperKit pipeline.
public protocol SampleTranscribing: Sendable {
    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription
}

// MARK: - Call diarization segments

/// Speaker label for a merged call transcript.
public enum CallSpeaker: String, Sendable, Equatable {
    case you       // mic
    case other     // system audio
}

/// One speaker-labelled segment with timestamps relative to the start of
/// the recording and the language detected for that segment's window.
public struct DialogueSegment: Sendable, Equatable {
    public let speaker: CallSpeaker
    public let start: Double   // seconds from recording start
    public let end: Double
    public let text: String
    public let language: String?
    /// 1-based diarization speaker index assigned by `DiarizationService`
    /// (N2b/N2c). `nil` when diarization hasn't run or no turn overlaps this
    /// segment. Trailing with a default so existing initializers, call sites,
    /// and `Equatable` synthesis stay source-compatible.
    public var speakerID: Int? = nil

    public init(
        speaker: CallSpeaker,
        start: Double,
        end: Double,
        text: String,
        language: String?,
        speakerID: Int? = nil
    ) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.speakerID = speakerID
    }
}

// MARK: - Apple Speech Engine

final class AppleSpeechEngine: TranscriberEngine {
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func transcribe(audio: AVAudioPCMBuffer, translate: Bool = false, language: String? = nil) async throws -> String {
        // Check authorization status (prepare() should have been called already)
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw TranscriberError.notAuthorized
        }

        guard let recognizer = await MainActor.run(body: {
            SFSpeechRecognizer(locale: locale)
        }), await MainActor.run(body: { recognizer.isAvailable }) else {
            throw TranscriberError.notAvailable
        }

        // Write buffer to temp WAV for SFSpeechURLRecognitionRequest
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Use commonFormat settings to preserve float sample type from Recorder
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.format.sampleRate,
            AVNumberOfChannelsKey: audio.format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !audio.format.isInterleaved,
        ]
        let file = try AVAudioFile(forWriting: tempURL, settings: settings)
        try file.write(from: audio)

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = true

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var lastPartialResult = ""

            let task = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                guard !finished else { lock.unlock(); return }

                if let error = error {
                    finished = true
                    let partial = lastPartialResult
                    lock.unlock()
                    if !partial.isEmpty {
                        continuation.resume(returning: partial)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let result = result {
                    lastPartialResult = result.bestTranscription.formattedString
                    if result.isFinal {
                        finished = true
                        let text = result.bestTranscription.formattedString
                        lock.unlock()
                        continuation.resume(returning: text)
                        return
                    }
                }
                lock.unlock()
            }

            // Timeout: if recognition hasn't completed in 30s, use best partial result
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let partial = lastPartialResult
                lock.unlock()
                task.cancel()
                if !partial.isEmpty {
                    continuation.resume(returning: partial)
                } else {
                    continuation.resume(throwing: TranscriberError.transcriptionTimedOut)
                }
            }
        }
    }
}

// MARK: - Deadline Helper

/// Sentinel error for timeout detection.
private struct DeadlineExceeded: Error {}

/// Thread-safe one-shot flag for deadline coordination. Uses DispatchQueue for serialization
/// to avoid NSLock restrictions in async contexts.
private final class DeadlineFlag: @unchecked Sendable {
    private var _completed = false
    private let queue = DispatchQueue(label: "voicely.deadline")

    /// Try to claim the flag. Returns true if this is the first call, false if already claimed.
    func tryComplete() -> Bool {
        queue.sync {
            guard !_completed else { return false }
            _completed = true
            return true
        }
    }
}

/// Run an async operation with a deadline. If the operation doesn't complete in time,
/// throws `DeadlineExceeded`. Uses `withCheckedThrowingContinuation` to avoid Sendable constraints.
private func withDeadline<T>(
    seconds: UInt64,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let flag = DeadlineFlag()

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(Int(seconds)))

        let task = Task {
            do {
                let value = try await operation()
                guard flag.tryComplete() else { return }
                timer.cancel()
                continuation.resume(returning: value)
            } catch {
                guard flag.tryComplete() else { return }
                timer.cancel()
                continuation.resume(throwing: error)
            }
        }

        timer.setEventHandler {
            guard flag.tryComplete() else { return }
            timer.cancel()
            task.cancel()
            continuation.resume(throwing: DeadlineExceeded())
        }
        timer.resume()
    }
}

// MARK: - WhisperKit Engine (primary - SFSpeechRecognizer broken on macOS 26)

final class WhisperKitEngine: @unchecked Sendable, TranscriberEngine, SampleTranscribing {
    /// WhisperKit stages the model into `.cache/...incomplete` then moves it
    /// into place, and CoreML compiles it for local hardware. That pipeline
    /// peaks at roughly 2.5x the final model size on disk.
    private static let diskHeadroomMultiplier: Double = 2.5

    private var pipe: WhisperKit?
    private var isLoading = false
    private var isTranscribing = false
    private let pipeLock = NSLock()
    private let model: WhisperModel
    private let onProgress: (@Sendable (TranscriberStatus) -> Void)?

    /// Whether a model download is currently in progress.
    private var isDownloadInProgress = false

    /// Reference to polling task so it can be cancelled.
    private var pollingTask: Task<Void, Never>?

    /// Lock-protected getter for pipe (#17: avoid data race on pipe read).
    private func getPipe() -> WhisperKit? {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        return pipe
    }

    /// Thread-safe read access to download state.
    var isCurrentlyDownloading: Bool {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        return isDownloadInProgress
    }

    /// Set to true to cancel any in-progress operation.
    private var cancelled = false

    // MARK: - Sticky language (Fix 1.1)

    /// Identifies an independent language latch. Dictation, the generic
    /// sample path (file queue), and each call channel each get their own
    /// latch so e.g. the other party speaking English never forces the mic's
    /// Russian to be detected as English on a later window.
    enum LatchKey: Hashable, Sendable {
        case dictation
        case samples
        case channel(CallSpeaker)
    }

    /// Forced language ("ru"/"en"). When set, every decode is hard-forced to
    /// this language with no detection and the latch is bypassed entirely.
    /// `nil` = auto-detect-then-latch per session.
    var preferredLanguage: String?

    /// Detected-and-latched language per session, keyed by `LatchKey`.
    /// Populated from the first window's `result.language` so later windows
    /// in the same session reuse it instead of re-detecting (which caused
    /// mid-session ru→en flips). Guarded by `pipeLock`.
    private var latchedLanguage: [LatchKey: String] = [:]

    /// Read the latched language for a session, if any. Lock-guarded.
    private func latched(for key: LatchKey) -> String? {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        return latchedLanguage[key]
    }

    /// Latch a detected language for a session. No-op if already latched or
    /// the detected string is empty. Lock-guarded.
    private func setLatched(_ language: String?, for key: LatchKey) {
        guard let language, !language.isEmpty else { return }
        pipeLock.lock()
        defer { pipeLock.unlock() }
        if latchedLanguage[key] == nil {
            latchedLanguage[key] = language
        }
    }

    /// Clear all language latches (dictation + sample path + every channel).
    /// Called at the start of each dictation/call/file session so a fresh
    /// detect-then-latch cycle runs. Does not touch `preferredLanguage`.
    func resetLanguageSession() {
        pipeLock.lock()
        latchedLanguage.removeAll()
        pipeLock.unlock()
        vlog("WhisperKit: language session reset")
    }

    /// Build decode options applying the sticky-language contract (Fix 1.1):
    /// - translate: task=.translate, language=nil, prefill on, detect off (unchanged).
    /// - forced (preferredLanguage != nil): force that language, prefill on,
    ///   detect off, never latch.
    /// - already latched: force the latched language, prefill on, detect off.
    /// - first window (no latch, no force): language=nil, prefill on, detect on
    ///   so WhisperKit detects AND writes the prefill itself; caller latches
    ///   `result.language` afterwards.
    ///
    /// GRABLYA: never leave detectLanguage=true once a language is pinned —
    /// detection would keep overwriting the prefill each window and the flips
    /// would return. After a latch (or force) detectLanguage is always false.
    private func makeDecodingOptions(translate: Bool, latchKey: LatchKey) -> DecodingOptions {
        let task: DecodingTask = translate ? .translate : .transcribe
        if translate {
            return DecodingOptions(
                task: .translate,
                language: nil,
                usePrefillPrompt: true,
                detectLanguage: false,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )
        }
        let pinned = preferredLanguage ?? latched(for: latchKey)
        return DecodingOptions(
            task: task,
            language: pinned,
            usePrefillPrompt: true,
            detectLanguage: pinned == nil,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    /// After a decode, latch the detected language for this session if we were
    /// in auto mode (not translate, not forced) and nothing is latched yet.
    private func latchIfNeeded(translate: Bool, latchKey: LatchKey, detected: String?) {
        guard !translate, preferredLanguage == nil else { return }
        setLatched(detected, for: latchKey)
    }

    // MARK: - Confidence-gated language detection (Fix 1.5)
    //
    // The Fix 1.1 latch pins the first window's detected language so later
    // windows don't flip. Its failure mode: if that first detection is WRONG,
    // the whole session is poisoned (observed: an English clip detected as Urdu,
    // synthetic speech as Catalan). This pre-detection makes the latched choice
    // robust: trust a confident detection (any language), but when the window is
    // ambiguous, prefer the user's likely languages over an exotic argmax.

    /// Probability at/above which a detected language is trusted as-is (so a
    /// genuinely French file still latches French). Below it the window is
    /// treated as ambiguous and biased toward `candidateLanguages()`.
    nonisolated static let languageConfidenceThreshold: Float = 0.6

    /// The user's likely languages: the system locale's language plus English.
    nonisolated static func candidateLanguages() -> Set<String> {
        var set: Set<String> = ["en"]
        if let code = Locale.current.language.languageCode?.identifier.lowercased(),
           !code.isEmpty {
            set.insert(code)
        }
        return set
    }

    /// Pure decision: which language to latch from WhisperKit's per-language
    /// probabilities. Trusts a confident global argmax (any language); otherwise
    /// falls back to the most probable *candidate* language so an ambiguous
    /// window never latches an exotic misfire. nil only for empty input.
    /// Pure + nonisolated so it is unit-testable without loading a model.
    nonisolated static func pickLanguage(
        langProbs: [String: Float],
        candidates: Set<String>,
        threshold: Float
    ) -> String? {
        guard let top = langProbs.max(by: { $0.value < $1.value }) else { return nil }
        if top.value >= threshold { return top.key }
        let bestCandidate = candidates
            .compactMap { lang in langProbs[lang].map { (lang, $0) } }
            .max(by: { $0.1 < $1.1 })
        return bestCandidate?.0 ?? top.key
    }

    /// Run WhisperKit's dedicated detector once on the window and apply
    /// `pickLanguage`. Returns the language to latch, or nil if detection failed
    /// (non-multilingual model / decode error) so callers fall back to the
    /// transcribe-result latch.
    private func detectLanguageBiased(samples: [Float], pipe: WhisperKit) async -> String? {
        guard let detected = try? await pipe.detectLangauge(audioArray: samples) else { return nil }
        return Self.pickLanguage(
            langProbs: detected.langProbs,
            candidates: Self.candidateLanguages(),
            threshold: Self.languageConfidenceThreshold
        )
    }

    init(model: WhisperModel, onProgress: (@Sendable (TranscriberStatus) -> Void)? = nil) {
        self.model = model
        self.onProgress = onProgress
    }

    /// Cancel any in-progress download, model load, or transcription.
    func cancel() {
        pipeLock.lock()
        cancelled = true
        let polling = pollingTask
        pollingTask = nil
        isDownloadInProgress = false
        pipeLock.unlock()
        polling?.cancel()
        vlog("WhisperKit: cancel requested")
    }

    private func resetCancellation() {
        pipeLock.lock()
        cancelled = false
        pipeLock.unlock()
    }

    private func isCancelled() -> Bool {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        return cancelled
    }

    /// Check cancellation and throw CancellationError if cancelled.
    private func checkCancellation() throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    // Sync helpers to avoid NSLock in async context (Swift 6 restriction)
    private func tryStartLoading() -> Bool {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        guard pipe == nil, !isLoading else { return false }
        isLoading = true
        return true
    }

    private func finishLoading(_ loaded: WhisperKit?) {
        pipeLock.lock()
        // If cancelled during download, discard the loaded pipe
        if cancelled {
            pipe = nil
        } else {
            pipe = loaded
        }
        isLoading = false
        isDownloadInProgress = false
        pollingTask = nil
        pipeLock.unlock()
    }

    /// Sync helper: set/check isTranscribing flag. Returns previous value.
    private func trySetTranscribing(_ value: Bool) -> Bool {
        pipeLock.lock()
        defer { pipeLock.unlock() }
        let was = isTranscribing
        isTranscribing = value
        return was
    }

    /// Sync helper: nil out pipe after timeout.
    private func clearPipe() {
        pipeLock.lock()
        pipe = nil
        pipeLock.unlock()
    }

    private func setDownloading(_ value: Bool) {
        pipeLock.lock()
        isDownloadInProgress = value
        pipeLock.unlock()
    }

    func setPollingTask(_ task: Task<Void, Never>?) {
        pipeLock.lock()
        pollingTask = task
        pipeLock.unlock()
    }

    /// Download and load model ahead of time (called on app launch).
    func preload() async throws {
        guard tryStartLoading() else { return }
        resetCancellation()
        do {
            let loaded = try await Self.loadWhisperKit(model: model, onProgress: onProgress, engine: self)
            finishLoading(loaded)
        } catch {
            finishLoading(nil)
            throw error
        }
    }

    // NOTE: keep in sync with transcribeSamples() — shared decoding pipeline is duplicated.
    func transcribe(audio: AVAudioPCMBuffer, translate: Bool = false, language: String? = nil) async throws -> String {
        // #19: Guard against concurrent transcribe() calls
        let alreadyTranscribing = trySetTranscribing(true)
        guard !alreadyTranscribing else {
            throw TranscriberError.engineBusy
        }
        defer { _ = trySetTranscribing(false) }

        resetCancellation()

        // Model should already be loaded via preload(), but handle cold start
        let needsLoad = tryStartLoading()

        if needsLoad {
            do {
                let loaded = try await Self.loadWhisperKit(model: model, onProgress: onProgress, engine: self)
                finishLoading(loaded)
            } catch {
                finishLoading(nil)
                throw error
            }
        } else {
            // #20: tryStartLoading returned false - either pipe exists or loading in progress.
            // If loading in progress (pipe is nil), wait for it to complete.
            var waited: UInt64 = 0
            let maxWait: UInt64 = 120_000_000_000 // 120 seconds in nanoseconds
            while getPipe() == nil && waited < maxWait {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waited += 100_000_000
                try checkCancellation()
            }
            // #65: Throw instead of silently continuing with nil pipe
            if getPipe() == nil {
                throw TranscriberError.modelNotReady
            }
        }

        guard let currentPipe = getPipe() else {
            throw TranscriberError.whisperKitFailed("Failed to initialize WhisperKit")
        }

        try checkCancellation()

        // Resample to 16kHz if needed (WhisperKit requires 16000 Hz)
        vlog("WhisperKit: input \(audio.frameLength) frames at \(audio.format.sampleRate)Hz")
        let resampled = try Self.resampleTo16kHz(audio)
        vlog("WhisperKit: resampled to \(resampled.frameLength) frames at \(resampled.format.sampleRate)Hz")

        // #minor: cancellation check after resampling
        try checkCancellation()

        guard resampled.frameLength > 8000 else {
            throw TranscriberError.recordingTooShort
        }
        guard let channelData = resampled.floatChannelData?[0] else {
            throw TranscriberError.whisperKitFailed("No audio data in buffer")
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(resampled.frameLength)))

        // #111: Empty audio produces NaN from 0/0 division - catch before RMS calc
        guard !samples.isEmpty else {
            throw TranscriberError.silentAudio
        }

        // Silence detection: skip transcription if audio too quiet.
        // Fix 1.4: gate on the loudest 0.5 s sub-window, not the whole-buffer
        // average, so a short quiet utterance inside a longer silent buffer
        // isn't averaged below the threshold and dropped.
        let rms = Self.peakWindowRMS(samples)
        vlog("WhisperKit: \(samples.count) samples, peak-window RMS = \(rms)")
        // #62: 0.005 allows whispered speech through while catching dead silence / disconnected mic
        if rms < 0.005 {
            vlog("WhisperKit: audio too quiet, skipping transcription")
            throw TranscriberError.silentAudio
        }

        // Sticky language (Fix 1.1): dictation has its own latch. `language`
        // arg, when non-nil, is treated as a hard force via preferredLanguage
        // upstream; here we honor an explicit per-call override too.
        let latchKey: LatchKey = .dictation
        // Fix 1.5: confidence-gated, candidate-biased pre-detection. Runs once
        // per session (until something latches) so an ambiguous first window
        // never poisons the rest with an exotic misfire. No-op if it returns nil
        // (the transcribe-result latch below is the fallback).
        if !translate, language == nil, latched(for: latchKey) == nil {
            setLatched(await detectLanguageBiased(samples: samples, pipe: currentPipe), for: latchKey)
        }
        let options: DecodingOptions
        if !translate, let language {
            // Explicit one-shot force from the caller: pin it, no detect, no latch.
            options = DecodingOptions(
                task: .transcribe,
                language: language,
                usePrefillPrompt: true,
                detectLanguage: false,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )
        } else {
            options = makeDecodingOptions(translate: translate, latchKey: latchKey)
        }

        // Transcription timeout: 90 seconds (#11)
        // NOTE (#18): withDeadline cancels the Task but cannot cancel in-flight CoreML/ANE operations.
        // CoreML GPU/ANE work will continue until completion even after timeout. After timeout we
        // nil out self.pipe to release the stale pipeline and force a fresh load on next call.
        let result: [TranscriptionResult]
        do {
            result = try await withDeadline(seconds: 90) {
                try await currentPipe.transcribe(audioArray: samples, decodeOptions: options)
            }
        } catch is DeadlineExceeded {
            // #18 + #101: Release stale pipeline after timeout - CoreML work may still be
            // running on GPU/ANE but we must not reuse a potentially stuck pipeline.
            // clearPipe() nils self.pipe; we also need to force WhisperKit dealloc to
            // release GPU resources, so the next call will create a fresh instance.
            clearPipe()
            throw TranscriberError.transcriptionTimedOut
        }

        // Latch the detected language for the rest of this dictation session
        // (only when we were auto-detecting and the caller didn't force one).
        if language == nil {
            let detected = result.first(where: { !$0.language.isEmpty })?.language
            latchIfNeeded(translate: translate, latchKey: latchKey, detected: detected)
        }

        // Build from cleaned segments (strip tokens, drop hallucinations) so a
        // trailing "Продолжение следует…" never reaches injected dictation —
        // same filter as the sample/diarized paths. Fall back to the raw join if
        // segmentation produced nothing usable.
        let cleaned = result
            .flatMap { $0.segments }
            .compactMap { Self.cleanSegmentText($0.text) }
            .joined(separator: " ")
        let text = cleaned.isEmpty ? result.map { $0.text }.joined(separator: " ") : cleaned
        vlog("WhisperKit: result segments=\(result.count) text=[\(text.count) chars]")
        return text
    }

    /// Lower-level entry point for file transcription: accepts 16 kHz mono
    /// Float32 samples directly and returns full segment data (timestamps,
    /// detected language, joined text). Skips the PCMBuffer resampling path
    /// because callers of this method are expected to pre-resample.
    ///
    /// Note: duplicates ~80% of `transcribe(audio:)` intentionally — that
    /// method is on the dictation hot path and we do not want to change its
    /// observable behavior. Dedupe in a future commit if this proves stable.
    // NOTE: keep in sync with transcribe(audio:) — shared decoding pipeline is duplicated.
    //
    // Generic sample path (file queue). When `language` is non-nil it's a hard
    // one-shot force; when nil this session latches under `.samples`.
    /// Strip WhisperKit special tokens from a segment's text. The low-level
    /// per-segment `.text` carries the raw decoder stream
    /// (`<|startoftranscript|><|ru|><|transcribe|><|0.00|> … <|5.06|>`); only the
    /// joined `result.text` is pre-cleaned by WhisperKit. The segment path feeds
    /// the timestamped, diarized (Speaker N), and call transcripts, so without
    /// this strip those outputs leak `<|…|>` tokens. Removes every `<|…|>` run
    /// and collapses the whitespace it leaves behind.
    static func stripSpecialTokens(_ s: String) -> String {
        guard s.contains("<|") else { return s }
        let cleaned = s.replacingOccurrences(
            of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        return cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clean one raw decoder segment: strip special tokens, then return nil if
    /// it is empty or a known hallucination ("Продолжение следует…"). Single
    /// source of truth so BOTH the joined-string transcript and the per-segment
    /// (diarized / timestamped / call) output filter identically — otherwise a
    /// trailing hallucination survives in whichever path skips this.
    nonisolated static func cleanSegmentText(_ raw: String) -> String? {
        let clean = stripSpecialTokens(raw)
        if clean.isEmpty || Transcriber.isHallucinationText(clean) { return nil }
        return clean
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        try await transcribeSamplesCore(
            samples,
            translate: translate,
            latchKey: .samples,
            forcedLanguage: language
        )
    }

    /// Per-channel call path (Fix 1.1): each speaker latches independently so
    /// the other party speaking a different language never flips the mic's
    /// detected language. Shares the exact decode core with `transcribeSamples`.
    func transcribeChannelSamples(
        _ samples: [Float],
        translate: Bool,
        speaker: CallSpeaker
    ) async throws -> WhisperTranscription {
        try await transcribeSamplesCore(
            samples,
            translate: translate,
            latchKey: .channel(speaker),
            forcedLanguage: nil
        )
    }

    /// Shared decode core for the sample-based paths. `latchKey` selects which
    /// independent language latch this session uses; `forcedLanguage`, when
    /// non-nil, hard-forces that language for this single call (no detect, no
    /// latch) and overrides both `preferredLanguage` and the latch.
    private func transcribeSamplesCore(
        _ samples: [Float],
        translate: Bool,
        latchKey: LatchKey,
        forcedLanguage: String?
    ) async throws -> WhisperTranscription {
        // #19: Guard against concurrent transcribe() calls
        let alreadyTranscribing = trySetTranscribing(true)
        guard !alreadyTranscribing else {
            throw TranscriberError.engineBusy
        }
        defer { _ = trySetTranscribing(false) }

        resetCancellation()

        // Model should already be loaded via preload(), but handle cold start
        let needsLoad = tryStartLoading()

        if needsLoad {
            do {
                let loaded = try await Self.loadWhisperKit(model: model, onProgress: onProgress, engine: self)
                finishLoading(loaded)
            } catch {
                finishLoading(nil)
                throw error
            }
        } else {
            var waited: UInt64 = 0
            let maxWait: UInt64 = 120_000_000_000
            while getPipe() == nil && waited < maxWait {
                try await Task.sleep(nanoseconds: 100_000_000)
                waited += 100_000_000
                try checkCancellation()
            }
            if getPipe() == nil {
                throw TranscriberError.modelNotReady
            }
        }

        guard let currentPipe = getPipe() else {
            throw TranscriberError.whisperKitFailed("Failed to initialize WhisperKit")
        }

        try checkCancellation()

        guard !samples.isEmpty else {
            throw TranscriberError.silentAudio
        }

        // Silence detection preserved from the audio-buffer path.
        // Fix 1.4: peak 0.5 s sub-window RMS (see peakWindowRMS) so a short
        // quiet utterance in a longer silent chunk isn't averaged away.
        let rms = Self.peakWindowRMS(samples)
        vlog("WhisperKit: transcribeSamples \(samples.count) samples, peak-window RMS = \(rms)")
        if rms < 0.005 {
            vlog("WhisperKit: transcribeSamples audio too quiet")
            throw TranscriberError.silentAudio
        }

        // Fix 1.5: confidence-gated, candidate-biased pre-detection (see the
        // dictation path) — applies to the call and file/CLI sample paths too.
        if !translate, forcedLanguage == nil, latched(for: latchKey) == nil {
            setLatched(await detectLanguageBiased(samples: samples, pipe: currentPipe), for: latchKey)
        }
        // Sticky language (Fix 1.1).
        let options: DecodingOptions
        if !translate, let forcedLanguage {
            options = DecodingOptions(
                task: .transcribe,
                language: forcedLanguage,
                usePrefillPrompt: true,
                detectLanguage: false,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )
        } else {
            options = makeDecodingOptions(translate: translate, latchKey: latchKey)
        }

        let results: [TranscriptionResult]
        do {
            results = try await withDeadline(seconds: 90) {
                try await currentPipe.transcribe(audioArray: samples, decodeOptions: options)
            }
        } catch is DeadlineExceeded {
            clearPipe()
            throw TranscriberError.transcriptionTimedOut
        }

        // Flatten WhisperKit results into our WhisperTranscription shape.
        var allSegments: [WhisperSegment] = []
        var detectedLang: String? = nil
        for r in results {
            if detectedLang == nil && !r.language.isEmpty {
                detectedLang = r.language
            }
            for seg in r.segments {
                // Strip tokens + drop empty/hallucination segments so they never
                // reach the diarized/timestamped/call transcripts.
                guard let clean = Self.cleanSegmentText(seg.text) else { continue }
                allSegments.append(WhisperSegment(
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: clean
                ))
            }
        }

        // Latch the detected language for the rest of this session (auto mode,
        // no per-call force).
        if forcedLanguage == nil {
            latchIfNeeded(translate: translate, latchKey: latchKey, detected: detectedLang)
        }

        // Build the plain transcript from the ALREADY-CLEANED segments (not the
        // raw result text) so a trailing hallucination filtered out of `segments`
        // is also gone from the joined string the CLI/file plain output uses.
        // Fall back to the raw join only if there were no usable segments.
        let joinedText = allSegments.isEmpty
            ? results.map { $0.text }.joined(separator: " ")
            : allSegments.map { $0.text }.joined(separator: " ")
        vlog("WhisperKit: transcribeSamples result segments=\(allSegments.count) text=[\(joinedText.count) chars]")

        return WhisperTranscription(
            text: joinedText,
            segments: allSegments,
            detectedLanguage: detectedLang
        )
    }

    // MARK: - Model Download + Load

    /// Download model with byte-level progress, then load.
    private static func loadWhisperKit(
        model: WhisperModel,
        onProgress: (@Sendable (TranscriberStatus) -> Void)?,
        engine: WhisperKitEngine
    ) async throws -> WhisperKit {
        vlog("WhisperKit: loading model '\(model.variant)'...")

        // Track download progress by polling the specific model folder size
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let modelDir = cacheRoot.appendingPathComponent("openai_whisper-\(model.variant)")
        let cacheDir = cacheRoot.appendingPathComponent(".cache")

        // #1 + #7: If model directory exists but previous load failed, it may be corrupted.
        // Validate by checking if directory size is reasonable vs expected.
        if FileManager.default.fileExists(atPath: modelDir.path) {
            let currentSize = directorySize(modelDir)
            let expectedSize = model.sizeBytes
            // If directory exists but is less than 50% of expected size, likely corrupted/partial.
            // 50% avoids deleting a nearly-complete download on resume (#104).
            if currentSize > 0 && currentSize < (expectedSize * 50 / 100) {
                vlog("WhisperKit: model directory looks incomplete (\(currentSize) bytes vs \(expectedSize) expected), deleting for clean retry")
                try? FileManager.default.removeItem(at: modelDir)
            }
        }

        // Fix 1.2 (offline start, BLOCKER): if the model is already fully on
        // disk, do NOT call WhisperKit.download — it hits the network and a
        // fully-downloaded model would fail to start with no connection. The
        // incomplete (<50%) directory was just deleted above, so a directory
        // that still exists with size ≥ 50% of expected is complete enough to
        // load directly. Skip the download branch and load from modelDir.
        let modelIsOnDisk: Bool = {
            guard FileManager.default.fileExists(atPath: modelDir.path) else { return false }
            let size = directorySize(modelDir)
            return size >= (model.sizeBytes * 50 / 100)
        }()

        try engine.checkCancellation()

        let folder: URL
        if modelIsOnDisk {
            // Fix 1.2: model already present — load it straight from disk, no
            // network. (The WhisperKit(config) path below sets download=false.)
            vlog("WhisperKit: model already on disk at \(modelDir.path), skipping download")
            folder = modelDir
        } else {
            // Check disk space before starting download. WhisperKit stages the model in
            // .cache/huggingface/download/.../weight.bin.<sha>.incomplete then moves into
            // place, and CoreML then compiles the model for local hardware. That pipeline
            // needs ~2.5x the model size; anything less gives the cryptic
            // NSCocoaErrorDomain Code=4 "couldn't be moved to weights" failure.
            // Use volumeAvailableCapacityForImportantUsage so we count purgeable space.
            let requiredBytes = UInt64(Double(model.sizeBytes) * Self.diskHeadroomMultiplier)
            let available: UInt64
            do {
                available = try Self.availableDiskSpace(at: modelDir)
            } catch {
                // Optimistic fallback: if we can't introspect the volume (unusual
                // sandbox, missing ancestor, network volume with broken URL keys),
                // skip the precheck and rely on classifyDownloadError to translate
                // the eventual POSIX/Cocoa out-of-space error to a clear message.
                // Losing the early warning is preferable to blocking a download
                // that could otherwise succeed.
                vlog("WhisperKit: availableDiskSpace failed for \(modelDir.path): \(error) — skipping precheck")
                available = UInt64.max
            }
            if available < requiredBytes {
                vlog("WhisperKit: insufficient disk space at \(modelDir.path): need \(requiredBytes), have \(available)")
                throw TranscriberError.insufficientDiskSpace(
                    needed: requiredBytes, available: available)
            }

            let expectedBytes = model.sizeBytes
            engine.setDownloading(true)

            let polling: Task<Void, Never>? = Task.detached { [weak engine] in
                while !Task.isCancelled {
                    guard let engine, !engine.isCancelled() else { break }
                    let modelBytes = Self.directorySize(modelDir)
                    let cacheBytes = Self.directorySize(cacheDir)
                    // #40: Cap at 95% so progress bar doesn't look stuck during model load phase
                    let progress = min(0.95, Double(modelBytes + cacheBytes) / Double(expectedBytes))
                    onProgress?(.downloadingModel(progress: progress))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            engine.setPollingTask(polling)

            // #2: Download with 5-minute timeout
            do {
                let timeoutSeconds = min(7200, max(600, UInt64(Double(model.sizeBytes) / 500_000)))
                folder = try await withDeadline(seconds: timeoutSeconds) {
                    try await WhisperKit.download(variant: model.variant)
                }
            } catch is DeadlineExceeded {
                polling?.cancel()
                engine.setDownloading(false)
                // Clean up partial download so next retry starts fresh
                let dir = model.modelDirectory
                if FileManager.default.fileExists(atPath: dir.path) {
                    vlog("WhisperKit: deleting partial model directory: \(dir.path)")
                    try? FileManager.default.removeItem(at: dir)
                }
                vlog("WhisperKit: download timed out")
                throw TranscriberError.modelDownloadFailed("Download timed out")
            } catch let error as TranscriberError {
                polling?.cancel()
                engine.setDownloading(false)
                vlog("WhisperKit: download failed: \(error)")
                throw error
            } catch {
                polling?.cancel()
                engine.setDownloading(false)
                vlog("WhisperKit: download failed: \(error)")
                // #9 + #10: Classify the error
                throw classifyDownloadError(error)
            }

            polling?.cancel()
            engine.setDownloading(false)
            vlog("WhisperKit: model downloaded to \(folder.path)")
        }

        onProgress?(.loadingModel)

        try engine.checkCancellation()

        vlog("WhisperKit: creating config, modelFolder=\(folder.path), calling WhisperKit(config)...")
        let modelPath = folder.path
        let kit: WhisperKit

        // CoreML compiles model for specific hardware (ANE/GPU) on first run.
        // No timeout: compilation is a local deterministic operation - it either
        // completes or fails with an error. Large models (3GB+) can take 10-15 min.
        do {
            let config = WhisperKitConfig()
            config.modelFolder = modelPath
            config.download = false
            kit = try await WhisperKit(config)
        } catch {
            vlog("WhisperKit: model load failed: \(error)")
            if let te = error as? TranscriberError {
                throw te
            }
            // Fix 1.2: this is the ONLY proven-corruption site — WhisperKit(config)
            // failed while loading a directory that is fully on disk (we either
            // skipped download because it was complete, or the download just
            // succeeded). CoreML couldn't compile/load the weights, so delete the
            // directory for a clean re-download. Never delete on cancellation,
            // network, or out-of-disk errors (those leave the weights intact).
            if Self.loadFailureWarrantsDeletion(error) {
                Transcriber.deleteModelDirectory(for: model)
            }
            // #28: Classify model load errors into actionable messages
            // NOTE: WhisperKit error messages may be generic; classification is best-effort
            // based on known error strings from CoreML / WhisperKit internals.
            throw classifyModelLoadError(error)
        }

        vlog("WhisperKit: model '\(model.variant)' loaded successfully")
        return kit
    }

    /// Whether a `WhisperKit(config)` load failure justifies deleting the model
    /// directory (Fix 1.2). True only for genuine load/compile corruption.
    /// False for cancellation, network errors (URLError / NSURLErrorDomain),
    /// and out-of-disk POSIX/Cocoa errors — those mean the on-disk weights are
    /// fine and a ~3 GB re-download would be wasteful and could fail offline.
    private static func loadFailureWarrantsDeletion(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is DeadlineExceeded { return false }
        if error is URLError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return false }
        // Out-of-disk: deleting wouldn't help and the model isn't corrupt.
        if ns.domain == NSPOSIXErrorDomain && ns.code == 28 /* ENOSPC */ { return false }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return false }
        // Walk one level of the error chain for a wrapped network/disk error.
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            if underlying is URLError { return false }
            let uns = underlying as NSError
            if uns.domain == NSURLErrorDomain { return false }
            if uns.domain == NSPOSIXErrorDomain && uns.code == 28 { return false }
            if uns.domain == NSCocoaErrorDomain && uns.code == NSFileWriteOutOfSpaceError { return false }
        }
        return true
    }

    // MARK: - Error Classification (#9, #10)

    /// Classify download errors into specific user-facing messages.
    private static func classifyDownloadError(_ error: Error, depth: Int = 0) -> TranscriberError {
        guard depth < 5 else { return .modelDownloadFailed("Check your internet connection and try again.") }

        // Check NSError for POSIX disk space errors
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 /* ENOSPC */ {
            return .modelDownloadFailed("Not enough disk space")
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return .modelDownloadFailed("Not enough disk space")
        }

        // Check URLError codes for network issues
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .modelDownloadFailed("No internet connection")
            case .timedOut:
                return .modelDownloadFailed("Download timed out")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .modelDownloadFailed("Server unavailable")
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return .modelDownloadFailed("Server unavailable")
            default:
                return .modelDownloadFailed(urlError.localizedDescription)
            }
        }

        // Walk the error chain for underlying URLError or disk errors
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return classifyDownloadError(underlying, depth: depth + 1)
        }

        return .modelDownloadFailed("Check your internet connection and try again.")
    }

    // MARK: - Model Load Error Classification (#28)

    /// Classify model load errors into actionable user-facing messages.
    private static func classifyModelLoadError(_ error: Error) -> TranscriberError {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("memory") || msg.contains("oom") || msg.contains("resource") {
            return .whisperKitFailed("Not enough memory. Try a smaller model.")
        }
        if msg.contains("corrupt") || msg.contains("invalid") || msg.contains("decode") {
            return .whisperKitFailed("Model may be corrupted. Delete and re-download.")
        }
        // Brief error context for unknown failures
        let brief = error.localizedDescription.prefix(120)
        return .whisperKitFailed("Model failed to load: \(brief)")
    }

    /// RMS (root mean square) of audio samples. Speech ~0.02-0.15, silence < 0.005.
    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }

    /// Fix 1.4: loudest ~0.5 s sub-window RMS. The plain whole-buffer RMS
    /// averages a short quiet utterance against a long silent tail and can
    /// false-trigger the silence gate, swallowing brief speech. Scanning
    /// sub-windows and taking the peak keeps the gate sensitive to short
    /// utterances while still rejecting genuine dead silence. Samples here are
    /// always 16 kHz mono, so 0.5 s = 8000 samples. Falls back to the
    /// whole-buffer RMS for inputs shorter than one window.
    private static func peakWindowRMS(_ samples: [Float], windowSamples: Int = 8000) -> Float {
        guard !samples.isEmpty else { return 0 }
        guard samples.count > windowSamples else { return calculateRMS(samples) }
        var peak: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(i + windowSamples, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let rms = sqrt(sum / Float(end - i))
            if rms > peak { peak = rms }
            i = end
        }
        return peak
    }

    /// Return the volume's available capacity in bytes, using the APFS-aware
    /// `volumeAvailableCapacityForImportantUsageKey` which accounts for
    /// purgeable space the kernel can free on demand.
    ///
    /// Side-effect-free: walks up the path to the first existing ancestor
    /// instead of creating directories. The caller passes a model-cache URL
    /// under `~/Documents/...` and that ancestor is guaranteed to exist on
    /// macOS, so the walk stops quickly and the resource-value query hits
    /// the correct volume.
    private static func availableDiskSpace(at url: URL) throws -> UInt64 {
        let fm = FileManager.default
        var candidate = url
        while !fm.fileExists(atPath: candidate.path) {
            // Safety: stop at the filesystem root so we never loop forever
            // if every component in the path is somehow missing.
            if candidate.path == "/" { break }
            candidate = candidate.deletingLastPathComponent()
        }
        let values = try candidate.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw TranscriberError.whisperKitFailed(
                "Could not read disk space at \(candidate.path)")
        }
        return UInt64(capacity)
    }

    #if DEBUG
    /// Test-only wrapper exposing the private disk-space helper.
    static func testAvailableDiskSpace(at url: URL) throws -> UInt64 {
        return try availableDiskSpace(at: url)
    }
    #endif

    /// Calculate total size of a directory in bytes.
    private static func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    // MARK: - Resampling

    /// Resample audio to 16kHz mono Float32 (WhisperKit requirement).
    private static func resampleTo16kHz(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let targetRate: Double = 16000
        let currentRate = buffer.format.sampleRate

        guard currentRate > 0 else {
            throw TranscriberError.whisperKitFailed("Invalid sample rate: 0")
        }
        if abs(currentRate - targetRate) < 1 { return buffer }

        vlog("Resampling \(currentRate)Hz -> \(targetRate)Hz")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
        ) else {
            throw TranscriberError.whisperKitFailed("Failed to create 16kHz format")
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw TranscriberError.whisperKitFailed("Failed to create audio converter")
        }

        let ratio = targetRate / currentRate
        let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1

        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            throw TranscriberError.whisperKitFailed("Failed to create resampling buffer")
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error = error {
            throw TranscriberError.whisperKitFailed("Resampling failed: \(error)")
        }

        return output
    }
}
