import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import VoicelyCore

enum AppState: Sendable {
    case idle
    case recording      // dictation mode
    case transcribing
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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var state: AppState = .idle
    private var modelState: ModelState = .noModel {
        didSet { applyModelState() }
    }
    private var modelReady: Bool { modelState.isReady }

    private let recorder = Recorder()
    private lazy var callRecorder = CallRecorder()
    private let transcriber = Transcriber()
    private let injector = Injector()
    private let storage = TranscriptStorage()
    private let overlay = Overlay()
    private let hotkey = HotkeyManager()
    private let onboarding = Onboarding()

    private var dictationSourceApp: String?
    private var dictateMenuItem: NSMenuItem!
    private var callMenuItem: NSMenuItem!
    private var hotkeyMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var languageMenuItem: NSMenuItem!
    private var accessibilityTimer: Timer?
    private var lastDictationToggle: Date = .distantPast

    // #3/#5/#8: Cancellable preload task reference
    private var preloadTask: Task<Void, Never>?
    // #12: Cancellable transcription task and discard window
    private var transcriptionTask: Task<Void, Never>?
    private var discardWindow: Date?
    // #7: Cancellable call recording task
    private var callTask: Task<Void, Never>?
    // Chunked transcription: process 30s chunks during recording
    private var chunkTask: Task<Void, Never>?
    private var chunkResults: [String] = []       // dictation path still joins strings
    private var callSegments: [DialogueSegment] = []
    private var callAEC: AcousticEchoCanceller?
    private var callElapsedSec: Double = 0
    private var callDelayReestimated: Bool = false
    // N2b: speaker diarization for the collapsed system (other) channel. One
    // shared actor; lazily downloads/loads its CoreML models on first call.
    private let diarizer = DiarizationService()
    // File transcription queue (user picks 1..10 audio/video files)
    private var fileQueue: FileTranscriptionQueue?
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
        let modelItem = NSMenuItem(title: "Model: \(transcriber.selectedModel.displayName)", action: nil, keyEquivalent: "")
        menu.addItem(modelItem)
        self.modelMenuItem = modelItem
        rebuildModelSubmenu()

