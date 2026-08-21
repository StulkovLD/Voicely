@preconcurrency import Speech
@preconcurrency import AVFoundation
import Darwin
import Foundation
@preconcurrency import WhisperKit

// MARK: - Debug Log

// NOTE (#107): vlog() opens/seeks/closes the file handle on every call.
// This is acceptable because it only runs in DEBUG builds and is not called
// in hot loops. If profiling shows I/O overhead, refactor to a retained handle.
func vlog(_ message: String) {
    #if DEBUG
    let line = "[\(Date())] \(message)\n"
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Voicely")
    let path = logDir.appendingPathComponent("debug.log").path
    // Ensure log directory exists
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDir.path)
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
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

/// Session-aware engine entry point used by the runtime scheduler. Engines that
/// do not keep per-session state can continue implementing `TranscriberEngine`;
/// `Transcriber` falls back to its original method for them.
protocol SessionTranscriberEngine: TranscriberEngine {
    func transcribe(
        audio: AVAudioPCMBuffer,
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> String
}

protocol PreloadableTranscriberEngine: TranscriberEngine {
    func preload() async throws
}

protocol CancelableTranscriberEngine: TranscriberEngine {
    func cancel()
}

protocol DownloadReportingTranscriberEngine: TranscriberEngine {
    var isCurrentlyDownloading: Bool { get }
}

protocol LanguageSessionResettable: TranscriberEngine {
    func resetLanguageSession()
}

/// Clears state for one logical transcription session without disturbing
/// queued or paused work owned by another session.
protocol SessionLanguageResettable: Sendable {
    func resetLanguageSession(_ sessionID: TranscriptionCoordinator.SessionID)
}

// MARK: - Model Selection

public struct WhisperModel: Sendable, Equatable {
    enum SharedDefaults {
        static let suiteName = "art.voicely.app"
        static var store: UserDefaults {
            UserDefaults(suiteName: suiteName) ?? .standard
        }
    }

    public enum Backend: Sendable, Equatable {
        case whisperKit
        case gigaAMV3E2ERNNT
        case gigaAMMultilingualCTC
    }

    public struct Capabilities: Sendable, Equatable {
        /// Nil means multilingual. A set means the backend is fixed to those
        /// language codes.
        public let supportedLanguages: Set<String>?
        public let supportsLanguageDetection: Bool
        public let supportsTranslationToEnglish: Bool
        public let minimumMacOSMajorVersion: Int

        public init(
            supportedLanguages: Set<String>?,
            supportsLanguageDetection: Bool,
            supportsTranslationToEnglish: Bool,
            minimumMacOSMajorVersion: Int = 14
        ) {
            self.supportedLanguages = supportedLanguages
            self.supportsLanguageDetection = supportsLanguageDetection
            self.supportsTranslationToEnglish = supportsTranslationToEnglish
            self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        }
    }

    public let variant: String
    public let displayName: String
    public let sizeLabel: String
    public let sizeBytes: UInt64
    public let minRAMGB: UInt64
    public let backend: Backend

    public var capabilities: Capabilities {
        switch backend {
        case .whisperKit:
            return Capabilities(
                supportedLanguages: nil,
                supportsLanguageDetection: true,
                supportsTranslationToEnglish: true
            )
        case .gigaAMV3E2ERNNT:
            return Capabilities(
                supportedLanguages: ["ru"],
                supportsLanguageDetection: false,
                supportsTranslationToEnglish: false,
                minimumMacOSMajorVersion: 15
            )
        case .gigaAMMultilingualCTC:
            // The charwise CTC model transcribes whichever of its languages it
            // hears; there is no language input, so this behaves as detection.
            return Capabilities(
                supportedLanguages: ["ru", "en", "kk", "ky", "uz"],
                supportsLanguageDetection: true,
                supportsTranslationToEnglish: false,
                minimumMacOSMajorVersion: 15
            )
        }
    }

    public func requestValidationError(
        translateToEnglish: Bool,
        language: String?
    ) -> String? {
        let capabilities = capabilities
        if translateToEnglish, !capabilities.supportsTranslationToEnglish {
            return "\(displayName) cannot translate to English. Select a Whisper model or use Russian transcription."
        }
        if let language,
           let supported = capabilities.supportedLanguages,
           !supported.contains(language.lowercased()) {
            return "\(displayName) supports only: \(supported.sorted().joined(separator: ", "))."
        }
        return nil
    }

