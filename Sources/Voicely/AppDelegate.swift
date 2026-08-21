import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import VoicelyCore

enum CallAudioFileWindowReader {
    static let maximumWindowSeconds = CallAudioProcessing.systemASRMaxWindowSeconds

    enum ReaderError: Error, LocalizedError {
        case invalidRange
        case unsupportedFormat
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .invalidRange:
                return "Invalid call audio window."
            case .unsupportedFormat:
                return "Unsupported call audio format."
            case .bufferAllocationFailed:
                return "Could not allocate a bounded call audio window."
            }
        }
    }

    static func durationSeconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        guard rate.isFinite, rate > 0 else { throw ReaderError.unsupportedFormat }
        return Double(file.length) / rate
    }

    /// Read, downmix, and resample one bounded interval. At no point does this
    /// allocate storage proportional to the complete call duration.
    static func readMono16k(
        from url: URL,
        startTime: Double,
        endTime: Double
    ) throws -> [Float] {
        guard startTime.isFinite,
              endTime.isFinite,
              startTime >= 0,
              endTime > startTime else { throw ReaderError.invalidRange }

        let boundedEnd = min(endTime, startTime + maximumWindowSeconds)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite,
              rate > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0 else { throw ReaderError.unsupportedFormat }

        // Quantize both boundaries on the same absolute source-frame grid.
        // Using floor for the start and ceil for the end makes adjacent windows
        // overlap whenever their shared boundary is fractional.
        let startFrame = sourceFrameBoundary(
            at: startTime,
            sampleRate: rate,
            fileLength: file.length
        )
        let requestedEndFrame = sourceFrameBoundary(
            at: boundedEnd,
            sampleRate: rate,
            fileLength: file.length
        )
        guard requestedEndFrame > startFrame else { return [] }
        let frameCount64 = requestedEndFrame - startFrame
        guard frameCount64 <= AVAudioFramePosition(UInt32.max) else {
            throw ReaderError.invalidRange
        }
        let mono = try readMonoFrames(
            from: file,
            format: format,
            startFrame: startFrame,
            endFrame: requestedEndFrame
        )
        guard !mono.isEmpty else { return [] }

        var resampled = try CallAudioProcessing.resampleMono(
            mono,
            fromRate: rate
        )
        let maxSamples = Int(maximumWindowSeconds * CallAudioProcessing.targetRate)
        let actualEndFrame = startFrame + AVAudioFramePosition(mono.count)
        let expectedSamples = min(
            maxSamples,
            targetFrameCount(
                startFrame: startFrame,
                endFrame: actualEndFrame,
                sourceRate: rate
            )
        )
        if resampled.count > expectedSamples {
            resampled.removeLast(resampled.count - expectedSamples)
        } else if resampled.count < expectedSamples {
            // Some converter configurations retain a bounded trailing prime.
            // Preserve the requested timeline instead of shortening the window.
            resampled.append(contentsOf: repeatElement(
                0,
                count: expectedSamples - resampled.count
            ))
        }
        return resampled
    }

    private static func sourceFrameBoundary(
        at time: Double,
        sampleRate: Double,
        fileLength: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        let duration = Double(fileLength) / sampleRate
        guard time < duration else { return fileLength }
        return min(
            fileLength,
            max(0, AVAudioFramePosition(
                (time * sampleRate).rounded(.toNearestOrAwayFromZero)
            ))
        )
    }

    /// AVAudioFile may return a packet-aligned short read before EOF. Keep
    /// reading until the complete bounded interval is materialized or the file
    /// actually stops producing frames.
    private static func readMonoFrames(
        from file: AVAudioFile,
        format: AVAudioFormat,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) throws -> [Float] {
        let requestedCount = endFrame - startFrame
        guard requestedCount > 0 else { return [] }

        var mono: [Float] = []
        mono.reserveCapacity(Int(requestedCount))
        file.framePosition = startFrame
        let channelCount = Int(format.channelCount)
        let gain = 1 / Float(channelCount)
        var remaining = requestedCount

        while remaining > 0 {
            let capacity = AVAudioFrameCount(min(remaining, 65_536))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else { throw ReaderError.bufferAllocationFailed }
            try file.read(into: buffer, frameCount: capacity)
            let count = min(Int(buffer.frameLength), Int(remaining))
            guard count > 0, let channels = buffer.floatChannelData else { break }

            let outputStart = mono.count
            mono.append(contentsOf: repeatElement(0, count: count))
            for channel in 0..<channelCount {
                let source = channels[channel]
                for index in 0..<count {
                    mono[outputStart + index] += source[index] * gain
                }
            }
            remaining -= AVAudioFramePosition(count)
        }
        return mono
    }

    /// Map two absolute source-frame boundaries onto one absolute 16 kHz grid.
    /// Subtracting the mapped boundaries makes adjacent window counts telescope:
    /// no per-window rounding drift can create an overlap or gap.
    private static func targetFrameCount(
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        sourceRate: Double
    ) -> Int {
        let ratio = CallAudioProcessing.targetRate / sourceRate
        let start = (Double(startFrame) * ratio).rounded(.toNearestOrAwayFromZero)
        let end = (Double(endFrame) * ratio).rounded(.toNearestOrAwayFromZero)
        return max(0, Int(end - start))
    }
}

enum AppState: Sendable, Equatable {
    case idle
    case recording      // dictation mode
    case transcribing
    case callStarting
    case callRecording   // call mode
    case callTranscribing
}

enum ModelState: Equatable {
    case noModel
    case downloading(WhisperModel, Double)   // model + progress 0...1
    case preparing(WhisperModel)             // CoreML compiling
    case ready(WhisperModel)
    case failed(WhisperModel, String)        // model + error message

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Structured truth about a dictation decode. Text fragments are presentation
/// data; recovery decisions use the failure/incompleteness fields instead of
/// inspecting marker text.
struct DictationDecodeOutcome: Equatable, Sendable {
    private(set) var fragments: [String]
    private(set) var recognizedFragmentCount: Int
    private(set) var hadTranscriptionFailure: Bool
    private(set) var isIncomplete: Bool

    var hasRecognizedText: Bool { recognizedFragmentCount > 0 }
    var requiresRecovery: Bool { hadTranscriptionFailure || isIncomplete }

    static func completeEmpty(hadTranscriptionFailure: Bool = false) -> Self {
        Self(
            fragments: [],
            recognizedFragmentCount: 0,
            hadTranscriptionFailure: hadTranscriptionFailure,
            isIncomplete: false
        )
    }

    static func recognized(
        _ text: String,
        hadTranscriptionFailure: Bool = false
    ) -> Self {
        Self(
            fragments: [text],
            recognizedFragmentCount: 1,
            hadTranscriptionFailure: hadTranscriptionFailure,
            isIncomplete: false
        )
    }

    static func incompleteGap(
        _ gapMarker: String,
        hadTranscriptionFailure: Bool
    ) -> Self {
        Self(
            fragments: [gapMarker],
            recognizedFragmentCount: 0,
            hadTranscriptionFailure: hadTranscriptionFailure,
            isIncomplete: true
        )
    }

    static var cancelled: Self {
        Self(
            fragments: [],
            recognizedFragmentCount: 0,
            hadTranscriptionFailure: false,
            isIncomplete: true
        )
    }

    mutating func merge(_ other: Self) {
        fragments.append(contentsOf: other.fragments)
        recognizedFragmentCount += other.recognizedFragmentCount
        hadTranscriptionFailure = hadTranscriptionFailure
            || other.hadTranscriptionFailure
        isIncomplete = isIncomplete || other.isIncomplete
    }

    mutating func recordTranscriptionFailure() {
        hadTranscriptionFailure = true
    }

    /// A parent span with no recognized child text gets one visible gap. This
    /// is presentation normalization; `isIncomplete` remains the authority.
    mutating func recordIncomplete(gapMarker: String) {
        isIncomplete = true
        if !hasRecognizedText {
            fragments = [gapMarker]
        }
    }
}

enum DictationRecoveryDisposition: Equatable, Sendable {
    case commit
    case preserve(reason: String)
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: AppState = .idle {
        didSet {
            if oldValue != state { refreshRuntimeMutationMenus() }
        }
    }
    private var modelState: ModelState = .noModel {
        didSet { applyModelState() }
    }
    private var modelReady: Bool { modelState.isReady }

    private let recorder = Recorder()
    private let dictationRecoveryStore: DictationRecoveryStore? = {
        do {
            return try DictationRecoveryStore()
        } catch {
            NSLog(
                "[Voicely] Dictation recovery store unavailable: %@",
                error.localizedDescription
            )
            return nil
        }
    }()
    private let dictationTerminationGate = DictationTerminationGate()
    private lazy var callRecorder = CallRecorder()
    private let transcriber = Transcriber()
    private let injector = Injector()
    private let storage = TranscriptStorage()
    private let overlay = Overlay()
    private let hotkey = HotkeyManager()
    private let onboarding = Onboarding()

    private var dictationSourceApp: String?
    private var dictationInjectionTarget: InjectionTargetToken?
    private var dictateMenuItem: NSMenuItem!
    private var callMenuItem: NSMenuItem!
    private var hotkeyMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var languageMenuItem: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var hotkeyRuntimeState: HotkeyRuntimeState?
    private var lastDictationToggle: Date = .distantPast

    // #3/#5/#8: Cancellable preload task reference
    private var preloadTask: Task<Void, Never>?
    private var preloadTaskOwner: UUID?
    // #12: Cancellable transcription task and discard window
    private var transcriptionTask: Task<Void, Never>?
    private var discardWindow: Date?

    /// Set when the user pressed the hotkey after the discard window closed and
    /// was warned; the next press cancels. Reset whenever a dictation session
    /// ends, so a stale warning never turns the next dictation's first press
    /// into an unannounced cancel.
    private var transcribeEscapeArmed = false
    // #7: Cancellable call recording task
    private var callTask: Task<Void, Never>?
    // AppKit termination is synchronous unless the delegate explicitly defers
    // it. Active call capture gets a bounded drain window before Quit proceeds.
    private var terminationTask: Task<Void, Never>?
    private var terminationReplyPending = false
    private var callCapturePreparedForTermination = false
    private var activeDictationRecovery: DictationRecoverySession?
    private var dictationTerminationInProgress = false
    private var dictationPreparedForTermination = false
    private static let callTerminationGraceSeconds: TimeInterval = 5
    private static let dictationTerminationGraceSeconds: TimeInterval = 5
    // Chunked transcription: process 30s chunks during recording
    private var chunkTask: Task<DictationDecodeOutcome, Never>?
    private var dictationChunkSessionID: UUID?
    private var dictationSessionOwner: UUID?
    // Speaker diarization (file-grade call pipeline + file queue). One
    // shared actor; lazily downloads/loads its CoreML models on first call.
    private let diarizer = DiarizationService()
    // File transcription queue (user picks 1..10 audio/video files)
    private var fileQueue: FileTranscriptionQueue?
    private var fileWorkActive = false {
        didSet {
            if oldValue != fileWorkActive { refreshRuntimeMutationMenus() }
        }
    }
    // Menu-bar progress tween for the file queue: eases the shown % toward the
    // target so it glides instead of jumping per 30 s chunk (the "резко" bug).
    private var fileQueueTweenTimer: DispatchSourceTimer?
    private var fileQueueShownPct: Double = 0
    private var fileQueueTargetPct: Double = 0
    private var fileQueueLabel: String = ""
    private var callTranscriptionShownPct: Int?
    // Prevent App Nap - hotkey must respond instantly
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple instances
        if let bid = Bundle.main.bundleIdentifier {
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == bid
            }
            if runningApps.count > 1 {
                print("[Voicely] Already running. Quitting duplicate.")
                NSApplication.shared.terminate(nil)
                return
            }
        }