        menu.addItem(NSMenuItem.separator())
        // Language submenu
        let langMenu = NSMenu()
        for (title, value) in [("Auto", "auto"), ("Translate to English", "translate_en")] {
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.representedObject = value
            if value == (UserDefaults.standard.string(forKey: "voicelyLanguage") ?? "auto") {
                item.state = .on
            }
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language: Auto", action: nil, keyEquivalent: "")
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

        // Restore language setting
        if UserDefaults.standard.string(forKey: "voicelyLanguage") == "translate_en" {
            transcriber.translateToEnglish = true
            languageMenuItem?.title = "Language: Translate to English"
        }
        // Reflect the persisted translate state in the menu bar icon on
        // launch (otherwise the user sees the default mic icon even though
        // translate is silently on).
        applyTranslateIndicator()

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

        // Auto-stop call recording at the RAM-bound cap (default 8h, override via
        // VOICELY_MAX_CALL_HOURS). Bounds memory only, not a product limit.
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
        // Disk-full guard (#2): the on-disk system spill was disabled because the
        // volume ran low. Recording continues from RAM and the transcript is
        // unaffected — only the full-channel diarization file stops growing.
        // Notify softly; never stop the call.
        callRecorder.onDiskSpillStopped = { [weak self] freeBytes in
            DispatchQueue.main.async {
                guard let self else { return }
                let freeMB = freeBytes / (1024 * 1024)
                AppDelegate.debugLog("disk-full guard: system spill stopped, \(freeMB) MB free")
                self.overlay.showInfo("Low disk - call continues")
                self.showDiskSpillNotification(freeMB: freeMB)
            }
        }

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
        preloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await onboarding.runIfNeeded()

            // Register hotkey only after accessibility is confirmed
            if result.accessibilityGranted {
                hotkey.register { [weak self] in
                    self?.toggleDictation()
                }
                // Monitor for accessibility revocation at runtime
                hotkey.onAccessibilityLost = { [weak self] in
                    DispatchQueue.main.async {
                        self?.overlay.showError("Accessibility revoked")
                        self?.startAccessibilityPoller()
                    }
                }
                hotkey.startAccessibilityMonitor()
            } else {
                print("[Voicely] Hotkey not registered - Accessibility not granted.")
                startAccessibilityPoller()
            }

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
                    guard let self, self.overlay.currentMode == .downloading else { return }
                    self.overlay.hide()
                }
            } else {
                self.modelState = .preparing(model)
                self.overlay.showInfo("Preparing model...")
            }

            do {
                try await transcriber.preloadModel()
                self.preloadTask = nil
                self.modelState = .ready(model)
                self.overlay.hide()

                if needsDownload {
                    self.overlay.showInfo("Ready")
                    self.showReadyNotification()
                }
                print("[Voicely] Ready. Press \(hotkey.combo.displayName) to dictate.")
            } catch {
                guard !Task.isCancelled else { return }
                self.preloadTask = nil
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
        let available = WhisperModel.available()
        let recommended = WhisperModel.recommended()
        let current = transcriber.selectedModel
        let locked = modelReady  // Single source of truth: modelState == .ready

        for model in available {
            var label = "\(model.displayName) (\(model.sizeLabel))"
            if model.minRAMGB > 0 { label += ", needs \(model.minRAMGB)GB RAM" }
            if model == recommended { label += "  - Recommended" }
            let isSelected = model == current
            if isSelected && locked { label += "  [ready]" }
            let mi = NSMenuItem(title: label, action: #selector(selectModelPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = model.variant
            if isSelected && locked { mi.state = .on }
            if !isSelected && locked { mi.isEnabled = false }
            modelMenu.addItem(mi)
        }

        if locked {
            modelMenu.addItem(NSMenuItem.separator())
            let deleteItem = NSMenuItem(title: "Delete \(current.displayName) to switch models", action: #selector(deleteCurrentModel), keyEquivalent: "")
            deleteItem.target = self
            modelMenu.addItem(deleteItem)
        }

        item.submenu = modelMenu
        item.isEnabled = true  // Override autoenablesItems on parent menu
    }

    /// Single source of truth: updates ALL model UI from modelState.
    private func applyModelState() {
        guard let item = modelMenuItem else { return }
        switch modelState {
        case .noModel:
            item.title = "Model: Select to Download"
            item.action = nil; item.target = nil
            statusItem.button?.title = ""
            rebuildModelSubmenu()
        case .downloading(_, let progress):
            let pct = Int(min(100, max(0, progress * 100)))
            item.title = "Cancel Download (\(pct)%)"
            item.submenu = nil
            item.action = #selector(cancelModelDownload); item.target = self
            statusItem.button?.title = " \(pct)%"
        case .preparing:
            item.title = "Model: Preparing..."
            item.submenu = nil
            item.action = nil; item.target = nil
            statusItem.button?.title = " ..."
        case .ready(let model):
            item.title = "Model: \(model.displayName)"
            item.action = nil; item.target = nil
            statusItem.button?.title = ""
            rebuildModelSubmenu()
        case .failed:
            item.title = "Model: Select to Download"
            item.action = nil; item.target = nil
            statusItem.button?.title = ""
            rebuildModelSubmenu()
        }
    }

    // MARK: - Accessibility Poller

    /// Polls for accessibility permission every 10 seconds.
    /// When granted, auto-registers the hotkey and stops polling.
    private func startAccessibilityPoller() {
        // Show user that hotkey is waiting for accessibility
        statusItem.button?.title = " (no hotkey)"
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hotkey.retryIfNeeded() {
                    print("[Voicely] Accessibility granted. Hotkey registered.")
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                    self.statusItem.button?.title = ""
                    self.overlay.showInfo("Hotkey active")
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
            overlay.showInfo("Model loading...")
            return
        }

        switch state {
        case .idle:
            AppDelegate.debugLog("toggleDictation: idle -> recording")
            // Check mic permission before starting
            let micStatus = recorder.prepare()
            AppDelegate.debugLog("Mic status: \(micStatus.rawValue)")
            guard micStatus == .authorized else {
                overlay.showError("Mic not authorized")
                return
            }

            dictationSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
            guard recorder.startMic() else {
                overlay.showError("Mic unavailable")
                return
            }
            // Pause file-transcription queue so WhisperKit is free for dictation.
            fileQueue?.pause()
            overlay.show(mode: .recording)
            state = .recording

            // Start chunked transcription: every 30s, extract and transcribe a chunk
            chunkResults = []
            chunkTask = Task {
                // Back-off interval when the ring buffer doesn't yet hold a full
                // 30-second window. Unrelated to the chunk duration above — this
                // only governs how often we re-check the buffer while waiting.
                let chunkWaitInterval: Duration = .seconds(1)
                var chunkIndex = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    guard let rate = self.recorder.currentSampleRate else {
                        AppDelegate.debugLog("dict chunk: no sample rate, skipping iteration")
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
                    guard let buffer = Self.makePCMBuffer(samples: samples, sampleRate: rate) else {
                        AppDelegate.debugLog("dict chunk #\(idx): FAILED to build PCM buffer - chunk DROPPED")
                        continue
                    }
                    let t0 = Date()
                    // P0.1 (completeness): never drop a dictation chunk silently.
                    // A failed chunk used to vanish via the catch below — on a long
                    // dictation that lost whole 30s spans (the "tail truncation" bug).
                    // Retry transient failures once, then keep a visible marker so a
                    // lost span is never silent.
                    var dictAttempt = 0
                    while true {
                        do {
                            let text = try await self.transcriber.transcribe(audio: buffer)
                            let elapsed = Date().timeIntervalSince(t0)
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                self.chunkResults.append(text)
                                AppDelegate.debugLog("dict chunk #\(idx): OK \(trimmed.count) chars in \(String(format: "%.1f", elapsed))s")
                            } else {
                                AppDelegate.debugLog("dict chunk #\(idx): empty result in \(String(format: "%.1f", elapsed))s (not counted)")
                            }
                            break
                        } catch {
                            let elapsed = Date().timeIntervalSince(t0)
                            if case .silentAudio = error as? TranscriberError {
                                AppDelegate.debugLog("dict chunk #\(idx): silent in \(String(format: "%.1f", elapsed))s (skipped)")
                                break
                            }
                            if case .recordingTooShort = error as? TranscriberError {
                                AppDelegate.debugLog("dict chunk #\(idx): tooShort in \(String(format: "%.1f", elapsed))s (skipped)")
                                break
                            }
                            if Task.isCancelled { break }
                            dictAttempt += 1
                            if dictAttempt < 2 {
                                AppDelegate.debugLog("dict chunk #\(idx): error after \(String(format: "%.1f", elapsed))s - retry \(dictAttempt): \(error)")
                                continue
                            }
                            // Retry exhausted: keep a marker so the span is never lost silently.
                            AppDelegate.debugLog("dict chunk #\(idx): FAILED after retry - marker kept: \(error)")
                            self.chunkResults.append("[…]")
                            print("[Voicely] Chunk error (kept marker): \(error)")
                            break
                        }
                    }
                }
                AppDelegate.debugLog("dict chunk loop exited: \(chunkIndex) chunks processed, \(self.chunkResults.count) kept")
            }

            dictateMenuItem.title = "Stop Dictation  (\(hotkey.combo.displayName))"
            callMenuItem.isEnabled = false

        case .recording:
            AppDelegate.debugLog("Recording stopped, calling recorder.stop()")

            // Cancel chunk loop, keep reference to await completion
            let pendingChunkTask = chunkTask
            chunkTask = nil
            pendingChunkTask?.cancel()

            let result = recorder.stop()
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

            // Extract remaining audio (only samples since last chunk extraction)
            let audio: AVAudioPCMBuffer?
            switch result {
            case .success(let buffer):
                audio = buffer
            case .failure(let error):
                if !chunkResults.isEmpty {
                    // Buffer fully drained by chunks, no remaining samples - that's OK
                    audio = nil
                } else {
                    print("[Voicely] Recorder error: \(error.localizedDescription)")
                    overlay.showError(error.localizedDescription)
                    state = .idle
                    discardWindow = nil
                    chunkResults = []
                    fileQueue?.resume()
                    resetMenubar()
                    return
                }
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
                await pendingChunkTask?.value
                guard !Task.isCancelled else {
                    self.chunkResults = []
                    return
                }

                // Transcribe the tail in 30s windows so each call stays under the 90s
                // decode deadline — single-shot transcribe of a long tail collapses to
                // one short segment and loses most content.
                var finalText = ""
                if let audio = audio {
                    let remDuration = Double(audio.frameLength) / audio.format.sampleRate
                    AppDelegate.debugLog("dict remainder: \(audio.frameLength) frames (\(String(format: "%.1f", remDuration))s at \(audio.format.sampleRate)Hz), windowing...")
                    finalText = await AppDelegate.transcribeWindowed(
                        buffer: audio,
                        transcriber: self.transcriber,
                        logPrefix: "dict remainder"
                    )
                    AppDelegate.debugLog("dict remainder: windowed total \(finalText.count) chars")
                } else {
                    AppDelegate.debugLog("dict remainder: nil (buffer fully drained by chunks)")
                }

                guard !Task.isCancelled else {
                    self.chunkResults = []
                    return
                }

                // Concatenate chunk results + final remainder
                var allResults = self.chunkResults
                self.chunkResults = []
                if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allResults.append(finalText)
                }
                let text = allResults.joined(separator: " ")

                AppDelegate.debugLog("Transcription result: \(text.count) chars (\(allResults.count) chunks)")
                var messageShown = false
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AppDelegate.debugLog("Injecting text...")
                    let currentApp = NSWorkspace.shared.frontmostApplication?.localizedName
                    let result = self.injector.inject(text: text)
                    let saved = self.storage.saveDictation(text: text, sourceApp: currentApp ?? sourceApp)
                    if saved == nil && result == .failed {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.overlay.showError("Copied to clipboard")
                        messageShown = true
                    } else if saved == nil {
                        self.overlay.showError("Disk full")
                        messageShown = true
                    } else if result == .failed, let _ = saved {
                        self.overlay.showError("Paste failed. Saved")
                        messageShown = true
                    } else if result == .clipboardPaste, let path = saved {
                        self.overlay.showInfo("Pasted & saved")
                        messageShown = true
                    }
                    AppDelegate.debugLog("Text result=\(result), saved=\(saved?.lastPathComponent ?? "nil")")
                } else {
                    AppDelegate.debugLog("Empty transcription result - nothing to inject")
                    self.overlay.showInfo("No speech detected")
                    messageShown = true
                }
                // Only hide overlay if no message was shown (messages auto-hide after 5s)
                if !messageShown {
                    self.overlay.hide()
                }
                self.state = .idle
                self.discardWindow = nil
                self.transcriptionTask = nil
                self.fileQueue?.resume()
                self.resetMenubar()
            }

        case .transcribing:
            // #12/#74: Discard recording if hotkey pressed within 3s of entering transcribing state
            if let window = discardWindow, Date().timeIntervalSince(window) < 3.0 {
                transcriber.cancelCurrentTask()
                transcriptionTask?.cancel()
                transcriptionTask = nil
                chunkTask?.cancel()
                chunkTask = nil
                chunkResults = []
                discardWindow = nil
                overlay.hide()
                overlay.showInfo("Discarded")
                state = .idle
                fileQueue?.resume()
                resetMenubar()
                return
            }
            // #17: Silently ignore hotkey during transcription (no repeated toast)
            return
        case .callRecording:
            overlay.showInfo("Recording call...")
        case .callTranscribing:
            overlay.showInfo("Transcribing call...")
        }
    }

    // MARK: - Call Recording

    @objc func toggleCallRecording() {
        guard modelReady else {
            overlay.showInfo("Model loading...")
            return
        }

        switch state {
        case .idle:
            dictationSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
            // Disable immediately to prevent double-click starting duplicate tasks
            callMenuItem.isEnabled = false
            // Pause file-transcription queue so WhisperKit is free for call chunks.
            fileQueue?.pause()
            // #7: Store call task so it can be cancelled on quit
            // #16: [weak self] to avoid strong self capture
            callTask = Task { [weak self] in
                guard let self else { return }
                // Request Screen Recording permission on-demand
                let hasScreenRecording = await self.onboarding.requestScreenRecording()
                guard hasScreenRecording else {
                    NSLog("[Voicely] Screen Recording permission denied - cannot record calls.")
                    self.overlay.showError("Screen Recording off")
                    self.callMenuItem.isEnabled = true
                    return
                }

                do {
                    // Call-start race (#5): the first press used to surface a raw
                    // error while the second succeeded. The flaky step is the
                    // cold start of SCStream + AVAudioEngine (shareable-content
                    // query, mic device warm-up) right after permission was just
                    // granted. Make start idempotent/waiting: retry a transient
                    // failure a few times with short backoff instead of throwing
                    // on the first attempt. `alreadyRunning` is treated as
                    // success (a second press while starting is a no-op).
                    try await self.startCallRecorderWithRetry()
                    self.state = .callRecording

                    // Two-channel chunk loop: AEC on mic against system reference,
                    // transcribe both channels, accumulate segments for final merge.
                    self.callSegments = []
                    self.callElapsedSec = 0
                    self.callDelayReestimated = false
                    self.callAEC = AcousticEchoCanceller(sampleRate: 48000)
                    self.chunkTask = Task { [weak self] in
                        guard let self else { return }
                        var chunkIndex = 0
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            guard !Task.isCancelled else { break }
                            // Greedy-drain (#3): one 30 s window is the baseline, but
                            // if decode is slower than real time the unread backlog in
                            // RAM grows. Drain extra windows in the same wake-up until
                            // the backlog is back under one window, so the read offset
                            // catches the write head and RAM stops climbing.
                            var windowsThisWake = 0
                            repeat {
                                guard !Task.isCancelled else { break }
                                // Per-channel by SECONDS, not a shared sample count: mic
                                // at a native rate (44.1k/AirPods) and system at 48k must
                                // each take their own rate's worth of one 30 s window, or
                                // the you/other timelines desync and drift every chunk.
                                let pair = self.callRecorder.extractChannelChunks(seconds: 30)
                                // Nothing buffered yet (≥ minSamples): stop draining,
                                // go back to sleep.
                                if pair.mic == nil && pair.system == nil { break }
                                chunkIndex += 1
                                let idx = chunkIndex
                                let chunkOffsetSec = self.callElapsedSec
                                // Advance the timeline by the ACTUAL drained duration of
                                // this window (system channel preferred, else mic, else
                                // the nominal 30 s) so you/other stay aligned even when a
                                // window comes up short near the cap or on desync.
                                let windowSec = Self.windowDurationSec(pair: pair)
                                let t0 = Date()
                                let (micSegs, sysSegs) = await self.transcribeChunk(
                                    pair: pair,
                                    startOffsetSec: chunkOffsetSec,
                                    idx: idx
                                )
                                let elapsed = Date().timeIntervalSince(t0)
                                self.callSegments.append(contentsOf: micSegs)
                                self.callSegments.append(contentsOf: sysSegs)
                                let depth = self.callAEC?.cancellationDepthDb ?? 0
                                AppDelegate.debugLog("call chunk #\(idx): mic segs=\(micSegs.count) sys segs=\(sysSegs.count) win=\(String(format: "%.1f", windowSec))s in \(String(format: "%.1f", elapsed))s, AEC depth=\(String(format: "%.1f", depth))dB")
                                self.callElapsedSec += windowSec
                                windowsThisWake += 1
                                let backlog = self.callRecorder.pendingBacklogSeconds()
                                if backlog > 45 {
                                    AppDelegate.debugLog("call: backlog \(String(format: "%.0f", backlog))s > 45s - draining extra window (\(windowsThisWake) this wake)")
                                    continue
                                }
                                break
                            } while !Task.isCancelled
                        }
                        AppDelegate.debugLog("call chunk loop exited: \(chunkIndex) chunks processed, \(self.callSegments.count) segments")
                    }

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
                    self.overlay.showError("Call record failed")
                    self.callMenuItem.isEnabled = true
                }
            }

        case .callRecording:
            // Cancel chunk loop, keep reference to await completion
            let pendingCallChunkTask = chunkTask
            chunkTask = nil
            pendingCallChunkTask?.cancel()

            state = .callTranscribing
            overlay.show(mode: .loading)
            callMenuItem.title = "Transcribing call..."
            callMenuItem.isEnabled = false
            dictateMenuItem.isEnabled = false

            let sourceApp = dictationSourceApp
            let callRecorder = self.callRecorder

            callTask = Task { [weak self] in
                guard let self else { return }
                await pendingCallChunkTask?.value

                // Tail flush BEFORE stop() so we can still read offsets.
                // Windowed (#4): the unread tail can exceed one 30 s window when
                // decode lagged capture (greedy-drain stops at 30 s remaining) or
                // a long final segment built up. Feeding the whole remainder as a
                // single chunk made WhisperKit process only its first window and
                // silently drop the rest (the "lost last ~1/4" bug). Drain full
                // 30 s windows first, then the sub-window remainder, so the entire
                // tail of BOTH channels is covered.
                var tailIdx = -1
                while !Task.isCancelled {
                    let backlog = callRecorder.pendingBacklogSeconds()
                    if backlog <= 30 { break }
                    let win = callRecorder.extractChannelChunks(seconds: 30)
                    if win.mic == nil && win.system == nil { break }
                    let winSec = Self.windowDurationSec(pair: win)
                    let (mSegs, sSegs) = await self.transcribeChunk(
                        pair: win, startOffsetSec: self.callElapsedSec, idx: tailIdx)
                    self.callSegments.append(contentsOf: mSegs)
                    self.callSegments.append(contentsOf: sSegs)
                    AppDelegate.debugLog("call tail win \(tailIdx): mic=\(mSegs.count) sys=\(sSegs.count) win=\(String(format: "%.1f", winSec))s")
                    self.callElapsedSec += winSec
                    tailIdx -= 1
                }
                // Final sub-30 s remainder of both channels.
                let tail = callRecorder.extractRemainingChannels()
                let audio = await callRecorder.stop()

                guard !Task.isCancelled else {
                    self.clearCallState()
                    self.finishCallRecording(hideOverlay: false)
                    return
                }

                if audio == nil && self.callSegments.isEmpty {
                    NSLog("[Voicely] No call audio captured")
                    self.overlay.showError("No audio captured")
                    self.clearCallState()
                    self.finishCallRecording(hideOverlay: false)
                    return
                }

                // Transcribe the tail, offsetting segments past all the chunks.
                let tailOffsetSec = self.callElapsedSec
                let (tailMicSegs, tailSysSegs) = await self.transcribeChunk(
                    pair: tail,
                    startOffsetSec: tailOffsetSec,
                    idx: tailIdx
                )
                self.callSegments.append(contentsOf: tailMicSegs)
                self.callSegments.append(contentsOf: tailSysSegs)

                guard !Task.isCancelled else {
                    self.clearCallState()
                    self.finishCallRecording(hideOverlay: false)
                    return
                }

                // N2b: split you/other once. `.you` is always the local user and
                // is NEVER diarized. The collapsed system (other) channel — a whole
                // conference in one stream — is what we separate into "Speaker N".
                let youSegs = self.callSegments.filter { $0.speaker == .you }
                let otherSegs = self.callSegments.filter { $0.speaker == .other }

                // Capture the diarization source BEFORE saveCall: the full-channel
                // system spill is written incrementally during the call and closed
                // by stop() above, but saveCall re-encodes system.wav from the RAM
                // copy and would clobber it. Prefer the on-disk spill to avoid
                // re-resampling the RAM copy (both stop at the same RAM cap, so the
                // spill is not "more complete" — just already on disk in the right
                // place); fall back to the RAM system buffer when spill was disabled
                // (disk-full) or never opened.
                let spillURL = callRecorder.systemWavURL
                let ramSystem = audio?.system
                if let spillURL {
                    AppDelegate.debugLog("call system spill available for diarization: \(spillURL.path)")
                }

                // One GLOBAL pass over the WHOLE system channel (never per-chunk —
                // per-chunk would renumber speakers each window). Any error/timeout
                // here MUST NOT lose the transcript: on failure we fall back to the
                // undiarized segments (remote turns render as "Other").
                let diarizedOther = await self.diarizeOtherSegments(
                    otherSegs,
                    spillURL: spillURL,
                    ramSystem: ramSystem
                )

                let merged = CallTranscriptMerger.merge(
                    mic: youSegs,
                    system: diarizedOther
                )

                let callPath = self.storage.saveCall(
                    mic: audio?.mic,
                    system: audio?.system,
                    segments: merged,
                    startTime: audio?.startTime ?? Date(),
                    sourceApp: sourceApp
                )

                if callPath != nil {
                    self.overlay.showInfo("Call saved")
                    // NOTE: do NOT delete `spillURL` here. The spill lives at the
                    // SAME path as the call's persisted system.wav
                    // (~/Documents/Voicely/calls/<id>/system.wav); saveCall just
                    // re-encoded the RAM copy over it. Removing it would delete the
                    // user's saved call audio. The spill was already consumed for
                    // diarization above, before saveCall ran.
                } else {
                    self.overlay.showError("Disk full")
                }
                let speakerCount = CallTranscriptMerger.detectedSpeakerIDs(in: merged).count
                NSLog("[Voicely] Call transcribed: %d segments, %d remote speakers", merged.count, speakerCount)

                self.clearCallState()
                self.finishCallRecording(hideOverlay: false)
            }

        default:
            break
        }
    }

    /// Start the call recorder, tolerating the cold-start race (#5). The first
    /// press after permission grant can hit a transient failure (SCShareable
    /// content not ready, mic device still warming) that the second press
    /// wouldn't — so retry a few times with short backoff. `alreadyRunning`
    /// means a start is already in flight: treat it as success, not an error.
    /// Throws only if every attempt fails, so the caller's catch still fires
    /// for a genuinely broken start (no audio device, permission revoked mid-way).
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
                // A start is already underway (e.g. double press). No-op success.
                AppDelegate.debugLog("call start: already running - treating as success")
                return
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

    /// Run one chunk through AEC (when both channels present) and transcribe
    /// mic + system sequentially. Mic is resampled to 48 kHz before AEC.
    /// Returns segments for each side; either list may be empty.
    ///
    /// Serialised rather than parallel because `WhisperKitEngine.trySetTranscribing`
    /// is a hard mutex (Finding 0.2 in the plan).
    private func transcribeChunk(
        pair: CallRecorder.ChannelChunks,
        startOffsetSec: Double,
        idx: Int
    ) async -> (mic: [DialogueSegment], system: [DialogueSegment]) {
        let micRateIn = pair.mic?.format.sampleRate ?? 48000
        let sysRateIn = pair.system?.format.sampleRate ?? 48000

        // Prepare reference / cleaned mic sample arrays at 48 kHz.
        var micSamples48k: [Float] = []
        var systemSamplesNative: [Float] = []

        if let sys = pair.system {
            systemSamplesNative = Self.samplesFromBuffer(sys)
        }

        if let mic = pair.mic {
            let raw = Self.samplesFromBuffer(mic)
            let mic48: [Float]
            if abs(micRateIn - 48000) > 1 {
                mic48 = (try? Self.resampleTo48k(raw, fromRate: micRateIn)) ?? raw
            } else {
                mic48 = raw
            }

            if let aec = callAEC, !systemSamplesNative.isEmpty {
                // Build a 48 kHz reference. If the system stream is at a
                // different rate (it usually isn't - SCStream is 48 k by config),
                // resample it. No need to resample native-48k.
                let sys48: [Float]
                if abs(sysRateIn - 48000) > 1 {
                    sys48 = (try? Self.resampleTo48k(systemSamplesNative, fromRate: sysRateIn)) ?? systemSamplesNative
                } else {
                    sys48 = systemSamplesNative
                }

                // First chunk only: estimate delay on the leading 1 s of both
                // streams. Later chunks keep the locked delay. Finding 0.3:
                // if drift is a real problem, we'd re-estimate periodically;
                // for now, one lock is enough.
                if !callDelayReestimated {
                    let probeLen = min(mic48.count, sys48.count, 48000)
                    if probeLen > 48000 / 2 {  // need at least 0.5 s
                        aec.estimateDelayMs(
                            mic: Array(mic48.prefix(probeLen)),
                            reference: Array(sys48.prefix(probeLen))
                        )
                        callDelayReestimated = true
                        AppDelegate.debugLog("call chunk #\(idx): AEC delay locked at \(String(format: "%.1f", aec.estimatedDelayMs))ms")
                    }
                }

                let n = min(mic48.count, sys48.count)
                // P0.5 (completeness): flag channel desync. We trim both channels
                // to the shorter one for AEC; a large gap means mic/system drifted
                // and the trimmed tail of the longer channel is dropped silently.
                let desync = abs(mic48.count - sys48.count)
                if desync > 4800 {  // >0.1s at 48k
                    AppDelegate.debugLog("call chunk #\(idx): channel desync \(String(format: "%.2f", Double(desync) / 48000.0))s (mic=\(mic48.count) sys=\(sys48.count)) - trimming to \(n)")
                }
                micSamples48k = aec.process(
                    mic: Array(mic48.prefix(n)),
                    reference: Array(sys48.prefix(n))
                )
            } else {
                micSamples48k = mic48
            }
        }

        // P0.2/P0.3/P0.4 (completeness): a failed channel chunk (timeout,
        // whisperKitFailed, …) used to be swallowed into an empty array, leaving
        // a silent 30s hole in the call timeline. Now: retry once, then keep a
        // gap-marker segment so the span is visible, not lost.
        var micSegs: [DialogueSegment] = []
        var sysSegs: [DialogueSegment] = []
        if !micSamples48k.isEmpty {
            micSegs = await self.transcribeCallChannel(
                samples: micSamples48k, sampleRate: 48000,
                speaker: .you, startOffsetSec: startOffsetSec, idx: idx)
        }
        if !systemSamplesNative.isEmpty {
            sysSegs = await self.transcribeCallChannel(
                samples: systemSamplesNative, sampleRate: sysRateIn,
                speaker: .other, startOffsetSec: startOffsetSec, idx: idx)
        }
        return (micSegs, sysSegs)
    }

    /// Transcribe one call channel with a single retry. `transcribeChannel`
    /// already returns `[]` for silent / too-short audio (benign). For real
    /// failures (timeout etc.) we retry once, then return a gap-marker segment
    /// spanning the chunk so the span is never silently dropped from the
    /// timeline (completeness axiom). Returns `[]` only on cancellation.
    private func transcribeCallChannel(
        samples: [Float],
        sampleRate: Double,
        speaker: CallSpeaker,
        startOffsetSec: Double,
        idx: Int
    ) async -> [DialogueSegment] {
        var attempt = 0
        while true {
            do {
                return try await self.transcriber.transcribeChannel(
                    samples: samples,
                    sampleRate: sampleRate,
                    speaker: speaker,
                    startOffsetSec: startOffsetSec
                )
            } catch {
                if Task.isCancelled { return [] }
                attempt += 1
                if attempt < 2 {
                    AppDelegate.debugLog("call chunk #\(idx): \(speaker.rawValue) error - retry \(attempt): \(error)")
                    continue
                }
                let durationSec = Double(samples.count) / sampleRate
                AppDelegate.debugLog("call chunk #\(idx): \(speaker.rawValue) FAILED after retry - gap marker (\(String(format: "%.1f", durationSec))s): \(error)")
                return [DialogueSegment(
                    speaker: speaker,
                    start: startOffsetSec,
                    end: startOffsetSec + durationSec,
                    text: "[…]",
                    language: nil
                )]
            }
        }
    }

    /// N2b: diarize the collapsed system (other) channel ONE-PASS over the whole
    /// channel and stamp each `.other` segment with its remote-speaker index.
    ///
    /// Source preference (the spill is read BEFORE saveCall clobbers system.wav):
    ///   1. `spillURL` — the full-channel on-disk system.wav (most complete).
    ///   2. `ramSystem` — the RAM system buffer, when spill was disabled
    ///      (disk-full) or never opened.
    /// The `.other` segment timeline and the system channel share one origin
    /// (recording start), so diarization turns (seconds from file/buffer start)
    /// align with the segments directly — `assignSpeakers` needs no offset.
    ///
    /// COMPLETENESS: this never throws. ANY failure (no source, model download,
    /// timeout, decode) returns the input segments unchanged — remote turns then
    /// render as "Other" and the transcript is saved exactly as before. The
    /// transcript is NEVER lost to diarization.
    private func diarizeOtherSegments(
        _ segments: [DialogueSegment],
        spillURL: URL?,
        ramSystem: AVAudioPCMBuffer?
    ) async -> [DialogueSegment] {
        guard !segments.isEmpty else { return segments }

        // Async status while the (potentially slow, model-loading) pass runs.
        // main-actor isolated; does not block the diarization await below.
        self.overlay.showInfo("Identifying speakers...")

        let turns: [SpeakerTurn]
        do {
            if let spillURL,
               FileManager.default.fileExists(atPath: spillURL.path) {
                turns = try await diarizer.diarize(wavURL: spillURL)
            } else if let ramSystem,
                      let samples16k = Self.systemSamples16k(from: ramSystem),
                      !samples16k.isEmpty {
                turns = try await diarizer.diarize(
                    samples: samples16k,
                    sampleRate: DiarizationService.requiredSampleRate
                )
            } else {
                AppDelegate.debugLog("call diarization: no system source (spill+RAM both unavailable) - keeping 'Other'")
                return segments
            }
        } catch {
            AppDelegate.debugLog("call diarization failed (\(error)) - keeping 'Other', transcript intact")
            return segments
        }

        guard !turns.isEmpty else {
            AppDelegate.debugLog("call diarization: 0 turns - keeping 'Other'")
            return segments
        }

        // Stamp ONLY the other-channel segments. `.you` never reaches here.
        let stamped = DiarizationService.assignSpeakers(to: segments, turns: turns)
        let speakerCount = CallTranscriptMerger.detectedSpeakerIDs(in: stamped).count
        AppDelegate.debugLog("call diarization: \(turns.count) turns -> \(speakerCount) remote speakers stamped onto \(stamped.count) segments")
        return stamped
    }

    /// Resample a system PCM buffer to 16 kHz mono Float32 for diarization (the
    /// RAM fallback when no on-disk spill exists). Mirrors `readMono16k`'s output
    /// contract. Returns nil if the buffer can't be converted.
    private static func systemSamples16k(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let rate = buffer.format.sampleRate
        guard rate > 0, buffer.frameLength > 0 else { return nil }
        let raw = samplesFromBuffer(buffer)
        guard !raw.isEmpty else { return nil }
        if abs(rate - DiarizationService.requiredSampleRate) < 1 {
            return raw
        }
        return resampleTo16kMono(raw, fromRate: rate)
    }

    /// Resample mono Float32 samples to 16 kHz for diarization (RAM fallback).
    /// Mirrors `resampleTo48k`. Returns nil on converter failure so the caller
    /// treats it as "no diarization source" and keeps "Other".
    private static func resampleTo16kMono(_ samples: [Float], fromRate: Double) -> [Float]? {
        let target = DiarizationService.requiredSampleRate
        if abs(fromRate - target) < 1 || samples.isEmpty { return samples }
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: fromRate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: target, channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: src,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        if let p = srcBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    p.initialize(from: base, count: samples.count)
                }
            }
        }
        guard let conv = AVAudioConverter(from: src, to: dst) else { return nil }
        let ratio = target / fromRate
        let outCap = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCap) else { return nil }
        var err: NSError?
        var consumed = false
        conv.convert(to: dstBuf, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return srcBuf
        }
        guard err == nil, let data = dstBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(dstBuf.frameLength)))
    }

    private func clearCallState() {
        callSegments = []
        callAEC = nil
        callElapsedSec = 0
        callDelayReestimated = false
    }

    private static func samplesFromBuffer(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Actual duration of a drained chunk window, in seconds. System channel is
    /// the diarization reference timeline, so prefer its duration; fall back to
    /// mic, then to the nominal 30 s window. Keeps `callElapsedSec` honest when a
    /// window comes up short (near the RAM cap, on desync, or while draining a
    /// partial tail) so you/other segments don't drift apart.
    private static func windowDurationSec(pair: CallRecorder.ChannelChunks) -> Double {
        if let sys = pair.system, sys.format.sampleRate > 0 {
            return Double(sys.frameLength) / sys.format.sampleRate
        }
        if let mic = pair.mic, mic.format.sampleRate > 0 {
            return Double(mic.frameLength) / mic.format.sampleRate
        }
        return 30
    }

    private static func resampleTo48k(_ samples: [Float], fromRate: Double) throws -> [Float] {
        if abs(fromRate - 48000) < 1 || samples.isEmpty { return samples }
        guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: fromRate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 48000, channels: 1, interleaved: false),
              let srcBuf = AVAudioPCMBuffer(pcmFormat: src,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        if let p = srcBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    p.initialize(from: base, count: samples.count)
                }
            }
        }
        guard let conv = AVAudioConverter(from: src, to: dst) else { return samples }
        let ratio = 48000.0 / fromRate
        let outCap = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCap) else { return samples }
        var err: NSError?
        var consumed = false
        conv.convert(to: dstBuf, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return srcBuf
        }
        guard err == nil, let data = dstBuf.floatChannelData?[0] else { return samples }
        return Array(UnsafeBufferPointer(start: data, count: Int(dstBuf.frameLength)))
    }

    private func finishCallRecording(hideOverlay: Bool = true) {
        if hideOverlay { overlay.hide() }
        state = .idle
        fileQueue?.resume()
        resetMenubar()
        callMenuItem.title = "Record Call"
        dictateMenuItem.isEnabled = true
    }

    // MARK: - Menu Actions

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
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "voicelyLanguage")
        transcriber.translateToEnglish = (value == "translate_en")

        // Update menu
        let title = value == "translate_en" ? "Translate to English" : "Auto"
        languageMenuItem?.title = "Language: \(title)"
        if let submenu = languageMenuItem?.submenu {
            for item in submenu.items {
                item.state = (item.representedObject as? String) == value ? .on : .off
            }
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

    func applicationWillTerminate(_ notification: Notification) {
        // #3: Cancel preload task to prevent corrupted partial downloads
        preloadTask?.cancel()
        preloadTask = nil

        // #12: Cancel any in-progress transcription
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // #7: Cancel any in-progress call task
        callTask?.cancel()
        callTask = nil

        chunkTask?.cancel()
        chunkTask = nil

        // Stop any in-flight file transcription work so pending writes
        // don't leave half-written transcripts behind.
        fileQueue?.cancelAll()
        fileQueue = nil

        _ = recorder.stop()

        // #24/#36/#47: Warn if quitting during call recording (forceStop releases resources without saving)
        if state == .callRecording || state == .callTranscribing {
            NSLog("[Voicely] WARNING: Quit during active call state=%@. Partial audio will be lost.", "\(state)")
            callRecorder.forceStop()
        }

        // Restore clipboard if paste was pending
        injector.restoreClipboardNow()

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

        var captured: HotkeyCombo?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Let unmodified Escape pass through so user can cancel the dialog
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
                return event
            }
            let flags = HotkeyCombo.cgEventFlags(from: event.modifierFlags)
            captured = HotkeyCombo(keyCode: Int64(event.keyCode), modifiers: flags)
            field.stringValue = captured!.displayName
            return nil
        }

        alert.addButton(withTitle: "Save")
        let response = alert.runModal()

        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }

        if response == .alertSecondButtonReturn, let combo = captured {
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
        guard let variant = sender.representedObject as? String,
              let model = WhisperModel.all.first(where: { $0.variant == variant })
        else { return }
        // Skip if already selected and active
        if model == transcriber.selectedModel && (modelReady || preloadTask != nil) { return }

        // Confirm download
        let alert = NSAlert()
        alert.messageText = "Download \(model.displayName)?"
        alert.informativeText = "This will download \(model.sizeLabel) to your Mac."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Any existing file queue holds a reference to the old engine —
        // drop it so the next file transcription picks up the new model.
        fileQueue?.cancelAll()
        fileQueue = nil

        transcriber.selectModel(model)
        modelState = .downloading(model, 0)
        overlay.show(mode: .downloading)
        overlay.updateProgress(0, status: "Voice model...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.overlay.currentMode == .downloading else { return }
            self.overlay.hide()
        }

        preloadTask = Task {
            do {
                try await transcriber.preloadModel()
                self.preloadTask = nil
                self.modelState = .ready(model)
                self.overlay.hide()
                self.showReadyNotification()
            } catch {
                guard !Task.isCancelled else { return }
                self.preloadTask = nil
                self.overlay.hide()
                let msg = Self.classifyModelError(error)
                self.overlay.showError(msg)
                self.modelState = .failed(model, msg)
            }
        }
    }

    // Delete current model from disk, fall back to another or show selection
    @objc func deleteCurrentModel() {
        guard state == .idle else {
            overlay.showInfo("Busy, wait...")
            return
        }

        let model = transcriber.selectedModel
        let alert = NSAlert()
        alert.messageText = "Delete \(model.displayName)?"
        alert.informativeText = "This will free \(model.sizeLabel) of disk space."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        preloadTask?.cancel()
        preloadTask = nil

        // Delete model directory
        try? FileManager.default.removeItem(at: model.modelDirectory)
        print("[Voicely] Deleted model: \(model.displayName)")

        transcriber.cancelAndReset()
        modelState = .noModel
        overlay.showInfo("Select a model")
    }

    // #25: Re-trigger onboarding setup wizard
    @objc func runSetupWizard() {
        guard state == .idle else {
            overlay.showInfo("Busy, wait...")
            return
        }
        Task {
            let result = await onboarding.runIfNeeded()
            if result.accessibilityGranted {
                _ = hotkey.retryIfNeeded()
                accessibilityTimer?.invalidate()
                accessibilityTimer = nil
            }
            // Restart model preload if permissions granted but model not ready
            if result.microphoneGranted && !modelState.isReady && preloadTask == nil {
                let model = transcriber.selectedModel
                overlay.showInfo("Retrying model...")
                modelState = .preparing(model)
                preloadTask = Task {
                    do {
                        try await transcriber.preloadModel()
                        self.preloadTask = nil
                        self.modelState = .ready(model)
                        self.overlay.hide()
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.preloadTask = nil
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
        preloadTask?.cancel()
        preloadTask = nil
        transcriber.cancelAndCleanup()
        overlay.hide()
        modelState = .noModel
        overlay.showInfo("Cancelled")
    }

    /// Build a mono AVAudioPCMBuffer from raw Float32 samples.
    /// Transcribe a long audio buffer by slicing it into 30-second windows and running
    /// each through `transcriber.transcribe` separately. Used for the final remainder
    /// in dictation/call — a single long-buffer transcribe collides with the 90s decode
    /// deadline and Whisper returns just one short segment, losing most content.
    /// Returns concatenated text across successful windows.
    private static func transcribeWindowed(
        buffer: AVAudioPCMBuffer,
        transcriber: Transcriber,
        logPrefix: String
    ) async -> String {
        let rate = buffer.format.sampleRate
        let total = Int(buffer.frameLength)
        guard rate > 0, total > 0, let channelData = buffer.floatChannelData?[0] else {
            return ""
        }
        let windowSamples = Int(rate * 30)
        var texts: [String] = []
        var offset = 0
        var idx = 0
        while offset < total {
            let end = min(offset + windowSamples, total)
            let count = end - offset
            idx += 1
            let durationSec = Double(count) / rate
            let slice = Array(UnsafeBufferPointer(start: channelData.advanced(by: offset), count: count))
            guard let sliceBuffer = makePCMBuffer(samples: slice, sampleRate: rate) else {
                AppDelegate.debugLog("\(logPrefix) win #\(idx): failed to build slice (count=\(count))")
                offset = end
                continue
            }
            AppDelegate.debugLog("\(logPrefix) win #\(idx): \(count) samples (\(String(format: "%.1f", durationSec))s), transcribing...")
            // P0.4 (completeness): retry a window once before giving up, and keep
            // a marker if it still fails, so the tail of a long dictation/call is
            // never silently truncated.
            var winAttempt = 0
            while true {
                let t0 = Date()
                do {
                    let text = try await transcriber.transcribe(audio: sliceBuffer)
                    let elapsed = Date().timeIntervalSince(t0)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        texts.append(text)
                        AppDelegate.debugLog("\(logPrefix) win #\(idx): OK \(trimmed.count) chars in \(String(format: "%.1f", elapsed))s")
                    } else {
                        AppDelegate.debugLog("\(logPrefix) win #\(idx): empty in \(String(format: "%.1f", elapsed))s")
                    }
                    break
                } catch {
                    let elapsed = Date().timeIntervalSince(t0)
                    if case .silentAudio = error as? TranscriberError {
                        AppDelegate.debugLog("\(logPrefix) win #\(idx): silent in \(String(format: "%.1f", elapsed))s")
                        break
                    }
                    if case .recordingTooShort = error as? TranscriberError {
                        AppDelegate.debugLog("\(logPrefix) win #\(idx): tooShort in \(String(format: "%.1f", elapsed))s")
                        break
                    }
                    if Task.isCancelled { break }
                    winAttempt += 1
                    if winAttempt < 2 {
                        AppDelegate.debugLog("\(logPrefix) win #\(idx): error after \(String(format: "%.1f", elapsed))s - retry \(winAttempt): \(error)")
                        continue
                    }
                    AppDelegate.debugLog("\(logPrefix) win #\(idx): FAILED after retry - marker kept: \(error)")
                    texts.append("[…]")
                    break
                }
            }
            offset = end
        }
        return texts.joined(separator: " ")
    }

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
    static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let icon = NSImage(size: size, flipped: false) { rect in
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
        icon.isTemplate = true
        return icon
    }

    static func debugLog(_ message: String) {
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
        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
        }
        dictateMenuItem.title = "Dictate  (\(hotkey.combo.displayName))"
        dictateMenuItem.isEnabled = true
        callMenuItem.title = "Record Call"
        callMenuItem.isEnabled = true
    }

    // MARK: - File Transcription

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
        guard let engine = transcriber.currentEngine as? any SampleTranscribing else {
            overlay.showError("Model not ready")
            return
        }
        // No cap on queue size — files are processed serially, so an arbitrary
        // number can be enqueued without raising peak memory.
        if fileQueue == nil {
            let centralRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Voicely/files")
            let queue = FileTranscriptionQueue(
                transcriber: engine,
                modelName: transcriber.selectedModel.displayName,
                centralRoot: centralRoot,
                diarizer: diarizer
            )
            queue.onStateChange = { [weak self] state, jobs in
                self?.handleFileQueueState(state, jobs: jobs)
            }
            fileQueue = queue
        }
        fileQueue?.enqueue(urls, options: options)
    }

    private func handleFileQueueState(
        _ state: FileTranscriptionQueue.QueueState,
        jobs: [FileTranscriptionQueue.Job]
    ) {
        updateMenubarTitleForFileQueue(state: state, jobs: jobs)
        switch state {
        case .idle:
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
        case .processing(let idx, let total):
            guard idx < jobs.count else { return }
            let job = jobs[idx]
            let name = job.sourceURL.lastPathComponent
            let progress: Double
            if case .transcribing(let p) = job.status { progress = p } else { progress = 0 }
            let title = "Transcribing \"\(name)\" (\(idx + 1)/\(total))"
            // Chunk progress ticks hit this path repeatedly; use the in-place
            // updater to avoid triggering the overlay's 250 ms fade-in on
            // every chunk. Fall through to full show() on the first entry or
            // when coming back from a non-fileQueue mode (e.g. after pause).
            if case .fileQueue = overlay.currentMode {
                overlay.updateFileQueueProgress(title: title, progress: progress)
            } else {
                overlay.show(mode: .fileQueue(title: title, progress: progress))
            }
        case .paused(let idx, let total):
            guard idx < jobs.count else { return }
            let job = jobs[idx]
            let name = job.sourceURL.lastPathComponent
            let title = "\"\(name)\" (\(idx + 1)/\(total))"
            overlay.show(mode: .fileQueuePaused(title: title))
        }
    }

    private func updateMenubarTitleForFileQueue(
        state: FileTranscriptionQueue.QueueState,
        jobs: [FileTranscriptionQueue.Job]
    ) {
        switch state {
        case .idle:
            // Hand control back to the model-state title.
            applyModelState()
        case .processing(let idx, let total):
            var pct = 0
            if idx < jobs.count,
               case .transcribing(let p) = jobs[idx].status {
                pct = Int((p * 100).rounded())
            }
            statusItem.button?.title = " \(idx + 1)/\(total) \(pct)%"
        case .paused(let idx, let total):
            statusItem.button?.title = " ⏸ \(idx + 1)/\(total)"
        }
    }

    private func showReadyNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Voicely is ready"
            content.body = "Press \(self.hotkey.combo.displayName) to start dictating"
            let request = UNNotificationRequest(identifier: "ready", content: content, trigger: nil)
            center.add(request)
        }
    }

    /// Soft notification when the on-disk call spill is paused for low disk.
    /// The call keeps recording from RAM; only the diarization file stops.
    private func showDiskSpillNotification(freeMB: UInt64) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Low disk space"
            content.body = "Call keeps recording, but per-speaker audio isn't being saved to disk (\(freeMB) MB free). Free up space to re-enable it."
            let request = UNNotificationRequest(identifier: "diskSpill", content: content, trigger: nil)
            center.add(request)
        }
    }
}