    public static let all: [WhisperModel] = [
        WhisperModel(variant: "gigaam-v3-e2e-rnnt", displayName: "GigaAM V3 RU", sizeLabel: "~426 MB", sizeBytes: 430_000_000, minRAMGB: 8, backend: .gigaAMV3E2ERNNT),
        WhisperModel(variant: "gigaam-multilingual-ctc", displayName: "GigaAM Multilingual", sizeLabel: "~421 MB", sizeBytes: 442_100_000, minRAMGB: 8, backend: .gigaAMMultilingualCTC),
        WhisperModel(variant: "large-v3-v20240930_turbo_632MB", displayName: "Large V3 Turbo Q", sizeLabel: "~632 MB", sizeBytes: 650_000_000, minRAMGB: 8, backend: .whisperKit),
        WhisperModel(variant: "large-v3_turbo", displayName: "Large V3 Turbo", sizeLabel: "~3 GB", sizeBytes: 3_200_000_000, minRAMGB: 24, backend: .whisperKit),
        WhisperModel(variant: "medium", displayName: "Medium", sizeLabel: "~1.5 GB", sizeBytes: 1_500_000_000, minRAMGB: 16, backend: .whisperKit),
    ]

    public static var systemRAMGB: UInt64 {
        ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
    }

    public var ramRequirementLabel: String {
        if minRAMGB >= 24 {
            return "24+ GB RAM"
        }
        return "\(minRAMGB) GB RAM"
    }

    /// What sets this model apart from the others on offer. Anything true of
    /// every model is noise the reader has to look past to find the difference:
    /// they all punctuate, and `available()` already filters by RAM, so a model
    /// the Mac cannot run is never shown in the first place.
    ///
    /// The two GigaAM models are not ranked against each other — we have no
    /// measurement saying which is sharper in Russian — so they differ by
    /// coverage, not by claim.
    public var onboardingHint: String? {
        switch backend {
        case .gigaAMV3E2ERNNT:
            return "Best in Russian · RU only"
        case .gigaAMMultilingualCTC:
            return "Best in Russian · RU/EN/KK/KY/UZ"
        case .whisperKit:
            return "Any language"
        }
    }

    public func userFacingLabel(isRecommended: Bool) -> String {
        var label = "\(displayName) · \(sizeLabel)"
        if let hint = onboardingHint {
            label += " · \(hint)"
        }
        if isRecommended {
            label += " · Recommended"
        }
        return label
    }

    public static func available(forSystemRAMGB ram: UInt64) -> [WhisperModel] {
        all.filter { $0.minRAMGB <= ram }
    }

    public static func available() -> [WhisperModel] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return available(forSystemRAMGB: systemRAMGB).filter {
            $0.isSupported(on: version)
        }
    }

    public func isSupported(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= capabilities.minimumMacOSMajorVersion
    }

    /// Available disk space in bytes, or nil if the check fails.
    private static var availableDiskBytes: UInt64? {
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        guard let free = attrs?[.systemFreeSize] as? UInt64 else { return nil }
        return free
    }

    public static func recommended(
        forSystemRAMGB ram: UInt64,
        availableDiskBytes disk: UInt64?
    ) -> WhisperModel {
        let preferredVariants: [String]
        if ram >= 24 {
            preferredVariants = [
                "large-v3_turbo",
                "medium",
                "large-v3-v20240930_turbo_632MB",
                "gigaam-v3-e2e-rnnt",
            ]
        } else if ram >= 16 {
            preferredVariants = [
                "medium",
                "large-v3-v20240930_turbo_632MB",
                "gigaam-v3-e2e-rnnt",
            ]
        } else {
            preferredVariants = [
                "large-v3-v20240930_turbo_632MB",
                "gigaam-v3-e2e-rnnt",
            ]
        }

        let candidates = preferredVariants.compactMap { variant in
            all.first(where: { $0.variant == variant && $0.minRAMGB <= ram })
        }

        if let disk {
            for model in candidates where disk >= model.sizeBytes * 3 / 2 {
                return model
            }
        }

        return candidates.first ?? all[0]
    }

    public static func recommended() -> WhisperModel {
        recommended(forSystemRAMGB: systemRAMGB, availableDiskBytes: availableDiskBytes)
    }

    public static func savedSelection() -> WhisperModel? {
        savedSelection(in: SharedDefaults.store)
    }