        // Disable App Nap so hotkey responds instantly after idle
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Voicely hotkey must respond without delay"
        )

        print("[Voicely] Starting...")

        // Menubar with Voicely logo
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
        }

        // Menu
        let menu = NSMenu()

        dictateMenuItem = NSMenuItem(title: "Dictate  (\(hotkey.combo.displayName))", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(dictateMenuItem)

        callMenuItem = NSMenuItem(title: "Record Call", action: #selector(toggleCallRecording), keyEquivalent: "")
        menu.addItem(callMenuItem)

        let transcribeFileItem = NSMenuItem(
            title: "Transcribe File...",
            action: #selector(openTranscribeFilePanel),
            keyEquivalent: "")
        transcribeFileItem.target = self
        menu.addItem(transcribeFileItem)

        menu.addItem(NSMenuItem.separator())

        // Hotkey submenu
        let hotkeyMenu = NSMenu()
        for preset in HotkeyPreset.all {
            let item = NSMenuItem(title: preset.name, action: #selector(selectHotkeyPreset(_:)), keyEquivalent: "")
            item.representedObject = preset.combo
            if preset.combo == hotkey.combo {
                item.state = .on
            }
            hotkeyMenu.addItem(item)
        }
        hotkeyMenu.addItem(NSMenuItem.separator())
        hotkeyMenu.addItem(NSMenuItem(title: "Record Custom...", action: #selector(recordCustomHotkey), keyEquivalent: ""))
        let hotkeyItem = NSMenuItem(title: "Hotkey: \(hotkey.combo.displayName)", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        self.hotkeyMenuItem = hotkeyItem

        // Model submenu
        let initialModelTitle: String
        if transcriber.hasSavedModelSelection {
            initialModelTitle = "Model: \(transcriber.selectedModel.displayName)"
        } else {
            initialModelTitle = "Model: Select to Download"
        }
        let modelItem = NSMenuItem(title: initialModelTitle, action: nil, keyEquivalent: "")
        menu.addItem(modelItem)
        self.modelMenuItem = modelItem
        rebuildModelSubmenu()

        menu.addItem(NSMenuItem.separator())
        // Language submenu
        let restoredLanguageMode = LanguageMode.restored()
        let langMenu = NSMenu()
        for mode in LanguageMode.visibleCases {
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (mode == restoredLanguageMode) ? .on : .off
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language: \(restoredLanguageMode.menuTitle)", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        self.languageMenuItem = langItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Transcripts", action: #selector(openTranscripts), keyEquivalent: ""))
        // #25: Re-trigger onboarding
        menu.addItem(NSMenuItem(title: "Check Permissions...", action: #selector(runSetupWizard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Voicely", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Voicely", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        applyLanguageMode(restoredLanguageMode, persist: false, resetSession: false)

        // Audio visualization callback
        recorder.onAudioLevel = { [weak self] level in
            self?.overlay.updateLevel(level)
        }

        // Auto-stop after max recording duration (5 min)
        recorder.onMaxDuration = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleDictation()
            }
        }

        // Auto-stop at the actual-rate classic-WAV safety cap (configured 8h,
        // override up to 12h; high-rate devices may reach 4 GiB earlier).
        callRecorder.onMaxDuration = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleCallRecording()
            }
        }
        // Warning 5 minutes before call recording limit
        callRecorder.onMaxDurationWarning = { [weak self] remaining in
            DispatchQueue.main.async {
                self?.overlay.showInfo("Call recording stops in \(remaining / 60) min")
            }
        }
        // Disk-full guard: capture remains file-authoritative, so low space can
        // degrade a channel. Notify immediately and preserve explicit metadata.
        callRecorder.onDiskSpillStopped = { [weak self] freeBytes in
            DispatchQueue.main.async {
                guard let self else { return }
                let freeMB = freeBytes / (1024 * 1024)
                AppDelegate.debugLog("disk-full guard: system spill stopped, \(freeMB) MB free")
                self.overlay.showInfo("Low disk - call continues")
                self.showDiskSpillNotification(freeMB: freeMB)
            }
        }
        callRecorder.onCaptureDegraded = { [weak self] channel in
            DispatchQueue.main.async {
                AppDelegate.debugLog("call capture degraded on \(channel); final artifact will be partial")
                self?.overlay.showInfo("Call capture degraded (\(channel))")
            }
        }

        recoverOrphanedDictations()
        recoverOrphanedCallCaptures()

        // Audio engine interrupted (device switch, sleep/wake, Bluetooth disconnect)
        // Stop recording gracefully - transcriber handles partial audio or errors
        recorder.onEngineInterrupted = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.toggleDictation()
            }
        }

        // Silence detection disabled: recording stops only on hotkey press.
        // Transcriber handles silent audio via .silentAudio error at transcription time.
        // Warning before auto-stop - show via timer text, not overlay.showInfo
        // (showInfo would replace recording bars with text mode)
        recorder.onAutoStopWarning = { [weak self] remaining in
            DispatchQueue.main.async {
                self?.overlay.showRecordingWarning("\(remaining)s left")
            }
        }
        // Stream error during call recording
        // Don't show overlay message here - toggleCallRecording switches to loading mode
        // immediately, overwriting any message. The call task handles error display.
        callRecorder.onStreamError = { [weak self] message in
            DispatchQueue.main.async {
                self?.toggleCallRecording()
            }
        }

        hotkey.onRuntimeStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleHotkeyRuntimeState(state)
            }
        }

        // WhisperKit model download + load progress -> modelState + overlay
        transcriber.onProgress = { [weak self] status in
            guard let self else { return }
            DispatchQueue.main.async {
                // Drop stale progress callbacks after download cancel/complete.
                guard self.preloadTask != nil else { return }
                let model = self.transcriber.selectedModel
                switch status {
                case .downloadingModel(let progress):
                    self.modelState = .downloading(model, progress)
                    // Update overlay progress bar if visible in downloading mode
                    if self.overlay.currentMode == .downloading && self.overlay.isVisible {
                        let pct = Int(min(100, max(0, progress * 100)))
                        self.overlay.updateProgress(progress, status: "Voice model... \(pct)%")
                    }
                case .loadingModel:
                    // Only switch overlay to loading if we were downloading (not fallback after cancel).
                    let wasDownloading: Bool
                    if case .downloading = self.modelState { wasDownloading = true } else { wasDownloading = false }
                    self.modelState = .preparing(model)
                    if wasDownloading && self.overlay.isVisible {
                        self.overlay.show(mode: .loading)
                    }
                case .processing, .finalizing:
                    break
                }
            }
        }

        // First-run onboarding, THEN register hotkey
        // #3: Store preload task so it can be cancelled on quit
        // #15: [weak self] to avoid retain cycle
        // #35: Cancel any stale preload before starting a new one
        preloadTask?.cancel()
        preloadTaskOwner = nil
        let initialPreloadOwner = UUID()
        preloadTaskOwner = initialPreloadOwner
        preloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearPreloadTask(completingOwner: initialPreloadOwner) }
            let result = await onboarding.runIfNeeded()

            // Register hotkey only after accessibility is confirmed
            if result.accessibilityGranted {
                let registered = hotkey.register { [weak self] in
                    self?.toggleDictation()
                }
                if registered {
                    self.handleHotkeyRuntimeState(.active)
                } else {
                    self.handleHotkeyRuntimeState(hotkey.runtimeState)
                }
            } else {
                print("[Voicely] Hotkey not registered - Accessibility not granted.")
                self.handleHotkeyRuntimeState(.permissionMissing)
            }

            // First install: ask the user which model to download instead of
            // silently auto-selecting it. We still compute a recommendation,
            // but the user must explicitly choose on the first clean install.
            if !self.transcriber.hasSavedModelSelection {
                WhisperModel.clearSavedSelection()
                self.modelState = .noModel
                guard let chosenModel = self.promptForInitialModelSelection() else {
                    self.overlay.showInfo("Select a model")
                    return
                }
                self.transcriber.selectModel(chosenModel)
            }
            self.normalizeLanguageModeForSelectedModel(
                persist: true,
                announce: true
            )

            // Preload speech model (downloads on first launch, instant on subsequent)
            let model = self.transcriber.selectedModel
            print("[Voicely] Preloading model: \(model.displayName)...")

            // UI hint only: if directory exists, model may already be downloaded.
            // Not authoritative - modelState is the source of truth for readiness.
            let needsDownload = !FileManager.default.fileExists(atPath: model.modelDirectory.path)

            if needsDownload {
                self.modelState = .downloading(model, 0)
                self.overlay.show(mode: .downloading)
                self.overlay.updateProgress(0, status: "Voice model...")
                // Auto-hide overlay after 10s - progress continues in menu bar
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self,
                          Self.isModelSetupOverlay(self.overlay.currentMode) else { return }
                    self.overlay.hide()
                }
            } else {
                self.modelState = .preparing(model)
                self.overlay.showInfo("Preparing model...")
            }

            do {
                try await transcriber.preloadModel()
                self.modelState = .ready(model)
                self.overlay.hide()

                if needsDownload {
                    self.overlay.showInfo("Ready")
                    self.showReadyNotification()
                }
                print("[Voicely] Ready. Press \(hotkey.combo.displayName) to dictate.")
            } catch {
                guard !Task.isCancelled else { return }
                print("[Voicely] Model preload failed: \(error)")
                self.overlay.hide()
                let msg = Self.classifyModelError(error)
                self.overlay.showError(msg)
                self.modelState = .failed(model, msg)
            }
        }
    }

    /// Rebuild model submenu with download status indicators
    private func rebuildModelSubmenu() {
        guard let item = modelMenuItem else { return }
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        let available = Self.availableModels(
            from: WhisperModel.available(),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        let recommended = Self.recommendedModel(
            preferred: WhisperModel.recommended(),
            available: available
        )
        let current: WhisperModel? = transcriber.hasSavedModelSelection ? transcriber.selectedModel : nil
        let locked = modelReady  // Single source of truth: modelState == .ready
        let mutationLocked = !Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        )

        guard !available.isEmpty else {
            let unavailable = NSMenuItem(title: "No compatible models for this Mac", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            modelMenu.addItem(unavailable)
            item.submenu = modelMenu
            item.isEnabled = true
            return
        }

        for model in available {
            var label = model.userFacingLabel(isRecommended: model == recommended)
            let isSelected = current == model
            if isSelected && locked { label += "  [ready]" }
            let mi = NSMenuItem(title: label, action: #selector(selectModelPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = model.variant
            if isSelected && locked { mi.state = .on }
            if mutationLocked || (!isSelected && locked) { mi.isEnabled = false }
            modelMenu.addItem(mi)
        }

        if locked, let current {
            modelMenu.addItem(NSMenuItem.separator())
            let deleteItem = NSMenuItem(title: "Delete \(current.displayName) to switch models", action: #selector(deleteCurrentModel), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.isEnabled = !mutationLocked
            modelMenu.addItem(deleteItem)
        }

        item.submenu = modelMenu
        item.isEnabled = true  // Override autoenablesItems on parent menu
    }

    private func promptForInitialModelSelection() -> WhisperModel? {
        let available = Self.availableModels(
            from: WhisperModel.available(),
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        guard !available.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Compatible Models"
            alert.informativeText = "Voicely needs at least 8 GB of RAM for the current model lineup."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        let recommended = Self.recommendedModel(
            preferred: WhisperModel.recommended(),
            available: available
        )
        let alert = NSAlert()
        alert.messageText = "Choose Voice Model"
        alert.informativeText = "Choose the local model to install on this Mac. The first model download can be 426 MB to 3 GB, and the first prepare step may take a minute.\n\nYou can change models later from the Model menu. For the best Russian experience, choose GigaAM V3 RU. Screen Recording is only requested when you first record a call."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 26), pullsDown: false)
        for model in available {
            popup.addItem(withTitle: model.userFacingLabel(isRecommended: model == recommended))
            popup.itemArray.last?.representedObject = model.variant
        }
        if let recommendedIndex = available.firstIndex(of: recommended) {
            popup.selectItem(at: recommendedIndex)
        } else {
            popup.selectItem(at: 0)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let variant = popup.selectedItem?.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.variant == variant })
        else {
            return nil
        }
        return model
    }

    /// Single source of truth: updates ALL model UI from modelState.
    private func applyModelState() {
        guard let item = modelMenuItem else { return }
        switch modelState {
        case .noModel:
            item.title = "Model: Select to Download"
            item.action = nil; item.target = nil
            rebuildModelSubmenu()
        case .downloading(_, let progress):
            let pct = Int(min(100, max(0, progress * 100)))
            item.title = "Cancel Download (\(pct)%)"
            item.submenu = nil
            item.action = #selector(cancelModelDownload); item.target = self
        case .preparing:
            item.title = "Model: Preparing..."
            item.submenu = nil
            item.action = nil; item.target = nil
        case .ready(let model):
            item.title = "Model: \(model.displayName)"
            item.action = nil; item.target = nil
            rebuildModelSubmenu()
        case .failed:
            item.title = "Model: Select to Download"
            item.action = nil; item.target = nil
            rebuildModelSubmenu()
        }
        applyModelMenuBarTitle()
    }

    nonisolated static func composedMenuBarTitle(
        modelStatus: String,
        hotkeyRuntimeState: HotkeyRuntimeState?
    ) -> String {
        let hotkeyStatus: String
        switch hotkeyRuntimeState {
        case .permissionMissing:
            hotkeyStatus = " (grant access)"
        case .eventTapUnavailable:
            hotkeyStatus = " (hotkey retrying)"
        case .active, .none:
            hotkeyStatus = ""
        }
        return modelStatus + hotkeyStatus
    }

    private var modelMenuBarTitle: String {
        switch modelState {
        case .downloading(_, let progress):
            let pct = Int(min(100, max(0, progress * 100)))
            return " \(pct)%"
        case .preparing:
            return " ..."
        case .noModel, .ready, .failed:
            return ""
        }
    }

    private func applyModelMenuBarTitle() {
        statusItem.button?.title = Self.composedMenuBarTitle(
            modelStatus: modelMenuBarTitle,
            hotkeyRuntimeState: hotkeyRuntimeState
        )
    }

    // MARK: - Accessibility Poller

    private func handleHotkeyRuntimeState(_ newState: HotkeyRuntimeState) {
        let previous = hotkeyRuntimeState
        hotkeyRuntimeState = newState

        switch newState {
        case .active:
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
            hotkey.startAccessibilityMonitor()
            if state == .idle, !fileWorkActive {
                applyModelState()
            }
            if let previous, previous != .active {
                overlay.showInfo("Hotkey active")
            }

        case .permissionMissing:
            applyModelMenuBarTitle()
            if previous == .active {
                overlay.showError("Accessibility permission lost")
            }
            startAccessibilityPoller()

        case .eventTapUnavailable:
            applyModelMenuBarTitle()
            if previous != .eventTapUnavailable {
                overlay.showError("Hotkey unavailable - retrying")
            }
            startAccessibilityPoller()
        }
    }

    /// Polls until both Accessibility trust and the event tap are active.
    /// Trust without a live tap is a distinct recoverable state.
    private func startAccessibilityPoller() {
        guard accessibilityTimer == nil else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hotkey.retryIfNeeded() {
                    print("[Voicely] Accessibility granted. Hotkey registered.")
                    self.handleHotkeyRuntimeState(.active)
                } else {
                    self.handleHotkeyRuntimeState(self.hotkey.runtimeState)
                }
            }
        }
    }

    // MARK: - Dictation

    @objc func toggleDictation() {
        let now = Date()
        guard now.timeIntervalSince(lastDictationToggle) > 0.3 else { return }
        lastDictationToggle = now

        guard modelReady else {
            if case .noModel = modelState {
                overlay.showInfo("Select a model")
            } else {
                overlay.showInfo("Model loading...")
            }
            return
        }

        switch state {
        case .idle:
            guard ensureCaptureConfiguration() else { return }
            AppDelegate.debugLog("toggleDictation: idle -> recording")
            // Check mic permission before starting
            let micStatus = recorder.prepare()
            AppDelegate.debugLog("Mic status: \(micStatus.rawValue)")
            guard micStatus == .authorized else {
                overlay.showError("Mic not authorized")
                return
            }

            guard let dictationRecoveryStore else {
                overlay.showError("Private recovery storage unavailable")
                return
            }
            dictationSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
            dictationInjectionTarget = injector.captureTarget()
            transcriber.resetLanguageSession()
            dictationTerminationGate.reset()
            dictationTerminationInProgress = false
            dictationPreparedForTermination = false
            activeDictationRecovery = nil
            guard recorder.startMic(
                recoveryStore: dictationRecoveryStore,
                sourceApp: dictationSourceApp
            ) else {
                dictationInjectionTarget = nil
                overlay.showError(recorder.lastStartErrorMessage ?? "Mic unavailable")
                return
            }
            // Pause file-transcription queue so WhisperKit is free for dictation.
            fileQueue?.pause()
            overlay.show(mode: .recording)
            state = .recording

            // Start chunked transcription. The loop is driven by buffered audio:
            // it polls only while a full 30-second window is unavailable, then
            // immediately processes the next buffered window after each decode.
            let chunkSessionID = UUID()
            dictationSessionOwner = chunkSessionID
            dictationChunkSessionID = chunkSessionID
            chunkTask = Task {
                let chunkWaitInterval: Duration = .milliseconds(250)
                var chunkIndex = 0
                var outcome = DictationDecodeOutcome.completeEmpty()
                while !Task.isCancelled, self.dictationChunkSessionID == chunkSessionID {
                    guard let rate = self.recorder.currentSampleRate else {
                        AppDelegate.debugLog("dict chunk: no sample rate, waiting")
                        try? await Task.sleep(for: chunkWaitInterval)
                        continue
                    }
                    let chunkSamples = Int(rate * 30)
                    guard let samples = self.recorder.extractChunk(sampleCount: chunkSamples,
                                                                    requireFull: true) else {
                        // Buffer doesn't have a full 30s yet — sleep briefly and retry
                        // rather than spinning the loop.
                        AppDelegate.debugLog("dict chunk: buffer not ready (need \(chunkSamples)), waiting")
                        try? await Task.sleep(for: chunkWaitInterval)
                        continue
                    }
                    chunkIndex += 1
                    let idx = chunkIndex
                    let durationSec = Double(samples.count) / rate
                    AppDelegate.debugLog("dict chunk #\(idx): extracted \(samples.count) samples (\(String(format: "%.1f", durationSec))s at \(rate)Hz), transcribing...")
                    await AppDelegate.transcribeAndCommitDictationChunk(
                        samples: samples,
                        sampleRate: rate,
                        logPrefix: "dict chunk #\(idx)",
                        transcribe: { buffer in
                            try await self.transcriber.transcribe(audio: buffer)
                        },
                        commit: { outcome.merge($0) }
                    )
                }
                AppDelegate.debugLog(
                    "dict chunk loop exited: \(chunkIndex) chunks processed, "
                        + "\(outcome.fragments.count) kept, incomplete=\(outcome.requiresRecovery)"
                )
                return outcome
            }

            dictateMenuItem.title = "Stop Dictation  (\(hotkey.combo.displayName))"
            callMenuItem.isEnabled = false

        case .recording:
            AppDelegate.debugLog("Recording stopped, calling recorder.stop()")

            // Close this buffer-consumer session, but do not cancel an ASR call
            // that already owns an extracted chunk. The task returns its local
            // committed results after that decode finishes.
            let pendingChunkTask = chunkTask
            let finishingSessionOwner = dictationSessionOwner ?? UUID()
            dictationSessionOwner = finishingSessionOwner
            chunkTask = nil
            dictationChunkSessionID = nil

            let result = recorder.stop()
            let recoverySession = recorder.takeDictationRecoverySession()
            activeDictationRecovery = recoverySession
            AppDelegate.debugLog("Recorder result: \(result)")
            overlay.show(mode: .loading)
            state = .transcribing

            // #12: Set discard window - hotkey within 2s will cancel transcription
            discardWindow = Date()

            dictateMenuItem.title = "Transcribing... (\(hotkey.combo.displayName) to cancel)"
            dictateMenuItem.isEnabled = false
            // #23: Disable call menu during transcription
            callMenuItem.isEnabled = false

            let sourceApp = dictationSourceApp
            let injectionTarget = dictationInjectionTarget

            // Extract remaining audio (only samples since last chunk extraction)
            let audio: AVAudioPCMBuffer?
            let recorderStopError: RecorderError?
            switch result {
            case .success(let buffer):
                audio = buffer
                recorderStopError = nil
            case .failure(let error):
                // A fully chunked recording legitimately leaves no tail. Decide
                // whether this is an error only after the in-flight chunk returns.
                audio = nil
                recorderStopError = error
            }

            // #12: Store transcription task so it can be cancelled for discard
            transcriptionTask = Task {
                // If a file queue is running, wait for it to actually reach
                // the paused state (engine idle) before we call transcribe.
                // For short dictations the natural chunk-sleep buffer isn't
                // enough to avoid trySetTranscribing collisions.
                if let queue = self.fileQueue {
                    _ = await queue.awaitPaused()
                }
                // Wait for any in-progress chunk transcription to complete
                let rawCompletedChunkOutcome = await pendingChunkTask?.value
                    ?? DictationDecodeOutcome.completeEmpty()
                let completedChunkOutcome = Self.dictationOutcomeAfterRecorderStop(
                    recorderStopError,
                    completedChunks: rawCompletedChunkOutcome
                )
                guard !Task.isCancelled,
                      Self.dictationFinalizationOwnsSession(
                        completingOwner: finishingSessionOwner,
                        currentOwner: self.dictationSessionOwner
                      ) else {
                    return
                }

                if let recorderStopError,
                   case .noSamples = recorderStopError,
                   rawCompletedChunkOutcome.fragments.isEmpty,
                   audio == nil {
                    print("[Voicely] Recorder error: \(recorderStopError.localizedDescription)")
                    self.overlay.showError(recorderStopError.localizedDescription)
                    self.preserveActiveDictationRecovery(
                        reason: "recorder_stop_failed: \(recorderStopError.localizedDescription)"
                    )
                    self.finishDictationSessionIfOwned(finishingSessionOwner)
                    return
                }
                if let recorderStopError,
                   completedChunkOutcome.isIncomplete,
                   !rawCompletedChunkOutcome.isIncomplete {
                    AppDelegate.debugLog(
                        "Recorder stop made dictation incomplete: "
                            + recorderStopError.localizedDescription
                    )
                }

                // Transcribe the tail in 30s windows so each call stays under the 90s
                // decode deadline — single-shot transcribe of a long tail collapses to
                // one short segment and loses most content.
                var tailOutcome = DictationDecodeOutcome.completeEmpty()
                if let audio = audio {
                    let remDuration = Double(audio.frameLength) / audio.format.sampleRate
                    AppDelegate.debugLog("dict remainder: \(audio.frameLength) frames (\(String(format: "%.1f", remDuration))s at \(audio.format.sampleRate)Hz), windowing...")
                    tailOutcome = await AppDelegate.transcribeWindowed(
                        buffer: audio,
                        transcriber: self.transcriber,
                        logPrefix: "dict remainder"
                    )
                    AppDelegate.debugLog(
                        "dict remainder: windowed total "
                            + "\(tailOutcome.fragments.joined(separator: " ").count) chars, "
                            + "incomplete=\(tailOutcome.requiresRecovery)"
                    )
                } else {
                    AppDelegate.debugLog("dict remainder: nil (buffer fully drained by chunks)")
                }

                guard !Task.isCancelled,
                      Self.dictationFinalizationOwnsSession(
                        completingOwner: finishingSessionOwner,
                        currentOwner: self.dictationSessionOwner
                      ) else {
                    return
                }

                // Merge typed decode truth across background chunks and tail.
                // Marker text never decides whether authoritative audio survives.
                var decodeOutcome = completedChunkOutcome
                decodeOutcome.merge(tailOutcome)
                let text = decodeOutcome.fragments.joined(separator: " ")

                AppDelegate.debugLog(
                    "Transcription result: \(text.count) chars "
                        + "(\(decodeOutcome.fragments.count) fragments, "
                        + "incomplete=\(decodeOutcome.requiresRecovery))"
                )
                var messageShown = false
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName
                    let saved = self.storage.saveDictation(
                        text: text,
                        sourceApp: sourceApp ?? currentApp
                    )
                    if !self.dictationTerminationInProgress {
                        AppDelegate.debugLog("Injecting text...")
                        let result = self.injector.inject(
                            text: text,
                            target: injectionTarget
                        )
                        switch result {
                        case .blockedSecureTarget:
                            self.overlay.showError(saved == nil
                                ? "Secure field blocked. Save failed"
                                : "Secure field blocked. Saved")
                            messageShown = true
                        case .copiedOnly:
                            self.overlay.showInfo(saved == nil
                                ? "Copied for manual paste; save failed"
                                : "Copied for manual paste & saved")
                            messageShown = true
                        case .failed:
                            self.overlay.showError(saved == nil
                                ? "Copy failed. Save failed"
                                : "Copy failed. Saved")
                            messageShown = true
                        case .directInsert:
                            if saved == nil {
                                self.overlay.showError("Inserted. Save failed")
                                messageShown = true
                            }
                        }
                        AppDelegate.debugLog("Text result=\(result), saved=\(saved?.lastPathComponent ?? "nil")")
                    }

                    self.applyDictationRecoveryDisposition(
                        Self.dictationRecoveryDisposition(
                            for: decodeOutcome,
                            transcriptSaveSucceeded: saved != nil,
                            terminationInProgress: self.dictationTerminationInProgress
                        ),
                        transcriptURL: saved
                    )
                    if decodeOutcome.requiresRecovery,
                       !self.dictationTerminationInProgress {
                        self.overlay.showError(saved == nil
                            ? "Transcription incomplete. Audio preserved; save failed"
                            : "Transcription incomplete. Audio preserved")
                        messageShown = true
                    }
                } else {
                    AppDelegate.debugLog(
                        "Empty transcription result - incomplete="
                            + "\(decodeOutcome.requiresRecovery)"
                    )
                    if decodeOutcome.requiresRecovery {
                        self.overlay.showError("Transcription incomplete. Audio preserved")
                    } else {
                        self.overlay.showInfo("No speech detected")
                    }
                    messageShown = true
                    self.applyDictationRecoveryDisposition(
                        Self.dictationRecoveryDisposition(
                            for: decodeOutcome,
                            transcriptSaveSucceeded: nil,
                            terminationInProgress: self.dictationTerminationInProgress
                        ),
                        transcriptURL: nil
                    )
                }
                // Only hide overlay if no message was shown (messages auto-hide after 5s)
                if !messageShown {
                    self.overlay.hide()
                }
                self.finishDictationSessionIfOwned(finishingSessionOwner)
            }

        case .transcribing:
            // #12/#74: Discard recording if hotkey pressed within 3s of entering transcribing state.
            // Past that window the hotkey used to be swallowed silently and there
            // was no way out of a wedged transcription short of quitting, so a
            // second press now arms the same discard — see `transcribeEscapeArmed`.
            if let window = discardWindow,
               Date().timeIntervalSince(window) >= 3.0,
               !transcribeEscapeArmed {
                transcribeEscapeArmed = true
                overlay.showInfo("Transcribing… press again to cancel")
                return
            }
            if discardWindow != nil {
                transcriber.cancelCurrentTask()
                transcriptionTask?.cancel()
                transcriptionTask = nil
                chunkTask?.cancel()
                chunkTask = nil
                dictationChunkSessionID = nil
                dictationSessionOwner = nil
                dictationInjectionTarget = nil
                commitActiveDictationRecovery(transcriptURL: nil)
                discardWindow = nil
                transcribeEscapeArmed = false
                overlay.hide()
                overlay.showInfo("Discarded")
                state = .idle
                fileQueue?.resume()
                resetMenubar()
                return
            }
            return
        case .callRecording:
            overlay.showInfo("Recording call...")
        case .callStarting:
            overlay.showInfo("Starting call...")
        case .callTranscribing:
            overlay.showInfo("Transcribing call...")
        }
    }

    // MARK: - Call Recording

    @objc func toggleCallRecording() {
        guard modelReady else {
            if case .noModel = modelState {
                overlay.showInfo("Select a model")
            } else {
                overlay.showInfo("Model loading...")
            }
            return
        }

        switch state {
        case .idle:
            guard ensureCaptureConfiguration() else { return }
            dictationSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
            transcriber.resetLanguageSession()
            // Enter a transitional state before the first await so neither the
            // hotkey nor a second menu action can start another capture session.
            state = .callStarting
            callMenuItem.isEnabled = false
            dictateMenuItem.isEnabled = false
            // Pause file-transcription queue so WhisperKit is free for call chunks.
            fileQueue?.pause()
            // #7: Store call task so it can be cancelled on quit
            // #16: [weak self] to avoid strong self capture
            callTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.state == .callStarting {
                        self.rollbackCallStart()
                    }
                    self.callTask = nil
                }
                // Request Screen Recording permission on-demand
                let hasScreenRecording = await self.onboarding.requestScreenRecording()
                guard hasScreenRecording else {
                    NSLog("[Voicely] Screen Recording permission denied - cannot record calls.")
                    self.overlay.showError("Screen Recording off")
                    return
                }

                do {
                    // Call-start race (#5): the first press used to surface a raw
                    // error while the second succeeded. The flaky step is the
                    // cold start of SCStream + AVAudioEngine (shareable-content
                    // query, mic device warm-up) right after permission was just
                    // granted. Make start idempotent/waiting: retry a transient
                    // failure a few times with short backoff instead of throwing
                    // on the first attempt.
                    try await self.startCallRecorderWithRetry()
                    guard !Task.isCancelled else {
                        self.callRecorder.forceStop()
                        return
                    }

                    // `CallRecorder.start()` publishes its own running state
                    // before this MainActor task can publish `.callRecording`.
                    // Recheck both lifecycle phase and latched interruption as
                    // one snapshot so a producer death in that handoff window
                    // finalizes the durable prefix instead of leaving a false
                    // recording UI behind.
                    switch self.callRecorder.startHandoffStatus {
                    case .healthy:
                        break
                    case .interrupted(let reason):
                        NSLog("[Voicely] Call capture interrupted during start handoff: %@", reason)
                        self.beginCallFinalization()
                        await self.finalizeCallRecording(
                            sourceApp: self.dictationSourceApp
                        )
                        return
                    case .notRunning:
                        NSLog("[Voicely] Call recorder stopped before start handoff completed")
                        self.beginCallFinalization()
                        await self.finalizeCallRecording(
                            sourceApp: self.dictationSourceApp
                        )
                        return
                    }
                    self.state = .callRecording

                    // No realtime transcription anymore: capture both channels
                    // and transcribe them when the call stops. Mic stays You;
                    // only the system channel is diarized into remote speakers.
                    // See `processCallRecording`.
                    if let button = self.statusItem.button {
                        button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recording Call")
                        button.image?.size = NSSize(width: 16, height: 16)
                        button.image?.isTemplate = true
                    }
                    self.callMenuItem.title = "Stop Recording"
                    self.callMenuItem.isEnabled = true
                    self.dictateMenuItem.isEnabled = false
                    self.overlay.showInfo("Recording call...")
                } catch {
                    NSLog("[Voicely] Failed to start call recording: %@", error.localizedDescription)
                    self.callRecorder.forceStop()
                    self.overlay.showError("Call record failed")
                }
            }

        case .callStarting:
            return

        case .callRecording:
            beginCallFinalization()
            let sourceApp = dictationSourceApp
            callTask = Task { [weak self] in
                guard let self else { return }
                await self.finalizeCallRecording(sourceApp: sourceApp)
            }

        default:
            break
        }
    }

    /// Publish interrupted dictation audio into Documents before model loading.
    /// The private source remains available when validation or publication fails.
    private func recoverOrphanedDictations() {
        guard let dictationRecoveryStore else {
            overlay.showError("Dictation recovery unavailable")
            return
        }
        let visibleBaseURL = storage.baseDir
        let exportTask = Task.detached(priority: .utility) {
            dictationRecoveryStore.exportPendingArtifacts(
                to: visibleBaseURL
            )
        }
        Task { @MainActor [weak self] in
            let report = await exportTask.value
            guard let self else { return }
            if report.retainedFailureCount > 0 {
                self.overlay.showError("Dictation recovery incomplete")
            } else if !report.exported.isEmpty {
                self.overlay.showInfo(report.exported.count == 1
                    ? "Recovered 1 dictation recording"
                    : "Recovered \(report.exported.count) dictation recordings")
            }
        }
    }

    /// Save crash/relaunch capture staging before normal app work starts. A
    /// failed recovery remains in PendingCalls for the next launch.
    private func recoverOrphanedCallCaptures() {
        let recoveryStore: PendingCallRecoveryStore
        do {
            recoveryStore = try PendingCallRecoveryStore()
        } catch {
            AppDelegate.debugLog("pending-call recovery unavailable: \(error)")
            overlay.showError("Call recovery unavailable")
            return
        }
        let captures = recoveryStore.claimRecoverableCaptures()
        guard !captures.isEmpty else { return }

        var recoveredCount = 0
        var incompleteCount = 0
        for capture in captures {
            let micDuration = Self.recoveredChannelDuration(
                channel: capture.micMetadata,
                fileURL: capture.micFileURL
            )
            let systemDuration = Self.recoveredChannelDuration(
                channel: capture.systemMetadata,
                fileURL: capture.systemFileURL
            )
            let gap = abs(systemDuration - micDuration)
            let missingChannels = capture.configuredChannels
                .subtracting(capture.capturedChannels)
                .map(\.rawValue)
                .sorted()
            let metadata = CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: Self.partialCallReasonRecoveredAfterInterruption,
                note: "Recovered disk-backed call audio after the app stopped before the normal artifact transaction completed. The transcript was unavailable; audio may end abruptly.",
                missingChannels: missingChannels,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: gap
            )
            let result = storage.saveCallDetailed(
                sourceCapture: capture,
                segments: [],
                sourceApp: "Recovered call",
                captureMetadata: metadata
            )
            if result.isFullyFinalized {
                recoveredCount += 1
                AppDelegate.debugLog("recovered orphan call \(capture.callID)")
            } else {
                incompleteCount += 1
                AppDelegate.debugLog(
                    "orphan call \(capture.callID) remains recoverable; failed=\(result.failedArtifactNames.joined(separator: ", "))"
                )
            }
        }

        if incompleteCount > 0 {
            overlay.showError("Call recovery incomplete")
        } else if recoveredCount > 0 {
            overlay.showInfo(recoveredCount == 1
                ? "Recovered 1 call recording"
                : "Recovered \(recoveredCount) call recordings")
        }
    }

    private nonisolated static func recoveredChannelDuration(
        channel: PendingCallChannelMetadata?,
        fileURL: URL?
    ) -> Double {
        if let channel, channel.sampleRate > 0 {
            return Double(channel.sampleCount) / channel.sampleRate
        }
        guard let fileURL else { return 0 }
        return (try? CallAudioFileWindowReader.durationSeconds(of: fileURL)) ?? 0
    }

    /// Transcribe a finished call with channel provenance as truth: mic is You,
    /// system audio is Other. Only the system channel is diarized into remote
    /// Speaker N ids; we never infer You from mixed diarization.
    private func processCallRecording(audio: CallRecorder.CallAudio, sourceApp: String?) async {
        transcriber.resetLanguageSession()
        updateCallTranscriptionProgress(.preparing)

        let captureMetadata = Self.callCaptureMetadata(
            system: audio.captureTruth.system,
            mic: audio.captureTruth.mic,
            interruptionReason: audio.captureTruth.interruptionReason
        )
        guard audio.micFileURL != nil || audio.systemFileURL != nil else {
            self.overlay.showError("No audio captured")
            return
        }

        let skipSystemChannel = Self.shouldSkipSystemChannel(captureMetadata)
        if skipSystemChannel {
            AppDelegate.debugLog(
                "call capture marked partial (reason=\(captureMetadata.partialReason ?? "unknown")): \(captureMetadata.note ?? "")"
            )
        }

        // Diarize the complete system channel before ASR so every remote decode
        // window is speaker-stable. Empty/failed diarization keeps the old
        // unlabeled 30-second fallback below.
        let systemTurns: [SpeakerTurn]
        if skipSystemChannel || audio.systemFileURL == nil {
            systemTurns = []
        } else if let systemFileURL = audio.systemFileURL {
            systemTurns = await self.diarizeSystemFile(systemFileURL)
        } else {
            systemTurns = []
        }
        let systemDuration = audio.captureTruth.system.durationSeconds
        let diarizedSystemWindows = CallAudioProcessing.systemTranscriptionWindows(
            turns: systemTurns,
            audioDuration: systemDuration
        )
        let useDiarizedSystemWindows = !systemTurns.isEmpty && !diarizedSystemWindows.isEmpty
        if !skipSystemChannel, !systemTurns.isEmpty, !useDiarizedSystemWindows {
            AppDelegate.debugLog("system diarization had no valid in-range turns - keeping unlabeled fallback")
        }

        let micWindowCount = audio.micFileURL == nil ? 0 : CallTranscriptionProgress.windowCount(
            sampleCount: audio.captureTruth.mic.sampleCount,
            sampleRate: audio.captureTruth.mic.sampleRate
        )
        let systemWindowCount: Int
        if skipSystemChannel || audio.systemFileURL == nil {
            systemWindowCount = 0
        } else if useDiarizedSystemWindows {
            systemWindowCount = diarizedSystemWindows.count
        } else {
            systemWindowCount = CallTranscriptionProgress.windowCount(
                sampleCount: audio.captureTruth.system.sampleCount,
                sampleRate: audio.captureTruth.system.sampleRate
            )
        }
        let totalWindows = micWindowCount + systemWindowCount
        var completedWindows = 0
        let markWindowComplete = { [weak self] in
            guard let self else { return }
            completedWindows += 1
            self.updateCallTranscriptionProgress(.transcribing(
                completedWindows: completedWindows,
                totalWindows: totalWindows
            ))
        }
        updateCallTranscriptionProgress(.transcribing(
            completedWindows: completedWindows,
            totalWindows: totalWindows
        ))

        let systemSegments: [DialogueSegment]
        if skipSystemChannel || audio.systemFileURL == nil {
            systemSegments = []
        } else if useDiarizedSystemWindows, let systemFileURL = audio.systemFileURL {
            systemSegments = await self.transcribeDiarizedSystemFile(
                fileURL: systemFileURL,
                windows: diarizedSystemWindows,
                onWindowComplete: markWindowComplete
            )
        } else if let systemFileURL = audio.systemFileURL {
            systemSegments = await self.transcribeCallFile(
                fileURL: systemFileURL,
                durationSeconds: systemDuration,
                speaker: .other,
                onWindowComplete: markWindowComplete
            )
        } else {
            systemSegments = []
        }
        let micLanguageOverride = CallAudioProcessing.micLanguageOverride(
            preferredLanguage: transcriber.preferredLanguage,
            translateToEnglish: transcriber.translateToEnglish,
            system: systemSegments
        )
        let micSegments: [DialogueSegment]
        if let micFileURL = audio.micFileURL {
            micSegments = await self.transcribeCallFile(
                fileURL: micFileURL,
                durationSeconds: audio.captureTruth.mic.durationSeconds,
                speaker: .you,
                forcedLanguage: micLanguageOverride,
                echoReferenceURL: audio.systemFileURL,
                onWindowComplete: markWindowComplete
            )
        } else {
            micSegments = []
        }
        guard !Task.isCancelled else {
            // Cancellation (especially the bounded Quit timeout) must leave the
            // typed source capture untouched for recovery. Saving the segments
            // accumulated so far as a "complete" call would be dishonest and
            // could retire the only durable audio source.
            AppDelegate.debugLog("call finalization cancelled before artifact commit; source retained")
            return
        }
        updateCallTranscriptionProgress(.saving)
        let transcript = CallAudioProcessing.assembleCallTranscript(
            mic: micSegments,
            system: systemSegments,
            systemTurns: []
        )

        let saveResult = self.storage.saveCallDetailed(
            sourceCapture: audio.sourceCapture,
            segments: transcript,
            sourceApp: sourceApp,
            captureMetadata: captureMetadata
        )
        let speakerCount = CallTranscriptMerger.detectedSpeakerIDs(in: transcript).count
        if saveResult.isFullyFinalized {
            updateCallTranscriptionProgress(.finished)
            self.overlay.showInfo(captureMetadata.isPartial ? "Call saved (partial capture)" : "Call saved")
            if captureMetadata.isPartial {
                NSLog("[Voicely] Call saved as partial capture: %@ (%d segments, %d remote speakers)",
                      captureMetadata.partialReason ?? "unknown",
                      transcript.count,
                      speakerCount)
            } else {
                NSLog("[Voicely] Call transcribed: %d segments, %d remote speakers",
                      transcript.count, speakerCount)
            }
        } else if saveResult.isComplete {
            updateCallTranscriptionProgress(.finished)
            self.overlay.showError("Call saved; recovery cleanup pending")
            NSLog("[Voicely] Call artifacts are durable but source cleanup failed: %@",
                  String(describing: saveResult.sourceCleanup))
        } else {
            let failedArtifacts = saveResult.failedArtifactNames.joined(separator: ", ")
            if saveResult.transcriptWasSaved {
                self.overlay.showError("Call partial: \(failedArtifacts)")
            } else {
                self.overlay.showError("Call save failed: \(failedArtifacts)")
            }
            NSLog("[Voicely] Call artifact set incomplete; failed=%@ transcript_saved=%@ segments=%d remote_speakers=%d",
                  failedArtifacts,
                  saveResult.transcriptWasSaved ? "yes" : "no",
                  transcript.count,
                  speakerCount)
        }
    }

    /// Read and transcribe one disk-backed channel in bounded 30-second windows.
    /// The optional echo reference is read for the same bounded interval; no
    /// whole-channel PCM copy is ever created.
    private func transcribeCallFile(
        fileURL: URL,
        durationSeconds: Double,
        speaker: CallSpeaker,
        forcedLanguage: String? = nil,
        echoReferenceURL: URL? = nil,
        onWindowComplete: (() -> Void)? = nil
    ) async -> [DialogueSegment] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        var segments: [DialogueSegment] = []
        let windowCount = Int(ceil(
            durationSeconds / CallAudioFileWindowReader.maximumWindowSeconds
        ))

        for windowIndex in 0..<windowCount {
            if Task.isCancelled { return segments }
            let start = Double(windowIndex) * CallAudioFileWindowReader.maximumWindowSeconds
            let end = min(
                durationSeconds,
                start + CallAudioFileWindowReader.maximumWindowSeconds
            )
            let window: [Float]
            do {
                window = try await Task.detached(priority: .userInitiated) {
                    try Self.loadCallTranscriptionWindow(
                        fileURL: fileURL,
                        echoReferenceURL: echoReferenceURL,
                        startTime: start,
                        endTime: end
                    )
                }.value
            } catch {
                AppDelegate.debugLog("call \(speaker.rawValue) window #\(windowIndex) read failed: \(error)")
                segments.append(DialogueSegment(
                    speaker: speaker,
                    start: start,
                    end: end,
                    text: "[…]",
                    language: nil
                ))
                onWindowComplete?()
                continue
            }
            guard !window.isEmpty else {
                segments.append(DialogueSegment(
                    speaker: speaker,
                    start: start,
                    end: end,
                    text: "[…]",
                    language: nil
                ))
                onWindowComplete?()
                continue
            }

            segments.append(contentsOf: await self.transcribeCallWindow(
                samples: window,
                sampleRate: CallAudioProcessing.targetRate,
                speaker: speaker,
                startOffsetSec: start,
                forcedLanguage: forcedLanguage,
                windowIndex: windowIndex
            ))
            onWindowComplete?()
        }
        return segments
    }

    /// Transcribe diarization-first windows directly from the system WAV.
    private func transcribeDiarizedSystemFile(
        fileURL: URL,
        windows: [CallSystemTranscriptionWindow],
        onWindowComplete: (() -> Void)? = nil
    ) async -> [DialogueSegment] {
        var segments: [DialogueSegment] = []

        for (windowIndex, window) in windows.enumerated() {
            if Task.isCancelled { return segments }
            let audioWindow: [Float]
            do {
                audioWindow = try await Task.detached(priority: .userInitiated) {
                    try CallAudioFileWindowReader.readMono16k(
                        from: fileURL,
                        startTime: window.audioStart,
                        endTime: window.audioEnd
                    )
                }.value
            } catch {
                AppDelegate.debugLog("system diarization window #\(windowIndex) read failed: \(error)")
                segments.append(DialogueSegment(
                    speaker: .other,
                    start: window.contentStart,
                    end: window.contentEnd,
                    text: "[…]",
                    language: nil,
                    speakerID: window.speakerID
                ))
                onWindowComplete?()
                continue
            }
            guard !audioWindow.isEmpty else {
                segments.append(DialogueSegment(
                    speaker: .other,
                    start: window.contentStart,
                    end: window.contentEnd,
                    text: "[…]",
                    language: nil,
                    speakerID: window.speakerID
                ))
                onWindowComplete?()
                continue
            }

            let rawSegments = await self.transcribeCallWindow(
                samples: audioWindow,
                sampleRate: CallAudioProcessing.targetRate,
                speaker: .other,
                startOffsetSec: window.audioStart,
                windowIndex: windowIndex
            )
            segments.append(contentsOf: CallAudioProcessing.systemSegments(
                from: rawSegments,
                in: window
            ))
            onWindowComplete?()
        }
        return segments
    }

    private nonisolated static func loadCallTranscriptionWindow(
        fileURL: URL,
        echoReferenceURL: URL?,
        startTime: Double,
        endTime: Double
    ) throws -> [Float] {
        let primary = try CallAudioFileWindowReader.readMono16k(
            from: fileURL,
            startTime: startTime,
            endTime: endTime
        )
        guard let echoReferenceURL,
              let reference = try? CallAudioFileWindowReader.readMono16k(
                from: echoReferenceURL,
                startTime: startTime,
                endTime: endTime
              ),
              !reference.isEmpty else { return primary }
        return try cleanMicForCallTranscription(
            mic: primary,
            micRate: CallAudioProcessing.targetRate,
            system: reference,
            systemRate: CallAudioProcessing.targetRate
        )
    }

    /// Transcribe a single call-channel window with one retry. Silent/too-short
    /// windows are benign and return `[]`; real failures become a gap marker.
    private func transcribeCallWindow(
        samples: [Float],
        sampleRate: Double,
        speaker: CallSpeaker,
        startOffsetSec: Double,
        forcedLanguage: String? = nil,
        windowIndex: Int
    ) async -> [DialogueSegment] {
        var attempt = 0
        while true {
            do {
                return try await self.transcriber.transcribeChannel(
                    samples: samples,
                    sampleRate: sampleRate,
                    speaker: speaker,
                    startOffsetSec: startOffsetSec,
                    forcedLanguage: forcedLanguage
                )
            } catch {
                if Task.isCancelled { return [] }
                attempt += 1
                let maxAttempts = 3
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                AppDelegate.debugLog("call \(speaker.rawValue) window #\(windowIndex) failed after \(maxAttempts) attempts: \(error)")
                let dur = Double(samples.count) / sampleRate
                return [DialogueSegment(
                    speaker: speaker,
                    start: startOffsetSec,
                    end: startOffsetSec + dur,
                    text: "[…]",
                    language: nil
                )]
            }
        }
    }

    /// The offline URL pipeline keeps the complete system channel on disk. A
    /// failure deliberately falls back to unlabeled fixed windows.
    private func diarizeSystemFile(_ systemFileURL: URL) async -> [SpeakerTurn] {
        do {
            return try await self.diarizer.diarize(fileURL: systemFileURL)
        } catch {
            AppDelegate.debugLog("system diarization failed (\(error)) - keeping unlabeled")
            return []
        }
    }

    /// Best-effort AEC: use system audio as the echo reference to reduce remote
    /// bleed before the mic channel is transcribed as `.you`. Keep this bounded:
    /// the NLMS filter is expensive, so long calls fall back to raw mic rather
    /// than freezing/OOMing while still preserving channel provenance.
    private nonisolated static func cleanMicForCallTranscription(
        mic: [Float],
        micRate: Double,
        system: [Float],
        systemRate: Double
    ) throws -> [Float] {
        guard !mic.isEmpty else { return [] }
        guard !system.isEmpty else {
            return try CallAudioProcessing.resampleMono(mic, fromRate: micRate)
        }

        let micDuration = micRate > 0 ? Double(mic.count) / micRate : 0
        let systemDuration = systemRate > 0 ? Double(system.count) / systemRate : 0
        let aecDuration = max(micDuration, systemDuration)
        let maxAECSeconds = Double(ProcessInfo.processInfo.environment["VOICELY_AEC_MAX_SECONDS"] ?? "") ?? 45
        guard aecDuration <= maxAECSeconds else {
            AppDelegate.debugLog("call AEC skipped for \(String(format: "%.1f", aecDuration))s channels (cap \(String(format: "%.1f", maxAECSeconds))s)")
            return try CallAudioProcessing.resampleMono(mic, fromRate: micRate)
        }

        let aecRate = 48_000.0
        let mic48 = try CallAudioProcessing.resampleMono(mic, fromRate: micRate, toRate: aecRate)
        let system48 = try CallAudioProcessing.resampleMono(system, fromRate: systemRate, toRate: aecRate)
        let processCount = min(mic48.count, system48.count)
        guard processCount > 0 else {
            return try CallAudioProcessing.resampleMono(mic, fromRate: micRate)
        }

        let aec = AcousticEchoCanceller(sampleRate: aecRate)
        let delayWindow = min(processCount, Int(aecRate))
        if delayWindow > Int(0.1 * aecRate) {
            _ = aec.estimateDelayMs(
                mic: Array(mic48[..<delayWindow]),
                reference: Array(system48[..<delayWindow])
            )
        }

        var cleaned48 = aec.process(
            mic: Array(mic48[..<processCount]),
            reference: Array(system48[..<processCount])
        )
        if mic48.count > processCount {
            cleaned48.append(contentsOf: mic48[processCount...])
        }
        return try CallAudioProcessing.resampleMono(cleaned48, fromRate: aecRate)
    }

    /// Start the call recorder, tolerating a cold-start failure. `alreadyRunning`
    /// is accepted only when the recorder confirms that both capture paths reached
    /// its running lifecycle state. Stale partial state is torn down before retrying.
    private func startCallRecorderWithRetry() async throws {
        let maxAttempts = 3
        var attempt = 0
        var lastError: Error?
        while attempt < maxAttempts {
            attempt += 1
            do {
                try await self.callRecorder.start()
                if attempt > 1 {
                    AppDelegate.debugLog("call start: succeeded on attempt \(attempt)")
                }
                return
            } catch CallRecorderError.alreadyRunning {
                let recorderHealthConfirmed = self.callRecorder.isFullyRunning
                if Self.canAcceptAlreadyRunningCallRecorder(isHealthy: recorderHealthConfirmed) {
                    return
                }
                lastError = CallRecorderError.alreadyRunning
                AppDelegate.debugLog("call start: stale/unverified running recorder - resetting")
                self.callRecorder.forceStop()
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(200 * attempt))
                    guard !Task.isCancelled else { break }
                }
            } catch {
                lastError = error
                AppDelegate.debugLog("call start: attempt \(attempt)/\(maxAttempts) failed: \(error)")
                if attempt < maxAttempts {
                    // Short backoff: 200 ms, 400 ms. Gives the mic device and
                    // ScreenCaptureKit a moment to become ready after a cold grant.
                    try? await Task.sleep(for: .milliseconds(200 * attempt))
                    guard !Task.isCancelled else { break }
                }
            }
        }
        throw lastError ?? CallRecorderError.noAudio
    }

    private func finishCallRecording(hideOverlay: Bool = true) {
        if hideOverlay { overlay.hide() }
        state = .idle
        fileQueue?.resume()
        resetMenubar()
        callMenuItem.title = "Record Call"
        dictateMenuItem.isEnabled = true
    }

    private func beginCallFinalization() {
        state = .callTranscribing
        overlay.show(mode: .loading)
        updateCallTranscriptionProgress(.preparing)
        // Cap the pill at ~3 s. The transcribe+diarize pass runs in the
        // background and must NOT keep the overlay up for the full duration.
        // Hide on a timer, decoupled from the task; the `.loading` guard keeps
        // a later "Call saved"/error flash from being torn down early.
        let overlayCapHide = DispatchWorkItem { [weak self] in
            guard let self, self.overlay.currentMode == .loading else { return }
            self.overlay.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: overlayCapHide)
        callMenuItem.isEnabled = false
        dictateMenuItem.isEnabled = false
    }

    /// Shared stop transaction for an explicit user stop and an interruption
    /// discovered at the recorder-to-UI handoff. `CallRecorder.stop()` owns the
    /// interruption snapshot, so both paths publish identical partial metadata.
    private func finalizeCallRecording(sourceApp: String?) async {
        defer { finishCallRecording(hideOverlay: false) }

        let audio = await callRecorder.stop()
        guard !Task.isCancelled else { return }
        guard let audio,
              audio.micFileURL != nil || audio.systemFileURL != nil else {
            NSLog("[Voicely] No call audio captured")
            overlay.showError("No audio captured")
            return
        }
        await processCallRecording(audio: audio, sourceApp: sourceApp)
    }

    private func rollbackCallStart() {
        state = .idle
        fileQueue?.resume()
        callMenuItem.title = "Record Call"
        callMenuItem.isEnabled = true
        dictateMenuItem.isEnabled = true
        resetMenubar()
    }

    // MARK: - Menu Actions

    nonisolated static func availableModels(
        from models: [WhisperModel],
        operatingSystemVersion: OperatingSystemVersion
    ) -> [WhisperModel] {
        models.filter { $0.isSupported(on: operatingSystemVersion) }
    }

    nonisolated static func recommendedModel(
        preferred: WhisperModel,
        available: [WhisperModel]
    ) -> WhisperModel {
        available.first(where: { $0 == preferred }) ?? available.first ?? preferred
    }

    nonisolated static func runtimeMutationsAllowed(
        appState: AppState,
        fileWorkActive: Bool
    ) -> Bool {
        appState == .idle && !fileWorkActive
    }

    /// Whether the model-setup overlay is still up, in either of the two modes
    /// it passes through.
    ///
    /// A download watchdog that only recognised `.downloading` disarmed itself
    /// the moment progress reached `.loadingModel` and the overlay switched to
    /// `.loading` — a mode with no auto-hide. The pill then stayed on screen
    /// forever. Both modes belong to the same "setting up a model" pill, so the
    /// watchdog must accept either.
    nonisolated static func isModelSetupOverlay(_ mode: OverlayMode?) -> Bool {
        switch mode {
        case .downloading, .loading: return true
        default: return false
        }
    }

    nonisolated static func canStartFileTranscription(
        modelReady: Bool,
        appState: AppState
    ) -> Bool {
        modelReady && appState == .idle
    }

    nonisolated static func compatibleLanguageModes(
        for model: WhisperModel
    ) -> [LanguageMode] {
        let capabilities = model.capabilities
        if !capabilities.supportsLanguageDetection,
           let supported = capabilities.supportedLanguages {
            return [LanguageMode.russian, .english].filter {
                guard let language = $0.preferredLanguage else { return false }
                return supported.contains(language)
            }
        }

        var modes: [LanguageMode] = []
        if capabilities.supportsLanguageDetection { modes.append(.auto) }
        if capabilities.supportsTranslationToEnglish {
            modes.append(.translateToEnglish)
        }
        return modes.isEmpty ? [.auto] : modes
    }

    nonisolated static func normalizedLanguageMode(
        _ requested: LanguageMode,
        for model: WhisperModel
    ) -> LanguageMode {
        let compatible = compatibleLanguageModes(for: model)
        return compatible.contains(requested) ? requested : (compatible.first ?? .auto)
    }

    private var currentLanguageMode: LanguageMode {
        if transcriber.translateToEnglish { return .translateToEnglish }
        switch transcriber.preferredLanguage?.lowercased() {
        case "ru": return .russian
        case "en": return .english
        default: return .auto
        }
    }

    private func normalizeLanguageModeForSelectedModel(
        persist: Bool,
        announce: Bool
    ) {
        let requested = currentLanguageMode
        let normalized = Self.normalizedLanguageMode(
            requested,
            for: transcriber.selectedModel
        )
        applyLanguageMode(
            requested,
            persist: persist,
            resetSession: requested != normalized,
            announceNormalization: announce && requested != normalized
        )
    }

    private func ensureCaptureConfiguration() -> Bool {
        let model = transcriber.selectedModel
        guard model.isSupported(on: ProcessInfo.processInfo.operatingSystemVersion) else {
            overlay.showError("\(model.displayName) requires macOS \(model.capabilities.minimumMacOSMajorVersion)+")
            return false
        }
        normalizeLanguageModeForSelectedModel(persist: true, announce: true)
        if let error = model.requestValidationError(
            translateToEnglish: transcriber.translateToEnglish,
            language: transcriber.preferredLanguage
        ) {
            overlay.showError(error)
            return false
        }
        return true
    }

    private func refreshRuntimeMutationMenus() {
        if modelMenuItem != nil { rebuildModelSubmenu() }
        rebuildLanguageSubmenu(selected: currentLanguageMode)
    }

    private func rebuildLanguageSubmenu(selected: LanguageMode) {
        guard let item = languageMenuItem else { return }
        let submenu = NSMenu()
        let enabled = Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        )
        for mode in Self.compatibleLanguageModes(for: transcriber.selectedModel) {
            let menuItem = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = mode.rawValue
            menuItem.state = mode == selected ? .on : .off
            menuItem.isEnabled = enabled
            submenu.addItem(menuItem)
        }
        item.title = "Language: \(selected.menuTitle)"
        item.submenu = submenu
        item.isEnabled = enabled
    }

    @objc func openTranscripts() {
        NSWorkspace.shared.open(storage.baseDir)
    }

    /// Standard About panel with required open-source attribution. The speaker
    /// diarization weights (pyannote segmentation + WeSpeaker embeddings, shipped
    /// via FluidAudio) are licensed CC-BY-4.0, which REQUIRES visible credit; the
    /// FluidAudio SDK itself is Apache-2.0. Keep this in sync with any added
    /// third-party component whose license demands attribution.
    @objc func showAbout() {
        let credits = NSMutableAttributedString()
        let body: [(String, Bool)] = [
            ("Offline voice-to-text, calls, and file transcription.\n\n", false),
            ("Speech recognition: WhisperKit (MIT) + OpenAI Whisper models.\n", false),
            ("Parakeet ASR: NVIDIA Parakeet TDT 0.6B v3 weights, licensed CC-BY-4.0; CoreML conversion by FluidInference.\n", false),
            ("Speaker diarization: FluidAudio (Apache-2.0).\n", false),
            ("Diarization models: pyannote segmentation and WeSpeaker embeddings, licensed CC-BY-4.0.\n", false),
        ]
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (line, _) in body {
            credits.append(NSAttributedString(string: line, attributes: attrs))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Voicely — free forever.",
        ])
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }
        guard let value = sender.representedObject as? String,
              let mode = LanguageMode(rawValue: value) else { return }
        applyLanguageMode(
            mode,
            persist: true,
            resetSession: true,
            announceNormalization: true
        )
    }

    private func applyLanguageMode(
        _ mode: LanguageMode,
        persist: Bool,
        resetSession: Bool = true,
        announceNormalization: Bool = false
    ) {
        let normalized = Self.normalizedLanguageMode(
            mode,
            for: transcriber.selectedModel
        )
        if persist {
            UserDefaults.standard.set(normalized.rawValue, forKey: "voicelyLanguage")
        }
        transcriber.translateToEnglish = normalized.translateToEnglish
        transcriber.preferredLanguage = normalized.preferredLanguage
        if resetSession {
            transcriber.resetLanguageSession()
        }

        rebuildLanguageSubmenu(selected: normalized)
        if announceNormalization, normalized != mode {
            overlay.showInfo("\(transcriber.selectedModel.displayName) uses \(normalized.menuTitle)")
        }
        // Surface the translate state in the menu bar itself so the user
        // never wonders why their Russian dictation came out as English.
        applyTranslateIndicator()
    }

    /// Switch the menubar icon (or its tooltip) to make translate-to-English
    /// visible at a glance. Call after toggling ``translateToEnglish`` or
    /// any time the idle menubar icon is restored.
    private func applyTranslateIndicator() {
        guard let button = statusItem?.button else { return }
        if transcriber.translateToEnglish {
            button.toolTip = "Translate to English is ON. Dictation output is in English regardless of the spoken language."
            // SF Symbol with a translate hint; falls back silently if unavailable.
            if let icon = NSImage(systemSymbolName: "character.bubble.fill",
                                  accessibilityDescription: "Translate to English") {
                icon.size = NSSize(width: 16, height: 16)
                icon.isTemplate = true
                button.image = icon
            }
        } else {
            button.toolTip = nil
            button.image = Self.makeMenuBarIcon()
        }
    }

    /// Restore the idle menubar icon, picking the translate-aware variant if needed.
    /// Use this everywhere we'd otherwise write ``button.image = makeMenuBarIcon()``
    /// so the translate hint isn't accidentally clobbered when transcription /
    /// recording finishes.
    private func restoreIdleMenuBarIcon() {
        applyTranslateIndicator()
    }

    nonisolated static func shouldDeferTermination(for state: AppState) -> Bool {
        switch state {
        case .recording, .transcribing,
             .callStarting, .callRecording, .callTranscribing:
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard Self.shouldDeferTermination(for: state) else {
            return .terminateNow
        }
        guard !terminationReplyPending else {
            return .terminateLater
        }

        terminationReplyPending = true
        callCapturePreparedForTermination = false
        let activeState = state
        let activeCallTask = callTask
        let activeTranscriptionTask = transcriptionTask
        if activeState == .recording || activeState == .transcribing {
            dictationTerminationInProgress = true
            dictationPreparedForTermination = false
        }

        terminationTask = Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            switch activeState {
            case .recording:
                // Reuse the normal stop transaction: close the chunk producer,
                // await its one ASR-owned chunk, decode the tail, and save.
                self.lastDictationToggle = .distantPast
                self.toggleDictation()
                await self.transcriptionTask?.value
                if self.activeDictationRecovery != nil {
                    self.preserveActiveDictationRecovery(
                        reason: "termination_finalize_incomplete"
                    )
                }
                self.dictationPreparedForTermination = true
                NSLog("[Voicely] Quit during dictation recording: graceful finalize completed.")

            case .transcribing:
                await activeTranscriptionTask?.value
                if self.activeDictationRecovery != nil {
                    self.preserveActiveDictationRecovery(
                        reason: "termination_transcription_incomplete"
                    )
                }
                self.dictationPreparedForTermination = true
                NSLog("[Voicely] Quit during dictation transcription: finalize completed.")

            case .callStarting:
                activeCallTask?.cancel()
                self.callRecorder.forceStop()
                self.callCapturePreparedForTermination = true
                NSLog("[Voicely] Quit during call start: durable recovery fallback flushed.")

            case .callRecording:
                // Stop both producers and synchronously drain the bounded WAV
                // queues, then attempt the normal artifact transaction. The
                // bounded timeout below cancels long ASR and leaves the durable
                // source for relaunch recovery.
                if let audio = await self.callRecorder.stop(),
                   !Task.isCancelled {
                    await self.processCallRecording(
                        audio: audio,
                        sourceApp: self.dictationSourceApp
                    )
                }
                self.callCapturePreparedForTermination = true
                NSLog("[Voicely] Quit during call recording: graceful finalize window completed.")

            case .callTranscribing:
                // Give an already-running artifact transaction the same bounded
                // window. The timeout below preserves its source staging if it
                // cannot finish before AppKit must terminate.
                await activeCallTask?.value
                self.callCapturePreparedForTermination = true

            default:
                break
            }
            self.replyToDeferredTermination(sender)
        }

        let graceSeconds = activeState == .recording || activeState == .transcribing
            ? Self.dictationTerminationGraceSeconds
            : Self.callTerminationGraceSeconds
        DispatchQueue.main.asyncAfter(
            deadline: .now() + graceSeconds
        ) { [weak self, weak sender] in
            guard let self, let sender, self.terminationReplyPending else { return }
            self.terminationTask?.cancel()
            switch activeState {
            case .recording, .transcribing:
                self.dictationChunkSessionID = nil
                self.chunkTask?.cancel()
                self.chunkTask = nil
                self.transcriptionTask?.cancel()
                self.transcriber.cancelCurrentTask()
                self.stopAndPreserveDictationForTermination(
                    reason: "termination_grace_timeout"
                )
                self.dictationPreparedForTermination = true
                NSLog("[Voicely] Dictation Quit grace period expired; audio retained for recovery.")

            case .callStarting, .callRecording, .callTranscribing:
                self.callTask?.cancel()
                self.transcriber.cancelCurrentTask()
                self.callRecorder.forceStop()
                self.callCapturePreparedForTermination = true
                NSLog("[Voicely] Call Quit grace period expired; durable recovery fallback flushed.")

            default:
                break
            }
            self.replyToDeferredTermination(sender)
        }
        return .terminateLater
    }

    private func replyToDeferredTermination(_ sender: NSApplication) {
        guard terminationReplyPending else { return }
        terminationReplyPending = false
        terminationTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if (state == .recording || state == .transcribing),
           !dictationPreparedForTermination {
            dictationTerminationInProgress = true
            dictationChunkSessionID = nil
            stopAndPreserveDictationForTermination(
                reason: "forced_termination"
            )
            dictationPreparedForTermination = true
            NSLog(
                "[Voicely] Forced Quit during dictation state=%@; audio retained for recovery.",
                "\(state)"
            )
        }

        // #3: Cancel preload task to prevent corrupted partial downloads
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskOwner = nil

        // #12: Cancel any in-progress transcription
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // #7: Cancel any in-progress call task
        callTask?.cancel()
        callTask = nil
        terminationTask?.cancel()
        terminationTask = nil

        chunkTask?.cancel()
        chunkTask = nil
        dictationChunkSessionID = nil
        dictationSessionOwner = nil
        dictationInjectionTarget = nil

        // Stop any in-flight file transcription work so pending writes
        // don't leave half-written transcripts behind.
        fileQueue?.cancelAll()
        fileQueue = nil

        _ = recorder.stop()

        // applicationShouldTerminate normally drains an active capture first.
        // Keep a synchronous recovery fallback for forced/system termination,
        // where AppKit may reach this callback without completing the deferral.
        if state == .callStarting || state == .callRecording || state == .callTranscribing {
            if callCapturePreparedForTermination {
                NSLog("[Voicely] Quit with active call state=%@; capture is durable for recovery.", "\(state)")
            } else {
                NSLog("[Voicely] Forced Quit during active call state=%@; flushing durable recovery fallback.", "\(state)")
                callRecorder.forceStop()
                callCapturePreparedForTermination = true
            }
        }

        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc func selectHotkeyPreset(_ sender: NSMenuItem) {
        guard let combo = sender.representedObject as? HotkeyCombo else { return }
        hotkey.updateHotkey(combo)
        updateHotkeyMenu()
    }

    @objc func recordCustomHotkey() {
        guard state == .idle else { return }
        let alert = NSAlert()
        alert.messageText = "Record Custom Hotkey"
        alert.informativeText = "Press the key combination you want to use, then click Save.\n\nCurrent: \(hotkey.combo.displayName)"
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Click here and press your hotkey..."
        field.isEditable = false
        field.alignment = .center
        alert.accessoryView = field

        // The monitor block runs inside AppKit's modal event dispatch, outside
        // any Swift concurrency context. An isolation-inheriting closure gets a
        // runtime executor check there, which crashes on macOS 26 — keep the
        // block @Sendable (no MainActor state) and defer the UI write.
        let capturedBox = RecordedHotkeyBox()
        let fieldRef = field
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @Sendable event in
            // Let unmodified Escape pass through so user can cancel the dialog
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
                return event
            }
            let flags = HotkeyCombo.cgEventFlags(from: event.modifierFlags)
            let combo = HotkeyCombo(keyCode: Int64(event.keyCode), modifiers: flags)
            capturedBox.set(combo)
            Task { @MainActor in
                fieldRef.stringValue = combo.displayName
            }
            return nil
        }

        alert.addButton(withTitle: "Save")
        let response = alert.runModal()

        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }

        if response == .alertSecondButtonReturn, let combo = capturedBox.current {
            // Require at least one modifier to prevent consuming plain keypresses system-wide
            let comboFlags = CGEventFlags(rawValue: combo.modifiers)
            let hasModifier = comboFlags.contains(.maskControl) || comboFlags.contains(.maskAlternate)
                || comboFlags.contains(.maskShift) || comboFlags.contains(.maskCommand)
            guard hasModifier else {
                let noModAlert = NSAlert()
                noModAlert.messageText = "Modifier Required"
                noModAlert.informativeText = "Hotkey must include at least one modifier (⌃ ⌥ ⇧ ⌘) to avoid capturing regular typing."
                noModAlert.addButton(withTitle: "OK")
                noModAlert.runModal()
                return
            }

            // #21: Check for conflicts with known system shortcuts
            let conflictWarning = checkHotkeyConflict(combo)
            if let warning = conflictWarning {
                let confirmAlert = NSAlert()
                confirmAlert.messageText = "Hotkey Conflict"
                confirmAlert.informativeText = "\(warning)\n\nUse this hotkey anyway?"
                confirmAlert.addButton(withTitle: "Use Anyway")
                confirmAlert.addButton(withTitle: "Cancel")
                guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }
            }

            hotkey.updateHotkey(combo)
            updateHotkeyMenu()
        }
    }

    // #21: Check hotkey against known system shortcuts
    private func checkHotkeyConflict(_ combo: HotkeyCombo) -> String? {
        let flags = CGEventFlags(rawValue: combo.modifiers)
        let hasCmd = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        let hasAlt = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)

        // Ctrl+Space: macOS input source switching
        if hasCtrl && !hasCmd && !hasAlt && !hasShift && combo.keyCode == 49 {
            return "Ctrl+Space (Input Source Switching) is a system shortcut. It may not work as a Voicely hotkey."
        }

        // Cmd-only shortcuts (no Ctrl, Alt, Shift)
        guard hasCmd && !hasCtrl && !hasAlt && !hasShift else { return nil }

        // keyCode mapping for known conflicts (Cmd+key)
        let conflicts: [(keyCode: Int64, name: String)] = [
            (49, "Cmd+Space (Spotlight)"),     // Space
            (48, "Cmd+Tab (App Switcher)"),    // Tab
            (12, "Cmd+Q (Quit)"),              // Q
            (13, "Cmd+W (Close Window)"),      // W
            (4,  "Cmd+H (Hide)"),              // H
        ]

        for conflict in conflicts {
            if combo.keyCode == conflict.keyCode {
                return "\(conflict.name) is a system shortcut. It may not work as a Voicely hotkey."
            }
        }
        return nil
    }

    private func updateHotkeyMenu() {
        hotkeyMenuItem?.title = "Hotkey: \(hotkey.combo.displayName)"
        dictateMenuItem?.title = "Dictate  (\(hotkey.combo.displayName))"
        if let submenu = hotkeyMenuItem?.submenu {
            for item in submenu.items {
                if let combo = item.representedObject as? HotkeyCombo {
                    item.state = combo == hotkey.combo ? .on : .off
                }
            }
        }
    }

    @objc func selectModelPreset(_ sender: NSMenuItem) {
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }
        guard let variant = sender.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.variant == variant })
        else { return }
        guard model.isSupported(on: ProcessInfo.processInfo.operatingSystemVersion) else {
            overlay.showError("\(model.displayName) requires macOS \(model.capabilities.minimumMacOSMajorVersion)+")
            return
        }
        // Skip if already selected and active
        if model == transcriber.selectedModel && (modelReady || preloadTask != nil) { return }

        // Confirm download
        let alert = NSAlert()
        alert.messageText = "Download \(model.displayName)?"
        var info = "This will download \(model.sizeLabel) to your Mac. Needs \(model.ramRequirementLabel). The first prepare step may take a minute."
        if let hint = model.onboardingHint {
            info += "\n\n\(hint)."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Commit-time guard for the modal nested event loop. A hotkey event may
        // have started live capture after the menu action was accepted.
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }

        // Any existing file queue holds a reference to the old engine —
        // drop it so the next file transcription picks up the new model.
        fileQueue?.cancelAll()
        fileQueue = nil

        transcriber.selectModel(model)
        normalizeLanguageModeForSelectedModel(persist: true, announce: true)
        modelState = .downloading(model, 0)
        overlay.show(mode: .downloading)
        overlay.updateProgress(0, status: "Voice model...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  Self.isModelSetupOverlay(self.overlay.currentMode) else { return }
            self.overlay.hide()
        }

        preloadTask?.cancel()
        let preloadOwner = UUID()
        preloadTaskOwner = preloadOwner
        preloadTask = Task {
            defer { self.clearPreloadTask(completingOwner: preloadOwner) }
            do {
                try await transcriber.preloadModel()
                self.modelState = .ready(model)
                self.overlay.hide()
                self.showReadyNotification()
            } catch {
                guard !Task.isCancelled else { return }
                self.overlay.hide()
                let msg = Self.classifyModelError(error)
                self.overlay.showError(msg)
                self.modelState = .failed(model, msg)
            }
        }
    }

    // Delete current model from disk, fall back to another or show selection
    @objc func deleteCurrentModel() {
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }

        let model = transcriber.selectedModel
        let alert = NSAlert()
        alert.messageText = "Delete \(model.displayName)?"
        alert.informativeText = "This will free \(model.sizeLabel) of disk space."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // A modal alert runs a nested event loop. The global hotkey can start
        // capture while the confirmation is open, so re-check at commit time.
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }
        scheduleModelRemoval(
            model: model,
            cleanupDownloadCache: false,
            completionMessage: "Select a model"
        )
    }

    // #25: Re-trigger onboarding setup wizard
    @objc func runSetupWizard() {
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }
        Task {
            let result = await onboarding.runIfNeeded()
            if result.accessibilityGranted {
                let active = hotkey.retryIfNeeded()
                handleHotkeyRuntimeState(active ? .active : hotkey.runtimeState)
            } else {
                handleHotkeyRuntimeState(.permissionMissing)
            }
            // Restart model preload if the app still has no ready model. The
            // model picker / downloader should stay available even when the
            // user deferred microphone access, so this matches first launch.
            if !modelState.isReady && preloadTask == nil {
                if !transcriber.hasSavedModelSelection {
                    modelState = .noModel
                    guard let chosenModel = promptForInitialModelSelection() else {
                        overlay.showInfo("Select a model")
                        return
                    }
                    transcriber.selectModel(chosenModel)
                    normalizeLanguageModeForSelectedModel(
                        persist: true,
                        announce: true
                    )
                }
                let model = transcriber.selectedModel
                overlay.showInfo("Retrying model...")
                modelState = .preparing(model)
                let preloadOwner = UUID()
                preloadTaskOwner = preloadOwner
                preloadTask = Task {
                    defer { self.clearPreloadTask(completingOwner: preloadOwner) }
                    do {
                        try await transcriber.preloadModel()
                        self.modelState = .ready(model)
                        self.overlay.hide()
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.overlay.hide()
                        let msg = Self.classifyModelError(error)
                        self.overlay.showError(msg)
                        self.modelState = .failed(model, msg)
                    }
                }
            }
        }
    }



    @objc func cancelModelDownload() {
        guard Self.runtimeMutationsAllowed(
            appState: state,
            fileWorkActive: fileWorkActive
        ) else {
            overlay.showInfo("Finish active transcription first")
            return
        }
        scheduleModelRemoval(
            model: transcriber.selectedModel,
            cleanupDownloadCache: true,
            completionMessage: "Cancelled"
        )
    }

    private func scheduleModelRemoval(
        model: WhisperModel,
        cleanupDownloadCache: Bool,
        completionMessage: String
    ) {
        // A completed queue still owns the raw engine selected when it was
        // created. Drop it before model teardown so setup-wizard retry cannot
        // enqueue new work on that stale engine. Its in-flight task, if any,
        // still releases the shared coordinator lease before the drain below.
        fileQueue?.cancelAll()
        fileQueue = nil
        let operationToDrain = preloadTask
        operationToDrain?.cancel()
        transcriber.cancelCurrentTask()
        WhisperModel.clearSavedSelection()
        modelState = .preparing(model)
        overlay.showInfo("Stopping model work...")

        let cleanupOwner = UUID()
        preloadTaskOwner = cleanupOwner
        preloadTask = Task {
            defer { self.clearPreloadTask(completingOwner: cleanupOwner) }
            _ = await operationToDrain?.value
            await transcriber.coordinator.waitUntilIdle()
            guard !Task.isCancelled else { return }

            if cleanupDownloadCache {
                transcriber.cancelAndCleanup(model: model)
            } else {
                try? FileManager.default.removeItem(at: model.modelDirectory)
                transcriber.cancelAndReset()
                print("[Voicely] Deleted model: \(model.displayName)")
            }
            modelState = .noModel
            overlay.hide()
            overlay.showInfo(completionMessage)
        }
    }

    nonisolated static func preloadTaskCompletionOwnsSlot(
        completingOwner: UUID,
        currentOwner: UUID?
    ) -> Bool {
        completingOwner == currentOwner
    }

    private func clearPreloadTask(completingOwner: UUID) {
        guard Self.preloadTaskCompletionOwnsSlot(
            completingOwner: completingOwner,
            currentOwner: preloadTaskOwner
        ) else { return }
        preloadTask = nil
        preloadTaskOwner = nil
    }

    nonisolated static func dictationFinalizationOwnsSession(
        completingOwner: UUID,
        currentOwner: UUID?
    ) -> Bool {
        completingOwner == currentOwner
    }

    private func finishDictationSessionIfOwned(_ completingOwner: UUID) {
        guard Self.dictationFinalizationOwnsSession(
            completingOwner: completingOwner,
            currentOwner: dictationSessionOwner
        ) else { return }
        dictationSessionOwner = nil
        dictationInjectionTarget = nil
        state = .idle
        discardWindow = nil
        transcribeEscapeArmed = false
        transcriptionTask = nil
        fileQueue?.resume()
        resetMenubar()
    }

    private func commitActiveDictationRecovery(transcriptURL: URL?) {
        guard let recovery = activeDictationRecovery else { return }
        let committed = dictationTerminationGate.commit {
            recovery.complete(transcriptURL: transcriptURL)
        }
        if committed {
            activeDictationRecovery = nil
        }
    }

    private func preserveActiveDictationRecovery(reason: String) {
        guard let recovery = activeDictationRecovery else { return }
        let preserved = dictationTerminationGate.recover(reason: reason) {
            recovery.preserve(reason: reason)
        }
        if preserved {
            activeDictationRecovery = nil
        }
    }

    private func applyDictationRecoveryDisposition(
        _ disposition: DictationRecoveryDisposition,
        transcriptURL: URL?
    ) {
        switch disposition {
        case .commit:
            commitActiveDictationRecovery(transcriptURL: transcriptURL)
        case .preserve(let reason):
            preserveActiveDictationRecovery(reason: reason)
        }
    }

    private func stopAndPreserveDictationForTermination(reason: String) {
        if activeDictationRecovery == nil {
            _ = recorder.stop()
            activeDictationRecovery = recorder.takeDictationRecoverySession()
        }
        preserveActiveDictationRecovery(reason: reason)
    }

    nonisolated static let dictationGapMarker = "[…]"
    nonisolated static let dictationIncompleteRecoveryReason =
        "transcription_failed_or_incomplete"
    nonisolated static let partialCallReasonSystemChannelMissing = "system_channel_missing"
    nonisolated static let partialCallReasonSystemChannelEffectivelySilent = "system_channel_effectively_silent"
    nonisolated static let partialCallReasonSystemChannelTruncated = "system_channel_truncated"
    nonisolated static let partialCallReasonMicChannelMissing = "mic_channel_missing"
    nonisolated static let partialCallReasonMicChannelEffectivelySilent = "mic_channel_effectively_silent"
    nonisolated static let partialCallReasonMicChannelTruncated = "mic_channel_truncated"
    nonisolated static let partialCallReasonMultipleChannelsUnavailable = "multiple_channels_unavailable"
    nonisolated static let partialCallReasonCaptureDroppedFrames = "capture_dropped_frames"
    nonisolated static let partialCallReasonCaptureTimelineDegraded = "capture_timeline_degraded"
    nonisolated static let partialCallReasonCaptureInterrupted = "capture_interrupted"
    nonisolated static let partialCallReasonRecoveredAfterInterruption = "capture_recovered_after_interruption"
    private static let emptyResultRescuePreferredWindowSeconds: Double = 10
    private static let emptyResultRescueMinimumParentSeconds: Double = 2
    private static let dictationSilenceRMSFloor: Double = 0.005
    nonisolated private static let callCaptureDurationComparisonMinimumSeconds: Double = 10
    nonisolated private static let callCaptureDurationToleranceSeconds: Double = 5

    nonisolated static func dictationRecoveryDisposition(
        for outcome: DictationDecodeOutcome,
        transcriptSaveSucceeded: Bool?,
        terminationInProgress: Bool
    ) -> DictationRecoveryDisposition {
        if outcome.requiresRecovery {
            return .preserve(reason: dictationIncompleteRecoveryReason)
        }
        if transcriptSaveSucceeded == false {
            return .preserve(
                reason: terminationInProgress
                    ? "termination_transcript_save_failed"
                    : "transcript_save_failed"
            )
        }
        return .commit
    }

    /// A drained tail is represented explicitly by `.noSamples`; it does not
    /// invalidate already-decoded chunks. Losing the engine or audio format is
    /// different: an unknown tail may be missing, so raw recovery must survive.
    nonisolated static func dictationOutcomeAfterRecorderStop(
        _ error: RecorderError?,
        completedChunks: DictationDecodeOutcome
    ) -> DictationDecodeOutcome {
        var outcome = completedChunks
        switch error {
        case .some(.noEngine), .some(.formatError):
            outcome.recordIncomplete(gapMarker: dictationGapMarker)
        case .some(.noSamples), .none:
            break
        }
        return outcome
    }

    nonisolated static func callCaptureMetadata(
        system: CallRecorder.ChannelCaptureTruth,
        mic: CallRecorder.ChannelCaptureTruth,
        interruptionReason: String? = nil
    ) -> CallTranscriptCaptureMetadata {
        let systemMissing = system.sampleCount == 0
        let micMissing = mic.sampleCount == 0
        let systemSilent = !systemMissing && system.isEffectivelySilent
        let micSilent = !micMissing && mic.isEffectivelySilent
        let micDuration = mic.durationSeconds
        let systemDuration = system.durationSeconds
        let channelEndGap = abs(systemDuration - micDuration)

        if let interruptionReason = interruptionReason?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !interruptionReason.isEmpty {
            var affectedChannels: [String] = []
            if systemMissing || systemSilent { affectedChannels.append("system") }
            if micMissing || micSilent { affectedChannels.append("mic") }
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonCaptureInterrupted,
                interruptionReason: interruptionReason,
                note: "Call capture was interrupted: \(interruptionReason). Audio after the interruption is unavailable; this transcript contains only the durable prefix.",
                missingChannels: affectedChannels,
                systemMeanVolumeDBFS: systemSilent ? system.meanVolumeDBFS : nil,
                systemPeakVolumeDBFS: systemSilent ? system.peakVolumeDBFS : nil,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if (systemMissing || systemSilent), (micMissing || micSilent) {
            let systemIssue: String
            if systemMissing {
                systemIssue = system.isDegraded
                    ? "System audio channel was not captured (\(channelCaptureDegradationDetail(channel: "system", truth: system)))."
                    : "System audio channel was not captured."
            } else {
                let meanText = String(format: "%.1f", system.meanVolumeDBFS)
                let peakText = String(format: "%.1f", system.peakVolumeDBFS)
                systemIssue = "System audio channel was effectively silent (mean \(meanText) dBFS, peak \(peakText) dBFS)."
            }

            let micIssue: String
            if micMissing {
                micIssue = mic.isDegraded
                    ? "Microphone audio channel was not captured (\(channelCaptureDegradationDetail(channel: "mic", truth: mic)))."
                    : "Microphone audio channel was not captured."
            } else {
                let meanText = String(format: "%.1f", mic.meanVolumeDBFS)
                let peakText = String(format: "%.1f", mic.peakVolumeDBFS)
                micIssue = "Microphone audio channel was effectively silent (mean \(meanText) dBFS, peak \(peakText) dBFS)."
            }

            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonMultipleChannelsUnavailable,
                note: "\(systemIssue) \(micIssue) Both sides are incomplete in this transcript.",
                missingChannels: ["system", "mic"],
                systemMeanVolumeDBFS: systemSilent ? system.meanVolumeDBFS : nil,
                systemPeakVolumeDBFS: systemSilent ? system.peakVolumeDBFS : nil,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if system.sampleCount == 0 {
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonSystemChannelMissing,
                note: system.isDegraded
                    ? "System audio channel was not captured (\(channelCaptureDegradationDetail(channel: "system", truth: system))). The remote/system side is missing from this transcript."
                    : "System audio channel was not captured. The remote/system side may be missing from this transcript.",
                missingChannels: ["system"],
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if mic.sampleCount == 0 {
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonMicChannelMissing,
                note: mic.isDegraded
                    ? "Microphone audio channel was not captured (\(channelCaptureDegradationDetail(channel: "mic", truth: mic))). Your side is missing from this transcript."
                    : "Microphone audio channel was not captured. Your side may be missing from this transcript.",
                missingChannels: ["mic"],
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if system.isEffectivelySilent {
            let meanText = String(format: "%.1f", system.meanVolumeDBFS)
            let peakText = String(format: "%.1f", system.peakVolumeDBFS)
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonSystemChannelEffectivelySilent,
                note: "System audio channel was effectively silent (mean \(meanText) dBFS, peak \(peakText) dBFS). The remote/system side may be missing from this transcript.",
                missingChannels: ["system"],
                systemMeanVolumeDBFS: system.meanVolumeDBFS,
                systemPeakVolumeDBFS: system.peakVolumeDBFS,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if mic.isEffectivelySilent {
            let meanText = String(format: "%.1f", mic.meanVolumeDBFS)
            let peakText = String(format: "%.1f", mic.peakVolumeDBFS)
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonMicChannelEffectivelySilent,
                note: "Microphone audio channel was effectively silent (mean \(meanText) dBFS, peak \(peakText) dBFS). Your side may be missing from this transcript.",
                missingChannels: ["mic"],
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        if system.isDegraded || mic.isDegraded {
            var affected: [String] = []
            var details: [String] = []
            if system.isDegraded {
                affected.append("system")
                details.append(channelCaptureDegradationDetail(
                    channel: "system",
                    truth: system
                ))
            }
            if mic.isDegraded {
                affected.append("mic")
                details.append(channelCaptureDegradationDetail(
                    channel: "mic",
                    truth: mic
                ))
            }
            let payloadWasLost = system.droppedSampleCount > 0
                || mic.droppedSampleCount > 0
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: payloadWasLost
                    ? partialCallReasonCaptureDroppedFrames
                    : partialCallReasonCaptureTimelineDegraded,
                note: "Call capture degraded (\(details.joined(separator: "; "))). Silence preserves known gaps, but affected speech may be unavailable.",
                missingChannels: affected,
                systemMeanVolumeDBFS: system.meanVolumeDBFS,
                systemPeakVolumeDBFS: system.peakVolumeDBFS,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        let longerDuration = max(system.durationSeconds, mic.durationSeconds)
        let shorterDuration = min(system.durationSeconds, mic.durationSeconds)
        let durationDifference = longerDuration - shorterDuration
        if longerDuration >= callCaptureDurationComparisonMinimumSeconds,
           durationDifference > callCaptureDurationToleranceSeconds {
            let systemText = String(format: "%.1f", system.durationSeconds)
            let micText = String(format: "%.1f", mic.durationSeconds)
            if mic.durationSeconds < system.durationSeconds {
                return CallTranscriptCaptureMetadata(
                    state: .partial,
                    partialReason: partialCallReasonMicChannelTruncated,
                    note: "Microphone audio ended early (mic \(micText)s, system \(systemText)s). Your side is incomplete in this transcript.",
                    missingChannels: ["mic"],
                    micDurationSeconds: micDuration,
                    systemDurationSeconds: systemDuration,
                    channelEndGapSeconds: channelEndGap
                )
            }
            return CallTranscriptCaptureMetadata(
                state: .partial,
                partialReason: partialCallReasonSystemChannelTruncated,
                note: "System audio ended early (system \(systemText)s, mic \(micText)s). The remote/system side is incomplete in this transcript.",
                missingChannels: ["system"],
                systemMeanVolumeDBFS: system.meanVolumeDBFS,
                systemPeakVolumeDBFS: system.peakVolumeDBFS,
                micDurationSeconds: micDuration,
                systemDurationSeconds: systemDuration,
                channelEndGapSeconds: channelEndGap
            )
        }

        return .complete
    }

    private nonisolated static func channelCaptureDegradationDetail(
        channel: String,
        truth: CallRecorder.ChannelCaptureTruth
    ) -> String {
        var parts: [String] = []
        if truth.droppedSampleCount > 0 {
            parts.append("\(truth.droppedSampleCount) payload frames unavailable")
        }
        if truth.zeroFilledSampleCount > 0 {
            parts.append("\(truth.zeroFilledSampleCount) timeline frames zero-filled")
        }
        if truth.discontinuityCount > 0 {
            parts.append(
                "\(truth.discontinuityCount) clock discontinuities, max drift "
                    + String(format: "%.3f s", truth.maxClockDriftSeconds)
            )
        }
        if truth.failure != nil {
            parts.append("capture writer reported a failure")
        }
        if parts.isEmpty {
            parts.append("timeline alignment is unverified")
        }
        return "\(channel): \(parts.joined(separator: ", "))"
    }

    nonisolated static func shouldSkipSystemChannel(
        _ metadata: CallTranscriptCaptureMetadata
    ) -> Bool {
        metadata.partialReason == partialCallReasonSystemChannelMissing
            || metadata.partialReason == partialCallReasonSystemChannelEffectivelySilent
            || metadata.partialReason == partialCallReasonMultipleChannelsUnavailable
            || (
                metadata.partialReason == partialCallReasonCaptureInterrupted
                    && metadata.missingChannels.contains("system")
            )
    }

    nonisolated static func canAcceptAlreadyRunningCallRecorder(
        isHealthy: Bool
    ) -> Bool {
        isHealthy
    }

    /// Transcribe a long audio buffer by slicing it into 30-second windows and running
    /// each through `transcriber.transcribe` separately. Used for the final remainder
    /// in dictation/call — a single long-buffer transcribe collides with the 90s decode
    /// deadline and Whisper returns just one short segment, losing most content.
    /// Returns concatenated text across successful/rescued windows.
    static func transcribeWindowed(
        buffer: AVAudioPCMBuffer,
        logPrefix: String,
        transcribe: @escaping @MainActor (AVAudioPCMBuffer) async throws -> String
    ) async -> DictationDecodeOutcome {
        let rate = buffer.format.sampleRate
        let total = Int(buffer.frameLength)
        guard total > 0 else { return .completeEmpty() }
        guard rate > 0, let channelData = buffer.floatChannelData?[0] else {
            return .incompleteGap(
                dictationGapMarker,
                hadTranscriptionFailure: false
            )
        }
        let windowSamples = Int(rate * 30)
        var outcome = DictationDecodeOutcome.completeEmpty()
        var offset = 0
        var idx = 0
        while offset < total {
            let end = min(offset + windowSamples, total)
            let count = end - offset
            idx += 1
            let durationSec = Double(count) / rate
            let slice = Array(UnsafeBufferPointer(start: channelData.advanced(by: offset), count: count))
            AppDelegate.debugLog("\(logPrefix) win #\(idx): \(count) samples (\(String(format: "%.1f", durationSec))s), transcribing...")
            let windowOutcome = await transcribeWithEmptyResultRescue(
                samples: slice,
                sampleRate: rate,
                logPrefix: "\(logPrefix) win #\(idx)",
                transcribe: transcribe
            )
            outcome.merge(windowOutcome)
            if Task.isCancelled {
                outcome.merge(.cancelled)
                break
            }
            offset = end
        }
        return outcome
    }

    private static func transcribeWindowed(
        buffer: AVAudioPCMBuffer,
        transcriber: Transcriber,
        logPrefix: String
    ) async -> DictationDecodeOutcome {
        await transcribeWindowed(buffer: buffer, logPrefix: logPrefix) { sliceBuffer in
            try await transcriber.transcribe(audio: sliceBuffer)
        }
    }

    /// Finish and commit a chunk once transcription has started, even if the
    /// surrounding chunk loop is asked to stop while the model is running.
    /// The caller owns the result collection, so a completed chunk is committed
    /// once and cannot leak into a later dictation session.
    static func transcribeAndCommitDictationChunk(
        samples: [Float],
        sampleRate: Double,
        logPrefix: String,
        transcribe: @escaping @MainActor (AVAudioPCMBuffer) async throws -> String,
        commit: @escaping @MainActor (DictationDecodeOutcome) -> Void
    ) async {
        let outcome = await transcribeWithEmptyResultRescue(
            samples: samples,
            sampleRate: sampleRate,
            logPrefix: logPrefix,
            transcribe: transcribe
        )
        commit(outcome)
    }

    /// Dictation completeness rescue: an empty decode on non-silent audio is retried
    /// by splitting the same span into smaller windows. Only keep the visible gap
    /// marker when that rescue path still produces no text.
    static func transcribeWithEmptyResultRescue(
        samples: [Float],
        sampleRate: Double,
        logPrefix: String,
        transcribe: @escaping @MainActor (AVAudioPCMBuffer) async throws -> String
    ) async -> DictationDecodeOutcome {
        guard !samples.isEmpty else { return .completeEmpty() }
        guard sampleRate > 0 else {
            return .incompleteGap(
                dictationGapMarker,
                hadTranscriptionFailure: false
            )
        }
        guard !Task.isCancelled else { return .cancelled }
        guard let buffer = makePCMBuffer(samples: samples, sampleRate: sampleRate) else {
            debugLog("\(logPrefix): FAILED to build PCM buffer")
            return .incompleteGap(
                dictationGapMarker,
                hadTranscriptionFailure: false
            )
        }

        let t0 = Date()
        var attempt = 0
        var hadTranscriptionFailure = false
        while true {
            do {
                let text = try await transcribe(buffer)
                let elapsed = Date().timeIntervalSince(t0)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    debugLog("\(logPrefix): OK \(trimmed.count) chars in \(String(format: "%.1f", elapsed))s")
                    return .recognized(
                        text,
                        hadTranscriptionFailure: hadTranscriptionFailure
                    )
                }

                guard hasNonSilentDictationAudio(samples) else {
                    debugLog("\(logPrefix): empty result in \(String(format: "%.1f", elapsed))s on silent audio (skipped)")
                    return .completeEmpty(
                        hadTranscriptionFailure: hadTranscriptionFailure
                    )
                }

                debugLog("\(logPrefix): empty result in \(String(format: "%.1f", elapsed))s on non-silent audio, rescuing")
                var rescued = await rescueEmptyDictationResult(
                    samples: samples,
                    sampleRate: sampleRate,
                    logPrefix: logPrefix,
                    transcribe: transcribe
                )
                if Task.isCancelled {
                    rescued.merge(.cancelled)
                    return rescued
                }
                if hadTranscriptionFailure {
                    rescued.recordTranscriptionFailure()
                }
                if rescued.hasRecognizedText {
                    debugLog("\(logPrefix): rescue recovered \(rescued.fragments.count) fragment(s)")
                    return rescued
                }
                debugLog("\(logPrefix): rescue failed - marker kept")
                rescued.recordIncomplete(gapMarker: dictationGapMarker)
                return rescued
            } catch is CancellationError {
                return .cancelled
            } catch {
                let elapsed = Date().timeIntervalSince(t0)
                if case .silentAudio = error as? TranscriberError {
                    debugLog("\(logPrefix): silent in \(String(format: "%.1f", elapsed))s (skipped)")
                    return .completeEmpty(
                        hadTranscriptionFailure: hadTranscriptionFailure
                    )
                }
                if case .recordingTooShort = error as? TranscriberError {
                    debugLog("\(logPrefix): tooShort in \(String(format: "%.1f", elapsed))s (skipped)")
                    return .completeEmpty(
                        hadTranscriptionFailure: hadTranscriptionFailure
                    )
                }
                if Task.isCancelled { return .cancelled }
                hadTranscriptionFailure = true
                attempt += 1
                if attempt < 2 {
                    debugLog("\(logPrefix): error after \(String(format: "%.1f", elapsed))s - retry \(attempt): \(error)")
                    continue
                }
                debugLog("\(logPrefix): FAILED after retry - marker kept: \(error)")
                return .incompleteGap(
                    dictationGapMarker,
                    hadTranscriptionFailure: true
                )
            }
        }
    }

    private static func rescueEmptyDictationResult(
        samples: [Float],
        sampleRate: Double,
        logPrefix: String,
        transcribe: @escaping @MainActor (AVAudioPCMBuffer) async throws -> String
    ) async -> DictationDecodeOutcome {
        guard let rescueWindowSamples = rescueWindowSampleCount(totalSamples: samples.count, sampleRate: sampleRate) else {
            debugLog("\(logPrefix): rescue unavailable (window too small)")
            return .completeEmpty()
        }

        let rescueDuration = Double(rescueWindowSamples) / sampleRate
        debugLog("\(logPrefix): splitting into rescue windows of \(rescueWindowSamples) samples (\(String(format: "%.1f", rescueDuration))s)")

        var rescued = DictationDecodeOutcome.completeEmpty()
        var offset = 0
        var idx = 0
        while offset < samples.count {
            guard !Task.isCancelled else {
                rescued.merge(.cancelled)
                return rescued
            }
            let end = min(offset + rescueWindowSamples, samples.count)
            let slice = Array(samples[offset..<end])
            idx += 1
            let childOutcome = await transcribeWithEmptyResultRescue(
                samples: slice,
                sampleRate: sampleRate,
                logPrefix: "\(logPrefix) rescue #\(idx)",
                transcribe: transcribe
            )
            rescued.merge(childOutcome)
            offset = end
        }
        return rescued
    }

    private static func rescueWindowSampleCount(totalSamples: Int, sampleRate: Double) -> Int? {
        guard sampleRate > 0, totalSamples > 1 else { return nil }
        let minimumParentSamples = max(1, Int(sampleRate * emptyResultRescueMinimumParentSeconds))
        guard totalSamples > minimumParentSamples else { return nil }
        let preferredSamples = max(1, Int(sampleRate * emptyResultRescuePreferredWindowSeconds))
        let rescueSamples: Int
        if totalSamples > preferredSamples * 2 {
            rescueSamples = preferredSamples
        } else {
            rescueSamples = Int(ceil(Double(totalSamples) / 2.0))
        }
        guard rescueSamples > 0, rescueSamples < totalSamples else { return nil }
        return rescueSamples
    }

    private static func hasNonSilentDictationAudio(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        let sumSquares = samples.reduce(into: 0.0) { partial, sample in
            let value = Double(sample)
            partial += value * value
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        return rms >= dictationSilenceRMSFloor
    }

    /// Build a mono AVAudioPCMBuffer from raw Float32 samples.
    private static func makePCMBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channelData.initialize(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private static func classifyModelError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("memory") || msg.contains("oom") || msg.contains("resource") {
            return "Not enough memory. Try a smaller model."
        } else if msg.contains("disk") || msg.contains("space") || msg.contains("no space") {
            return "Not enough disk space. Free up storage and retry."
        }
        return "Model failed. Select another in the menu."
    }

    /// Programmatic menubar icon - 7-bar waveform matching the Voicely logo.
    /// AppKit calls the drawing handler from its image-rendering machinery,
    /// outside any Swift concurrency context. A closure written inline here
    /// inherits the AppDelegate's MainActor isolation, and the runtime's
    /// executor check then dereferences garbage — SIGSEGV in
    /// swift_task_isCurrentExecutor on launch (macOS 26). The handler must be
    /// a nonisolated function.
    static func makeMenuBarIcon() -> NSImage {
        let icon = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: false,
            drawingHandler: Self.drawMenuBarIconBars
        )
        icon.isTemplate = true
        return icon
    }

    nonisolated static func drawMenuBarIconBars(_ rect: NSRect) -> Bool {
        let heights: [CGFloat] = [3.5, 7, 11, 15, 11, 7, 3.5]
        let barW: CGFloat = 1.8
        let gap: CGFloat = 0.7
        let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        let startX = (rect.width - total) / 2
        let cy = rect.height / 2

        NSColor.black.setFill()
        for (i, h) in heights.enumerated() {
            let x = startX + CGFloat(i) * (barW + gap)
            let r = NSRect(x: x, y: cy - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        return true
    }

    nonisolated static func debugLog(_ message: String) {
        #if DEBUG
        let line = "[\(Date())] \(message)\n"
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Voicely")
        let path = logDir.appendingPathComponent("debug.log").path

        // Create log directory if needed
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }
        #endif
    }

    private func resetMenubar() {
        callTranscriptionShownPct = nil
        restoreIdleMenuBarIcon()
        switch hotkeyRuntimeState {
        case .permissionMissing:
            statusItem.button?.title = " (grant access)"
        case .eventTapUnavailable:
            statusItem.button?.title = " (hotkey retrying)"
        case .active, .none:
            applyModelState()
        }
        dictateMenuItem.title = "Dictate  (\(hotkey.combo.displayName))"
        dictateMenuItem.isEnabled = true
        callMenuItem.title = "Record Call"
        callMenuItem.isEnabled = true
    }

    private func updateCallTranscriptionProgress(_ phase: CallTranscriptionProgressPhase) {
        let fraction = CallTranscriptionProgress.fraction(for: phase)
        let pct = Int((min(1.0, max(0.0, fraction)) * 100).rounded())
        guard callTranscriptionShownPct != pct else { return }
        callTranscriptionShownPct = pct
        statusItem.button?.title = CallTranscriptionProgress.menuBarTitle(for: fraction)
        statusItem.button?.toolTip = CallTranscriptionProgress.menuItemTitle(for: fraction)
        callMenuItem.title = CallTranscriptionProgress.menuItemTitle(for: fraction)
    }

    // MARK: - File Transcription

    struct FileTranscriptionRuntimeWiring {
        let engine: any SampleTranscribing
        let coordinator: TranscriptionCoordinator
        let requestSettings: FileTranscriptionQueue.RequestSettings

        var modelName: String { requestSettings.modelName }
    }

    static func fileTranscriptionRuntimeWiring(
        for transcriber: Transcriber
    ) -> FileTranscriptionRuntimeWiring? {
        // FileTranscriptionQueue owns the one lease around each raw engine
        // invocation. Passing Transcriber's coordinated adapter here would
        // acquire the same actor twice and deadlock.
        guard let engine = transcriber.currentEngine as? any SampleTranscribing else {
            return nil
        }
        return FileTranscriptionRuntimeWiring(
            engine: engine,
            coordinator: transcriber.coordinator,
            requestSettings: FileTranscriptionQueue.RequestSettings(
                modelName: transcriber.selectedModel.displayName,
                translateToEnglish: transcriber.translateToEnglish,
                preferredLanguage: transcriber.preferredLanguage
            )
        )
    }

    @objc func openTranscribeFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = "Transcribe"
        let accessory = TranscribeOptionsAccessoryView()
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        startFileTranscription(urls: urls, options: accessory.currentOptions)
    }

    private func startFileTranscription(
        urls: [URL],
        options: FileTranscriptionOptions
    ) {
        guard Self.canStartFileTranscription(
            modelReady: modelReady,
            appState: state
        ) else {
            overlay.showError(modelReady ? "Finish active recording first" : "Model not ready")
            return
        }
        guard let wiring = Self.fileTranscriptionRuntimeWiring(for: transcriber) else {
            overlay.showError("Model not ready")
            return
        }
        // No cap on queue size — files are processed serially, so an arbitrary
        // number can be enqueued without raising peak memory.
        if fileQueue == nil {
            let centralRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Voicely/files")
            let queue = FileTranscriptionQueue(
                transcriber: wiring.engine,
                modelName: wiring.modelName,
                centralRoot: centralRoot,
                coordinator: wiring.coordinator,
                diarizer: diarizer
            )
            queue.onStateChange = { [weak self] state, jobs in
                self?.handleFileQueueState(state, jobs: jobs)
            }
            fileQueue = queue
        }
        fileWorkActive = true
        fileQueue?.enqueue(
            urls,
            options: options,
            requestSettings: wiring.requestSettings
        )
        // Brief acknowledgment in the pill, matching the other overlays' style
        // ("Transcribing call..."). Live n/total · % lives in the menu bar; the
        // pill must NOT track the whole run — that was the "overlay hangs" bug.
        overlay.showInfo(urls.count == 1 ? "Transcribing file..." : "Transcribing files...")
    }

    private func handleFileQueueState(
        _ state: FileTranscriptionQueue.QueueState,
        jobs: [FileTranscriptionQueue.Job]
    ) {
        updateMenubarTitleForFileQueue(state: state, jobs: jobs)
        switch state {
        case .idle:
            fileWorkActive = false
            var completed = 0
            var failed = 0
            var cancelled = 0
            for job in jobs {
                switch job.status {
                case .completed: completed += 1
                case .failed: failed += 1
                case .cancelled: cancelled += 1
                default: break
                }
            }
            if jobs.isEmpty || cancelled == jobs.count {
                // Nothing to report or everything was user-cancelled.
                overlay.hide()
            } else if failed == 0 && cancelled == 0 {
                overlay.showInfo("Transcribed \(jobs.count) files")
            } else if failed > 0 {
                overlay.showError("Transcribed \(completed) of \(jobs.count) - \(failed) failed")
            } else {
                overlay.showInfo("Transcribed \(completed) of \(jobs.count)")
            }
        case .processing:
            fileWorkActive = true
            // Live progress lives in the menu bar (updateMenubarTitleForFileQueue,
            // called above). The pill only flashes once on enqueue and once on
            // completion — re-showing it on every chunk tick here was the
            // "overlay hangs the whole run" bug.
            break
        case .paused:
            fileWorkActive = true
            // Pause is almost always because dictation/call just started and is
            // showing its OWN overlay; the menu bar's "⏸ n/total" carries the
            // queue state. Don't fight the active overlay with a pill here.
            break
        }
    }

    private func updateMenubarTitleForFileQueue(
        state: FileTranscriptionQueue.QueueState,
        jobs: [FileTranscriptionQueue.Job]
    ) {
        switch state {
        case .idle:
            stopFileQueueTween()
            fileQueueShownPct = 0
            fileQueueTargetPct = 0
            // Hand control back to the model-state title.
            applyModelState()
        case .processing(let idx, let total):
            // Show OVERALL batch progress (monotonic 0→100 across all files),
            // not the current file's local % — overall never resets per file, so
            // the number only climbs and the tween stays smooth.
            fileQueueLabel = "\(idx + 1)/\(total)"
            fileQueueTargetPct = Self.overallProgress(jobs: jobs, total: total) * 100
            startFileQueueTween()
        case .paused(let idx, let total):
            stopFileQueueTween()
            statusItem.button?.title = " ⏸ \(idx + 1)/\(total)"
        }
    }

    /// Overall batch progress in 0...1: each finished job counts as 1, the file
    /// currently transcribing contributes its own fraction, and the brief
    /// extract/write phases nudge it so the bar never sits dead-still. Failed and
    /// cancelled jobs count as "done" too, so progress still reaches 100%.
    private static func overallProgress(
        jobs: [FileTranscriptionQueue.Job], total: Int
    ) -> Double {
        guard total > 0 else { return 0 }
        var done = 0.0
        for job in jobs {
            switch job.status {
            case .completed, .failed, .cancelled: done += 1
            case .transcribing(let p): done += p
            case .writing: done += 0.95
            case .extracting: done += 0.02
            case .pending: break
            }
        }
        return min(1.0, done / Double(total))
    }

    private func startFileQueueTween() {
        guard fileQueueTweenTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        // Dispatch handlers run outside Swift concurrency; assumeIsolated's
        // executor check crashes there on macOS 26 (see Overlay.swift).
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.fileQueueTweenTick() }
        }
        t.resume()
        fileQueueTweenTimer = t
    }

    private func fileQueueTweenTick() {
        let diff = fileQueueTargetPct - fileQueueShownPct
        if abs(diff) < 0.5 {
            fileQueueShownPct = fileQueueTargetPct
        } else {
            fileQueueShownPct += diff * 0.18   // ease toward the target
        }
        statusItem.button?.title = " \(fileQueueLabel) · \(Int(fileQueueShownPct.rounded()))%"
        // Settled — stop ticking; the next progress update restarts the tween.
        if abs(fileQueueTargetPct - fileQueueShownPct) < 0.5 {
            stopFileQueueTween()
        }
    }

    private func stopFileQueueTween() {
        fileQueueTweenTimer?.cancel()
        fileQueueTweenTimer = nil
    }

    private func showReadyNotification() {
        deliverNotificationIfAuthorized(
            identifier: "ready",
            title: "Voicely is ready",
            body: "Press \(hotkey.combo.displayName) to start dictating"
        )
    }

    /// Soft notification when the on-disk call spill is paused for low disk.
    /// The call keeps recording from RAM; only the diarization file stops.
    private func showDiskSpillNotification(freeMB: UInt64) {
        deliverNotificationIfAuthorized(
            identifier: "diskSpill",
            title: "Low disk space",
            body: "Call keeps recording, but per-speaker audio isn't being saved to disk (\(freeMB) MB free). Free up space to re-enable it."
        )
    }

    private func deliverNotificationIfAuthorized(
        identifier: String,
        title: String,
        body: String
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }
}

/// Thread-safe capture cell for the hotkey-recording event monitor: the
/// monitor block is @Sendable and may not touch MainActor state directly.
private final class RecordedHotkeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HotkeyCombo?

    func set(_ combo: HotkeyCombo) {
        lock.withLock { value = combo }
    }

    var current: HotkeyCombo? {
        lock.withLock { value }
    }
}