    public static func savedSelection(in defaults: UserDefaults) -> WhisperModel? {
        savedSelection(
            in: defaults,
            systemRAMGB: systemRAMGB,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    public static func savedSelection(
        in defaults: UserDefaults,
        systemRAMGB: UInt64,
        operatingSystemVersion: OperatingSystemVersion
    ) -> WhisperModel? {
        guard let saved = defaults.string(forKey: "whisperModel") else { return nil }
        guard let model = all.first(where: { $0.variant == saved }) else { return nil }
        guard model.minRAMGB <= systemRAMGB,
              model.isSupported(on: operatingSystemVersion) else {
            return nil
        }
        return model
    }

    public static func hasSavedSelection() -> Bool {
        hasSavedSelection(in: SharedDefaults.store)
    }

    public static func hasSavedSelection(in defaults: UserDefaults) -> Bool {
        savedSelection(in: defaults) != nil
    }

    public static func clearSavedSelection() {
        clearSavedSelection(in: SharedDefaults.store)
    }

    static func clearSavedSelection(in defaults: UserDefaults) {
        defaults.removeObject(forKey: "whisperModel")
    }

    /// Resolve model storage without consulting the process working directory.
    /// A checkout-local GigaAM path is available only in debug builds and only
    /// through an explicit, identity-checked environment override.
    func resolvedModelDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch backend {
        case .whisperKit:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
                .appendingPathComponent("openai_whisper-\(variant)")
        case .gigaAMV3E2ERNNT:
            #if DEBUG
            if let override = environment["VOICELY_GIGAAM_DEV_REPO_ROOT"],
               let repoRoot = Self.validatedDevelopmentRepositoryRoot(override) {
                return repoRoot
                    .appendingPathComponent(".local/models/gigaam/v3-e2e-rnnt")
            }
            #endif
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml")
        case .gigaAMMultilingualCTC:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/voicely/models/gigaam-multilingual-ctc")
        }
    }

    /// Model directory on disk.
    public var modelDirectory: URL {
        resolvedModelDirectory()
    }

    #if DEBUG
    private static func validatedDevelopmentRepositoryRoot(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let supplied = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let canonical = supplied.resolvingSymlinksInPath().standardizedFileURL
        guard supplied.path == canonical.path,
              secureItem(at: canonical, expectedType: .typeDirectory),
              secureItem(at: canonical.appendingPathComponent(".git"), expectedType: nil),
              secureItem(at: canonical.appendingPathComponent("Package.swift"), expectedType: .typeRegular),
              secureItem(at: canonical.appendingPathComponent("Sources/VoicelyCore/GigaAMEngine.swift"), expectedType: .typeRegular),
              secureItem(at: canonical.appendingPathComponent("Sources/VoicelyCLI/Voicely.swift"), expectedType: .typeRegular),
              let package = try? String(
                contentsOf: canonical.appendingPathComponent("Package.swift"),
                encoding: .utf8
              ),
              package.contains("name: \"Voicely\""),
              package.contains("name: \"VoicelyCore\"") else {
            return nil
        }
        return canonical
    }

    private static func secureItem(
        at url: URL,
        expectedType: FileAttributeType?
    ) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            return false
        }
        return expectedType == nil || attributes[.type] as? FileAttributeType == expectedType
    }
    #endif

    /// Filesystem path of `modelDirectory`. Public so the headless CLI can report
    /// whether a model is already downloaded (`voicely status`) without exposing
    /// the internal URL helper.
    public var modelDirectoryPath: String { modelDirectory.path }

    public static func == (lhs: WhisperModel, rhs: WhisperModel) -> Bool {
        lhs.variant == rhs.variant
    }
}

/// Immutable request state captured before a request waits for the shared ASR
/// lease. Later menu or runtime mutations cannot change the model, engine,
/// language, translation mode, session identity, or priority of queued work.
public struct TranscriptionSession: Sendable {
    public let id: TranscriptionCoordinator.SessionID
    public let priority: TranscriptionCoordinator.Priority
    public let model: WhisperModel
    public let translateToEnglish: Bool
    public let preferredLanguage: String?

    fileprivate let engine: any TranscriberEngine
    fileprivate let coordinator: TranscriptionCoordinator
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
    typealias EngineFactory = @Sendable (
        WhisperModel,
        (@Sendable (TranscriberStatus) -> Void)?
    ) -> any TranscriberEngine

    private var engine: (any TranscriberEngine)?
    private let locale: Locale
    private let engineFactory: EngineFactory
    private var legacySessionID = TranscriptionCoordinator.SessionID()

    /// Process/runtime-level scheduler shared with file and CLI consumers.
    public let coordinator: TranscriptionCoordinator

    public private(set) var selectedModel: WhisperModel
    public var translateToEnglish = false

    /// Forced transcription language ("ru"/"en") set from the Language menu.
    /// `nil` = auto-detect with a per-session latch (Fix 1.1). When set, every
    /// decode is hard-forced to this language with no detection. Pushed onto
    /// the engine before each call (mirrors how `translateToEnglish` is passed).
    public var preferredLanguage: String?

    public var onProgress: (@Sendable (TranscriberStatus) -> Void)?

    public init(
        locale: Locale = .current,
        coordinator: TranscriptionCoordinator = TranscriptionCoordinator()
    ) {
        self.locale = locale
        self.coordinator = coordinator
        self.engineFactory = Self.makeProductionEngine
        self.selectedModel = WhisperModel.savedSelection() ?? WhisperModel.recommended()
    }

    init(
        locale: Locale = .current,
        coordinator: TranscriptionCoordinator,
        selectedModel: WhisperModel,
        engineFactory: @escaping EngineFactory
    ) {
        self.locale = locale
        self.coordinator = coordinator
        self.engineFactory = engineFactory
        self.selectedModel = selectedModel
    }

    public var hasSavedModelSelection: Bool {
        WhisperModel.hasSavedSelection()
    }

    /// Exposes the underlying engine so specialized call paths (file
    /// transcription) can conditionally cast to feature-specific protocols
    /// like `SampleTranscribing`. Nil until the engine has been loaded.
    public var currentEngine: (any TranscriberEngine)? { engine }

    /// Capture all mutable request settings and the resolved engine before the
    /// request can suspend in the coordinator queue.
    public func makeSession(
        id: TranscriptionCoordinator.SessionID = TranscriptionCoordinator.SessionID(),
        priority: TranscriptionCoordinator.Priority
    ) throws -> TranscriptionSession {
        try makeSession(
            id: id,
            priority: priority,
            language: preferredLanguage
        )
    }

    /// A `SampleTranscribing` view pinned to one immutable session. File and
    /// CLI consumers can keep their existing chunk-processing interfaces while
    /// every chunk still goes through the shared runtime coordinator.
    public func sampleTranscriber(
        for session: TranscriptionSession
    ) -> any SampleTranscribing {
        CoordinatedSampleTranscriber(session: session)
    }

    /// Change model. Resets engine so next transcription downloads/loads new model.
    public func selectModel(_ model: WhisperModel) {
        guard model != selectedModel || engine == nil else { return }
        cancelCurrentTask()
        selectedModel = model
        engine = nil
        WhisperModel.SharedDefaults.store.set(model.variant, forKey: "whisperModel")
        vlog("Model changed to '\(model.variant)'")
    }

    /// Resolve engine. WhisperKit is primary (SFSpeechRecognizer broken on macOS 26).
    private func resolveEngine() -> any TranscriberEngine {
        if let engine = self.engine { return engine }

        let e = engineFactory(selectedModel, onProgress)
        self.engine = e
        return e
    }

    nonisolated private static func makeProductionEngine(
        model: WhisperModel,
        onProgress: (@Sendable (TranscriberStatus) -> Void)?
    ) -> any TranscriberEngine {
        switch model.backend {
        case .whisperKit:
            vlog("Using WhisperKit, model: \(model.variant) (RAM: \(WhisperModel.systemRAMGB) GB)")
            return WhisperKitEngine(model: model, onProgress: onProgress)
        case .gigaAMV3E2ERNNT:
            vlog("Using GigaAM v3, model: \(model.variant) (RAM: \(WhisperModel.systemRAMGB) GB)")
            return GigaAMEngine(model: model, onProgress: onProgress)
        case .gigaAMMultilingualCTC:
            vlog("Using GigaAM Multilingual CTC, model: \(model.variant) (RAM: \(WhisperModel.systemRAMGB) GB)")
            return GigaAMCTCEngine(
                model: model,
                onProgress: onProgress,
                punctuator: CoreMLPunctuationRestorer()
            )
        }
    }

    /// Rotate the compatibility session used by existing app entry points.
    /// Explicit `TranscriptionSession` callers should reset that session
    /// directly when it ends.
    public func resetLanguageSession() {
        let completedSessionID = legacySessionID
        legacySessionID = TranscriptionCoordinator.SessionID()

        if let scoped = engine as? any SessionLanguageResettable {
            scoped.resetLanguageSession(completedSessionID)
        } else {
            (engine as? any LanguageSessionResettable)?.resetLanguageSession()
        }
    }

    public func resetLanguageSession(_ session: TranscriptionSession) {
        if let scoped = session.engine as? any SessionLanguageResettable {
            scoped.resetLanguageSession(session.id)
        } else {
            (session.engine as? any LanguageSessionResettable)?.resetLanguageSession()
        }
    }

    /// Whether a download is currently in progress.
    public var isDownloading: Bool {
        guard let downloadable = engine as? any DownloadReportingTranscriberEngine else { return false }
        return downloadable.isCurrentlyDownloading
    }

    /// Cancel any in-progress download, model load, or transcription.
    public func cancelCurrentTask() {
        guard let cancelable = engine as? any CancelableTranscriberEngine else { return }
        cancelable.cancel()
    }

    /// Cancel and reset engine without deleting downloaded model files.
    public func cancelAndReset() {
        cancelCurrentTask()
        engine = nil
    }

    /// Cancel download and clean up partial files. Resets engine so next attempt starts fresh.
    ///
    /// `model` is explicit because the selection can move on while a cancel is
    /// still draining: reading `selectedModel` here would delete whichever model
    /// the user picked next, not the one they cancelled.
    public func cancelAndCleanup(model: WhisperModel) {
        cancelCurrentTask()
        // Delete partial model files
        let dir = model.modelDirectory
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
        let session = TranscriptionSession(
            id: TranscriptionCoordinator.SessionID(),
            priority: .background,
            model: selectedModel,
            translateToEnglish: false,
            preferredLanguage: nil,
            engine: resolveEngine(),
            coordinator: coordinator
        )
        try await preloadModel(for: session)
    }

    public func preloadModel(for session: TranscriptionSession) async throws {
        guard let preloadable = session.engine as? any PreloadableTranscriberEngine else {
            return
        }
        do {
            try await session.coordinator.withLease(
                sessionID: session.id,
                priority: .background
            ) {
                try await preloadable.preload()
            }
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
        let session = try makeSession(id: legacySessionID, priority: .live)
        return try await transcribe(audio: audio, session: session)
    }

    public func transcribe(
        audio: AVAudioPCMBuffer,
        session: TranscriptionSession
    ) async throws -> String {

        // WhisperKit doesn't need Speech Recognition permission (runs on CoreML).
        // Authorization check skipped - only microphone permission is required (handled by Recorder).

        onProgress?(.processing)

        let raw: String
        do {
            let engine = session.engine
            raw = try await session.coordinator.withLease(
                sessionID: session.id,
                priority: session.priority
            ) {
                if let sessionEngine = engine as? any SessionTranscriberEngine {
                    return try await sessionEngine.transcribe(
                        audio: audio,
                        translate: session.translateToEnglish,
                        language: session.preferredLanguage,
                        sessionID: session.id
                    )
                }
                return try await engine.transcribe(
                    audio: audio,
                    translate: session.translateToEnglish,
                    language: session.preferredLanguage
                )
            }
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
        startOffsetSec: Double,
        forcedLanguage: String? = nil
    ) async throws -> [DialogueSegment] {
        guard !samples.isEmpty else { return [] }
        let session = try makeSession(
            id: legacySessionID,
            priority: .live,
            language: forcedLanguage ?? preferredLanguage
        )
        return try await transcribeChannel(
            samples: samples,
            sampleRate: sampleRate,
            speaker: speaker,
            startOffsetSec: startOffsetSec,
            session: session
        )
    }

    public func transcribeChannel(
        samples: [Float],
        sampleRate: Double,
        speaker: CallSpeaker,
        startOffsetSec: Double,
        session: TranscriptionSession
    ) async throws -> [DialogueSegment] {
        guard !samples.isEmpty else { return [] }

        let resampled = try Self.resampleSamples(samples, fromRate: sampleRate, toRate: 16000)
        guard !resampled.isEmpty else { return [] }

        onProgress?(.processing)

        let result: WhisperTranscription
        do {
            let engine = session.engine
            result = try await session.coordinator.withLease(
                sessionID: session.id,
                priority: session.priority
            ) {
                if let whisper = engine as? WhisperKitEngine {
                    return try await whisper.transcribeChannelSamples(
                        resampled,
                        translate: session.translateToEnglish,
                        speaker: speaker,
                        forcedLanguage: session.preferredLanguage,
                        sessionID: session.id
                    )
                }
                if let sessionEngine = engine as? any SessionSampleTranscribing {
                    return try await sessionEngine.transcribeSamples(
                        resampled,
                        translate: session.translateToEnglish,
                        language: session.preferredLanguage,
                        sessionID: session.id
                    )
                }
                if let sampleEngine = engine as? any SampleTranscribing {
                    return try await sampleEngine.transcribeSamples(
                        resampled,
                        translate: session.translateToEnglish,
                        language: session.preferredLanguage
                    )
                }
                return WhisperTranscription(text: "", segments: [], detectedLanguage: nil)
            }
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
        let input = SingleBufferAudioConverterInput(srcBuf)
        converter.convert(to: dstBuf, error: &err) { _, outStatus in
            input.provide(status: outStatus)
        }
        if let err { throw TranscriberError.whisperKitFailed("resample failed: \(err)") }
        guard let data = dstBuf.floatChannelData?[0] else {
            throw TranscriberError.whisperKitFailed("resample output missing data")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(dstBuf.frameLength)))
    }

    private func makeSession(
        id: TranscriptionCoordinator.SessionID,
        priority: TranscriptionCoordinator.Priority,
        language: String?
    ) throws -> TranscriptionSession {
        let model = selectedModel
        let translate = translateToEnglish
        if let message = model.requestValidationError(
            translateToEnglish: translate,
            language: language
        ) {
            throw TranscriberError.unsupportedModelCapability(message)
        }

        return TranscriptionSession(
            id: id,
            priority: priority,
            model: model,
            translateToEnglish: translate,
            preferredLanguage: language,
            engine: resolveEngine(),
            coordinator: coordinator
        )
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

    // MARK: - Decoder-output filter

    private static func filterHallucinations(_ text: String, audioDuration: Double) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if isHallucinationText(trimmed) { return "" }
        return trimmed
    }

    /// Reject output that contains no letters or numbers. Phrase blacklists are
    /// intentionally forbidden here: ordinary speech such as "Спасибо", "Bye",
    /// or "Thank you" is valid product data and cannot be classified from text
    /// alone. Silence/no-speech decisions happen from audio/model evidence before
    /// this stage. `nonisolated` so every output surface shares the same rule.
    nonisolated static func isHallucinationText(_ trimmed: String) -> Bool {
        !trimmed.unicodeScalars.contains {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
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
    case unsupportedModelCapability(String)

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
        case .unsupportedModelCapability(let message):
            return message
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

/// Sample entry point with a stable language-state namespace.
protocol SessionSampleTranscribing: SampleTranscribing {
    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> WhisperTranscription
}

/// Adapts an immutable session back to the existing chunk-oriented protocol.
/// Call-site arguments are intentionally ignored: the session snapshot is the
/// source of truth once work has entered the runtime queue.
private final class CoordinatedSampleTranscriber: SampleTranscribing {
    private let session: TranscriptionSession

    init(session: TranscriptionSession) {
        self.session = session
    }

    func transcribeSamples(
        _ samples: [Float],
        translate _: Bool,
        language _: String?
    ) async throws -> WhisperTranscription {
        guard let sampleEngine = session.engine as? any SampleTranscribing else {
            throw TranscriberError.modelNotReady
        }

        return try await session.coordinator.withLease(
            sessionID: session.id,
            priority: session.priority
        ) {
            if let sessionEngine = sampleEngine as? any SessionSampleTranscribing {
                return try await sessionEngine.transcribeSamples(
                    samples,
                    translate: session.translateToEnglish,
                    language: session.preferredLanguage,
                    sessionID: session.id
                )
            }
            return try await sampleEngine.transcribeSamples(
                samples,
                translate: session.translateToEnglish,
                language: session.preferredLanguage
            )
        }
    }
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
            let state = SpeechRecognitionCompletionState()

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    let (claimed, partial) = state.claimCompletion()
                    guard claimed else { return }
                    if !partial.isEmpty {
                        continuation.resume(returning: partial)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    guard state.storePartial(text) else { return }
                    if result.isFinal {
                        guard state.claimFinal() else { return }
                        continuation.resume(returning: text)
                    }
                }
            }

            // Timeout: if recognition hasn't completed in 30s, use best partial result
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                let (claimed, partial) = state.claimCompletion()
                guard claimed else { return }
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
struct DeadlineExceeded: Error {}

private final class SpeechRecognitionCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var partial = ""

    func storePartial(_ value: String) -> Bool {
        lock.withLock {
            guard !finished else { return false }
            partial = value
            return true
        }
    }

    func claimFinal() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    func claimCompletion() -> (Bool, String) {
        lock.withLock {
            guard !finished else { return (false, "") }
            finished = true
            return (true, partial)
        }
    }
}

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
///
/// Note the deadline frees the *caller* — it cannot abort an in-flight CoreML/ANE
/// call. That is exactly what is needed here: the coordinator lease is released on
/// unwind, so one wedged inference stops holding every later request hostage.
func withDeadline<T>(
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

final class WhisperKitEngine: @unchecked Sendable, SessionTranscriberEngine, SessionSampleTranscribing, PreloadableTranscriberEngine, CancelableTranscriberEngine, DownloadReportingTranscriberEngine, LanguageSessionResettable, SessionLanguageResettable {
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
    private let compatibilitySessionID = TranscriptionCoordinator.SessionID()

    /// Whether a model download is currently in progress.
    private var isDownloadInProgress = false

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
        case dictation(TranscriptionCoordinator.SessionID)
        case samples(TranscriptionCoordinator.SessionID)
        case channel(TranscriptionCoordinator.SessionID, CallSpeaker)

        var sessionID: TranscriptionCoordinator.SessionID {
            switch self {
            case .dictation(let sessionID), .samples(let sessionID):
                return sessionID
            case .channel(let sessionID, _):
                return sessionID
            }
        }
    }

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
    /// Compatibility reset for legacy callers that do not supply a session ID.
    func resetLanguageSession() {
        pipeLock.lock()
        latchedLanguage.removeAll()
        pipeLock.unlock()
        vlog("WhisperKit: language session reset")
    }

    func resetLanguageSession(_ sessionID: TranscriptionCoordinator.SessionID) {
        pipeLock.lock()
        latchedLanguage = latchedLanguage.filter { $0.key.sessionID != sessionID }
        pipeLock.unlock()
        vlog("WhisperKit: language session reset \(sessionID)")
    }

    /// Build decode options applying the sticky-language contract (Fix 1.1):
    /// - translate: task=.translate, language=nil, prefill on, detect off (unchanged).
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
        let pinned = latched(for: latchKey)
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
        guard !translate else { return }
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

    /// The user's likely languages: preferred system languages, current locale,
    /// plus English as a safe fallback.
    nonisolated static func candidateLanguages() -> Set<String> {
        var set: Set<String> = ["en"]
        if let code = Locale.current.language.languageCode?.identifier.lowercased(),
           !code.isEmpty {
            set.insert(code)
        }
        for preferred in Locale.preferredLanguages {
            if let code = Locale(identifier: preferred).language.languageCode?.identifier.lowercased(),
               !code.isEmpty {
                set.insert(code)
            }
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
    ///
    /// This only latches the flag `checkCancellation` reads between phases. The
    /// download itself stops because `preloadTask.cancel()` propagates into the
    /// installer's transport — this engine holds no handle on that transfer.
    func cancel() {
        pipeLock.lock()
        cancelled = true
        isDownloadInProgress = false
        pipeLock.unlock()
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
        try await transcribe(
            audio: audio,
            translate: translate,
            language: language,
            sessionID: compatibilitySessionID
        )
    }

    func transcribe(
        audio: AVAudioPCMBuffer,
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> String {
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
        // arg, when non-nil, is treated as a hard per-session force.
        let latchKey: LatchKey = .dictation(sessionID)
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

        // Build from cleaned segments (strip decoder tokens and empty symbolic
        // output) so every surface uses the same evidence-based filter.
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

    /// Clean one raw decoder segment: strip special tokens, then return nil only
    /// when no linguistic/numeric content remains. Both joined and timestamped
    /// outputs use this path.
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
        try await transcribeSamples(
            samples,
            translate: translate,
            language: language,
            sessionID: compatibilitySessionID
        )
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> WhisperTranscription {
        try await transcribeSamplesCore(
            samples,
            translate: translate,
            latchKey: .samples(sessionID),
            forcedLanguage: language
        )
    }

    /// Per-channel call path (Fix 1.1): each speaker latches independently so
    /// the other party speaking a different language never flips the mic's
    /// detected language. Shares the exact decode core with `transcribeSamples`.
    func transcribeChannelSamples(
        _ samples: [Float],
        translate: Bool,
        speaker: CallSpeaker,
        forcedLanguage: String? = nil
    ) async throws -> WhisperTranscription {
        try await transcribeChannelSamples(
            samples,
            translate: translate,
            speaker: speaker,
            forcedLanguage: forcedLanguage,
            sessionID: compatibilitySessionID
        )
    }

    func transcribeChannelSamples(
        _ samples: [Float],
        translate: Bool,
        speaker: CallSpeaker,
        forcedLanguage: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> WhisperTranscription {
        try await transcribeSamplesCore(
            samples,
            translate: translate,
            latchKey: .channel(sessionID, speaker),
            forcedLanguage: forcedLanguage
        )
    }

    /// Shared decode core for the sample-based paths. `latchKey` selects which
    /// independent language latch this session uses; `forcedLanguage`, when
    /// non-nil, hard-forces that language for this single call (no detect, no
    /// latch) and overrides the session latch.
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
                // Strip tokens and empty symbolic segments before publishing.
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

        // Build the plain transcript from the already-cleaned segments so every
        // output surface follows the same token/symbol filtering rule.
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

        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let folder = cacheRoot.appendingPathComponent("openai_whisper-\(model.variant)")

        guard let assets = WhisperKitAssetCatalog.assets(forVariant: model.variant) else {
            throw TranscriberError.modelDownloadFailed("No pinned assets for \(model.variant)")
        }

        try engine.checkCancellation()

        // CoreML compiles the model for local hardware after install, and that
        // pipeline needs headroom beyond the assets themselves; anything less
        // gives the cryptic NSCocoaErrorDomain Code=4 "couldn't be moved to
        // weights" failure. The installer already counts the bytes it is about
        // to fetch, so only the surplus is declared here.
        let compileHeadroom = Int64(Double(model.sizeBytes) * (Self.diskHeadroomMultiplier - 1))

        // Fix 1.2 (offline start, BLOCKER): `install` returns without touching
        // the network once every pinned asset is present and intact, so a
        // fully-downloaded model still starts with no connection.
        engine.setDownloading(true)
        do {
            try await WhisperKitAssetInstaller.install(
                variant: model.variant,
                sourceRoot: folder,
                assets: assets,
                revision: WhisperKitAssetCatalog.revision,
                additionalRequiredBytes: compileHeadroom,
                onBytes: { written, expected in
                    guard expected > 0 else { return }
                    // #40: Cap at 95% so the bar doesn't look stuck during the load phase
                    let progress = min(0.95, Double(written) / Double(expected))
                    onProgress?(.downloadingModel(progress: progress))
                }
            )
            engine.setDownloading(false)
        } catch {
            engine.setDownloading(false)
            vlog("WhisperKit: install failed: \(error)")
            throw classifyInstallError(error)
        }

        try engine.checkCancellation()

        // HubApi staged downloads here and kept a .metadata tree per file. The
        // installer replaced it, so this is dead weight — ~490 MB for medium.
        let staleHubCache = cacheRoot
            .appendingPathComponent(".cache/huggingface/download")
            .appendingPathComponent("openai_whisper-\(model.variant)")
        if FileManager.default.fileExists(atPath: staleHubCache.path) {
            vlog("WhisperKit: removing stale HubApi cache at \(staleHubCache.path)")
            try? FileManager.default.removeItem(at: staleHubCache)
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

    /// Translate an installer failure for the user. Cancellation and disk-space
    /// errors carry meaning the generic network classifier would flatten, so
    /// they are mapped first; everything else is a transport failure.
    private static func classifyInstallError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let assetError = error as? GigaAMAssetDownloadError {
            switch assetError {
            case let .insufficientDiskSpace(requiredBytes, availableBytes):
                return TranscriberError.insufficientDiskSpace(
                    needed: UInt64(max(0, requiredBytes)),
                    available: UInt64(max(0, availableBytes))
                )
            case .sizeMismatch, .checksumMismatch:
                return TranscriberError.modelDownloadFailed(
                    "Downloaded model failed its integrity check. Try again."
                )
            case .assetUnavailable:
                return TranscriberError.modelDownloadFailed(
                    "Check your internet connection and try again."
                )
            default:
                return TranscriberError.modelDownloadFailed(
                    assetError.errorDescription ?? "Model install failed"
                )
            }
        }
        if let transcriberError = error as? TranscriberError { return transcriberError }
        return classifyDownloadError(error)
    }

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

    // MARK: - Resampling

    /// Resample audio to 16kHz mono Float32 (WhisperKit requirement).
    static func resampleTo16kHz(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
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
        let input = SingleBufferAudioConverterInput(buffer)
        converter.convert(to: output, error: &error) { _, outStatus in
            input.provide(status: outStatus)
        }
        if let error = error {
            throw TranscriberError.whisperKitFailed("Resampling failed: \(error)")
        }

        return output
    }
}
