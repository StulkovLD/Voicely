import AppKit
import QuartzCore

enum OverlayMode: Sendable, Equatable {
    case recording
    case loading
    case downloading
    case error
    case fileQueue(title: String, progress: Double)
    case fileQueuePaused(title: String)
}

struct OverlayAccessibilityAnnouncement: Sendable, Equatable {
    let label: String
    let message: String
    let priority: Int
}

struct OverlayPlacementRequest {
    let screens: [CGRect]
    let cursor: CGPoint?
    let mainScreen: CGRect?
    let panelSize: CGSize
    let screenMargin: CGFloat
    let bottomOffset: CGFloat

    init(
        screens: [CGRect],
        cursor: CGPoint?,
        mainScreen: CGRect?,
        panelSize: CGSize,
        screenMargin: CGFloat = 24,
        bottomOffset: CGFloat = 140
    ) {
        self.screens = screens
        self.cursor = cursor
        self.mainScreen = mainScreen
        self.panelSize = panelSize
        self.screenMargin = screenMargin
        self.bottomOffset = bottomOffset
    }
}

struct OverlayPlacement: Equatable {
    let screenFrame: CGRect
    let frame: CGRect
}

enum OverlayPlacementResolver {
    /// The pill is centred on the screen the user is on, and attaches to
    /// nothing — no focused element, no window, no AX call.
    ///
    /// Attaching it to the focused element is what forced the overlay to ask
    /// Accessibility where the caret was, which is what made it clamp the AX
    /// messaging timeout process-wide, which is what broke every paste in the
    /// product. This resolver reads only screen geometry and the cursor, so
    /// none of that can come back.
    ///
    /// Active screen = the one under the cursor: it is a process-local,
    /// non-blocking read that needs no permission and cannot time out, and with
    /// "Displays have separate Spaces" it is also macOS's own notion of the
    /// active display. `NSScreen.main` follows key-window focus, which is
    /// unreliable for a nonactivating panel in an LSUIElement app — fallback
    /// only.
    static func resolve(_ request: OverlayPlacementRequest) -> OverlayPlacement? {
        guard !request.screens.isEmpty else { return nil }
        guard let screenFrame = activeScreen(in: request) else { return nil }

        let originX = screenFrame.minX + max((screenFrame.width - request.panelSize.width) / 2, 0)
        let originY = clampedOrigin(
            ideal: screenFrame.minY + request.bottomOffset,
            minimum: screenFrame.minY + request.screenMargin,
            maximum: screenFrame.maxY - request.screenMargin - request.panelSize.height,
            fallback: screenFrame.minY + max((screenFrame.height - request.panelSize.height) / 2, 0)
        )

        return OverlayPlacement(
            screenFrame: screenFrame,
            frame: CGRect(origin: CGPoint(x: originX, y: originY), size: request.panelSize)
        )
    }

    private static func activeScreen(in request: OverlayPlacementRequest) -> CGRect? {
        if let cursor = request.cursor,
           cursor.x.isFinite,
           cursor.y.isFinite,
           let hit = request.screens.first(where: { $0.contains(cursor) }) {
            return hit
        }
        if let mainScreen = request.mainScreen,
           let matching = request.screens.first(where: { $0 == mainScreen }) {
            return matching
        }
        return request.screens.sorted(by: stableScreenOrder).first
    }

    private static func stableScreenOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        return lhs.height < rhs.height
    }

    private static func clampedOrigin(
        ideal: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard minimum <= maximum else { return fallback }
        return min(max(ideal, minimum), maximum)
    }
}

@MainActor
final class Overlay {
    // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive; macOS 26
    // raises NSInternalInconsistencyException when both are set, which crashed
    // the overlay panel on first creation and froze launch at "Preparing".
    // The pill must appear on whatever space the user is on, including
    // fullscreen apps, so keep canJoinAllSpaces + fullScreenAuxiliary.
    // `.fullScreenAuxiliary` only offers the pill to *our own* fullscreen window
    // (NSWindow.h: "can be shown with the fullscreen window"). Following ANOTHER
    // app into its fullscreen Space — a fullscreen editor, say — is what
    // `.canJoinAllApplications` is for: "able to join all applications, allowing
    // it to join other apps' sets and full screen spaces… commonly used for
    // floating windows and system overlays" (macOS 13+; we target 14).
    //
    // It sits in the Primary/Auxiliary/CanJoinAllApplications exclusivity group,
    // NOT the canJoinAllSpaces/moveToActiveSpace one — so it cannot resurrect the
    // illegal pair that crashed panel creation and froze launch at "Preparing".
    nonisolated static let panelCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .canJoinAllApplications,
    ]

    private var panel: NSPanel?
    private var bars: [CALayer] = []
    private var timer: DispatchSourceTimer?
    /// Nil once hidden. Every watchdog in the app asks "is the panel still in
    /// mode X?" via `currentMode`; a mode that outlived `hide()` answered yes
    /// for a panel already on its way out, which let a stale check re-show it
    /// mid-fade and strand it on screen.
    private var mode: OverlayMode?
    private var smoothLevels: [Float] = Array(repeating: 0, count: 32)
    private var tick: Int = 0
    private var progressTrackLayer: CALayer?
    private var progressLayer: CALayer?
    private var progressTextLayer: CATextLayer?
    private var errorTextLayer: CATextLayer?
    private var generation: Int = 0
    var isVisible: Bool { panel?.isVisible ?? false }
    var currentMode: OverlayMode? { mode }
    private var timerTextLayer: CATextLayer?
    private var recordingStartTime: Date?
    private var segmentProgressLayer: CATextLayer?
    private var pendingHide: DispatchWorkItem?
    /// Brief warning shown via timer text during recording (e.g. "10s remaining")
    private var recordingWarningExpiry: Date?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activeSpaceObserver: NSObjectProtocol?

    /// Screen the pill was last placed on. Guards the 5 Hz reposition check so
    /// setFrame only runs when the user actually moved to another display —
    /// within one screen the pill never moves.
    private var placedScreenFrame: CGRect?

    // Audio level updated from background audio thread - nonisolated access via lock
    private let levelLock = NSLock()
    nonisolated(unsafe) private var _currentLevel: Float = 0
    nonisolated var currentLevel: Float {
        get { levelLock.withLock { _currentLevel } }
        set { levelLock.withLock { _currentLevel = newValue } }
    }

    private let barCount = 32
    /// Width of the pill in its resting modes. Message toasts may stretch the
    /// pill (`messagePillWidth`) so the text actually fits; every `show(mode:)`
    /// returns to this base.
    private let basePillWidth: CGFloat = 160
    private var pillWidth: CGFloat = 160
    private let pillHeight: CGFloat = 56
    private let pillRadius: CGFloat = 28
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1.2
    private let barMinHeight: CGFloat = 6
    private let barMaxHeight: CGFloat = 40

    nonisolated static func accessibilityAnnouncement(
        message: String,
        isError: Bool
    ) -> OverlayAccessibilityAnnouncement {
        OverlayAccessibilityAnnouncement(
            label: isError ? "Voicely error" : "Voicely status",
            message: message,
            priority: isError
                ? NSAccessibilityPriorityLevel.high.rawValue
                : NSAccessibilityPriorityLevel.medium.rawValue
        )
    }

    init() {
        // Task { @MainActor } instead of MainActor.assumeIsolated: the
        // notification block runs outside any Swift concurrency context, and
        // the runtime's executor check inside assumeIsolated dereferences
        // garbage there (SIGSEGV on macOS 26). Enqueueing a real task hops to
        // the main actor without that check.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionToTargetSurface()
            }
        }
        // Must be NSWorkspace's own centre — this notification is not posted to
        // NotificationCenter.default.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionToTargetSurface()
            }
        }
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    /// Move the pill to the screen the user is on, if that is not where it
    /// already is.
    ///
    /// Cheap enough to call at 5 Hz from the animation tick, which is the only
    /// trigger that catches the case the owner actually hit: walking the cursor
    /// to another display posts no notification at all.
    private func repositionToTargetSurface() {
        guard let p = panel, p.isVisible else { return }
        guard let placement = resolvePlacement() else { return }
        guard placement.screenFrame != placedScreenFrame else { return }
        placedScreenFrame = placement.screenFrame
        p.setFrame(placement.frame, display: false)
        refreshContentsScale()
    }

    func show(mode: OverlayMode) {
        self.mode = mode
        generation += 1
        pendingHide?.cancel()
        pendingHide = nil
        createPanelIfNeeded()
        guard let p = panel else { return }

        setPillWidth(basePillWidth)
        applyPlacement(to: p)

        // Clean up layers from other modes
        removeErrorLayer()
        removeTimerDisplay()
        removeSegmentProgress()
        if mode != .downloading { removeProgressBar() }

        // Restore bar opacity for modes that show the waveform
        switch mode {
        case .recording, .loading, .downloading:
            for bar in bars { bar.opacity = 1 }
        case .error, .fileQueue, .fileQueuePaused:
            for bar in bars { bar.opacity = 0 }
        }

        // Fade in
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        startAnimation()

        // Setup timer if recording
        if mode == .recording {
            recordingStartTime = Date()
            setupTimerDisplay()
        }
        // Setup progress bar if downloading mode
        if mode == .downloading {
            setupProgressBar()
        }
        // File queue modes render a single line of status text in the pill
        if case .fileQueue(let title, let progress) = mode {
            renderFileQueueText(title: title, progress: progress, paused: false)
        }
        if case .fileQueuePaused(let title) = mode {
            renderFileQueueText(title: title, progress: 0, paused: true)
        }
    }

    private func renderFileQueueText(title: String, progress: Double, paused: Bool) {
        guard let p = panel,
              let cv = p.contentView?.subviews.first?.layer else { return }
        removeErrorLayer()

        let text = CATextLayer()
        text.frame = CGRect(x: 12, y: (pillHeight - 16) / 2,
                            width: pillWidth - 24, height: 16)
        text.fontSize = 11
        text.foregroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        text.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        text.alignmentMode = .center
        text.contentsScale = p.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        text.truncationMode = .middle
        let message = formatFileQueueMessage(title: title, progress: progress, paused: paused)
        text.string = message
        cv.addSublayer(text)
        errorTextLayer = text
        publishAccessibilityMessage(message, isError: false, announce: true)
    }

    private func formatFileQueueMessage(title: String, progress: Double, paused: Bool) -> String {
        if paused { return "⏸ \(title)" }
        let pct = Int((progress * 100).rounded())
        return "\(title) - \(pct)%"
    }

    /// Update the file-queue overlay text in place without triggering a new
    /// fade-in animation. Caller must have entered `.fileQueue` mode first
    /// via `show(mode:)`; otherwise this is a no-op.
    func updateFileQueueProgress(title: String, progress: Double) {
        guard case .fileQueue = mode else { return }
        self.mode = .fileQueue(title: title, progress: progress)
        guard let layer = errorTextLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let message = formatFileQueueMessage(title: title, progress: progress, paused: false)
        layer.string = message
        CATransaction.commit()
        publishAccessibilityMessage(message, isError: false, announce: false)
    }

    /// Update download progress 0.0-1.0
    func updateProgress(_ progress: Double, status: String) {
        guard let progressLayer = progressLayer, let textLayer = progressTextLayer else { return }
        let clamped = min(1.0, max(0.0, progress))
        let trackWidth = pillWidth - 32
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame.size.width = trackWidth * CGFloat(clamped)
        textLayer.string = status
        CATransaction.commit()
        publishAccessibilityMessage(status, isError: false, announce: false)
    }

    private func setupProgressBar() {
        // Guard: don't create duplicate layers
        guard progressLayer == nil,
              let cv = panel?.contentView?.subviews.first?.layer else { return }

        // Hide bars during download
        for bar in bars { bar.isHidden = true }

        // Status text - centered
        let text = CATextLayer()
        text.frame = CGRect(x: 16, y: 28, width: pillWidth - 32, height: 20)
        text.fontSize = 12
        text.foregroundColor = NSColor(white: 0.7, alpha: 1).cgColor
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.alignmentMode = .center
        text.contentsScale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        text.string = "Downloading..."
        cv.addSublayer(text)
        progressTextLayer = text
        publishAccessibilityMessage("Downloading", isError: false, announce: true)

        // Background track
        let track = CALayer()
        track.frame = CGRect(x: 16, y: 14, width: pillWidth - 32, height: 5)
        track.cornerRadius = 2.5
        track.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        cv.addSublayer(track)
        progressTrackLayer = track

        // Progress fill
        let fill = CALayer()
        fill.frame = CGRect(x: 16, y: 14, width: 0, height: 5)
        fill.cornerRadius = 2.5
        fill.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        cv.addSublayer(fill)
        progressLayer = fill
    }

    private func removeProgressBar() {
        progressTrackLayer?.removeFromSuperlayer()
        progressLayer?.removeFromSuperlayer()
        progressTextLayer?.removeFromSuperlayer()
        progressTrackLayer = nil
        progressLayer = nil
        progressTextLayer = nil
        // Restore bars
        for bar in bars { bar.isHidden = false }
    }

    private func setupTimerDisplay() {
        guard timerTextLayer == nil, let cv = panel?.contentView?.subviews.first?.layer else { return }
        let text = CATextLayer()
        text.frame = CGRect(x: 0, y: 3, width: pillWidth, height: 14)
        text.fontSize = 10
        text.foregroundColor = NSColor(white: 0.5, alpha: 0.8).cgColor
        text.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        text.alignmentMode = .center
        text.contentsScale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        text.string = "0:00"
        cv.addSublayer(text)
        timerTextLayer = text
    }

    private func removeTimerDisplay() {
        timerTextLayer?.removeFromSuperlayer()
        timerTextLayer = nil
        recordingStartTime = nil
        recordingWarningExpiry = nil
    }

    /// Show a brief warning in the timer text during recording mode (e.g. "10s remaining").
    /// The warning shows for 3 seconds with orange color, then resumes showing elapsed time.
    func showRecordingWarning(_ message: String) {
        guard mode == .recording, let layer = timerTextLayer else { return }
        layer.foregroundColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 0.9).cgColor
        layer.string = message
        recordingWarningExpiry = Date().addingTimeInterval(3)
    }

    /// Show transcription segment progress during `.loading` mode (e.g. "Transcribing 3/10...")
    func updateSegmentProgress(current: Int, total: Int) {
        guard mode == .loading else { return }
        setupSegmentProgressLayer()
        segmentProgressLayer?.string = "Transcribing \(current)/\(total)..."
    }

    private func setupSegmentProgressLayer() {
        guard segmentProgressLayer == nil, let cv = panel?.contentView?.subviews.first?.layer else { return }
        let text = CATextLayer()
        text.frame = CGRect(x: 0, y: 3, width: pillWidth, height: 14)
        text.fontSize = 10
        text.foregroundColor = NSColor(white: 0.5, alpha: 0.8).cgColor
        text.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        text.alignmentMode = .center
        text.contentsScale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        cv.addSublayer(text)
        segmentProgressLayer = text
    }

    private func removeSegmentProgress() {
        segmentProgressLayer?.removeFromSuperlayer()
        segmentProgressLayer = nil
    }

    func hide() {
        guard let p = panel else { return }
        // Clear the mode up front, not in the completion handler: the fade
        // leaves `isVisible == true` for 0.3 s, and any watchdog that reads a
        // stale mode in that gap would act on a panel that is already leaving.
        mode = nil
        generation += 1
        let capturedGeneration = generation

        // Fade out
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async { [weak self] in
                guard self?.generation == capturedGeneration else { return }
                self?.stopAnimation()
                self?.removeTimerDisplay()
                self?.removeSegmentProgress()
                self?.removeProgressBar()
                p.orderOut(nil)
                p.alphaValue = 1
            }
        })
    }

    /// Show a brief info message (white), auto-hides after 5 seconds.
    func showInfo(_ message: String) {
        showMessage(
            message,
            color: NSColor(white: 0.7, alpha: 1),
            isError: false
        )
    }

    /// Show a brief error message (red tint), auto-hides after 5 seconds.
    func showError(_ message: String) {
        showMessage(
            message,
            color: NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1),
            isError: true
        )
    }

    /// Width that actually fits `message` at the toast font, clamped so short
    /// toasts keep the familiar pill and long ones stop before absurd.
    nonisolated static func messagePillWidth(for message: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
        return min(440, max(160, ceil(textWidth) + 32))
    }

    private func setPillWidth(_ width: CGFloat) {
        guard pillWidth != width else { return }
        pillWidth = width
        guard let p = panel else { return }
        if let blur = p.contentView?.subviews.first {
            blur.frame = NSRect(x: 0, y: 0, width: width, height: pillHeight)
        }
    }

    private func showMessage(
        _ message: String,
        color: NSColor,
        isError: Bool
    ) {
        createPanelIfNeeded()
        guard let p = panel, let cv = p.contentView?.subviews.first?.layer else { return }

        // A toast must not kill an active session's pill: remember what was on
        // screen and put it back when the toast expires. The recording clock
        // keeps its epoch — the session did not restart.
        let resumeMode: OverlayMode?
        switch mode {
        case .recording, .loading, .downloading, .fileQueue, .fileQueuePaused:
            resumeMode = mode
        case .error, nil:
            resumeMode = nil
        }
        let resumeStart = recordingStartTime

        self.mode = .error
        // A `hide()` may still be fading out; its completion is gated on
        // `generation`, so bumping it here keeps that orderOut from killing
        // this toast 0.3 s in (lived: "Ready" after the first model install
        // flashed and vanished).
        generation += 1
        stopAnimation()
        removeProgressBar()
        removeErrorLayer()
        for bar in bars { bar.opacity = 0 }

        setPillWidth(Self.messagePillWidth(for: message))

        let text = CATextLayer()
        text.frame = CGRect(x: 12, y: (pillHeight - 16) / 2, width: pillWidth - 24, height: 16)
        text.fontSize = 11
        text.foregroundColor = color.cgColor
        text.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        text.alignmentMode = .center
        text.contentsScale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        text.truncationMode = .end
        text.string = message
        cv.addSublayer(text)
        errorTextLayer = text
        publishAccessibilityMessage(message, isError: isError, announce: true)

        applyPlacement(to: p)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .error else { return }
            self.removeErrorLayer()
            if let resumeMode {
                self.show(mode: resumeMode)
                self.recordingStartTime = resumeStart
            } else {
                self.hide()
            }
        }
        pendingHide = work
        // Toasts over an active session return to it quickly; terminal toasts
        // stay the full 5 s the reading owner asked for.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (resumeMode == nil ? 5 : 2.5),
            execute: work
        )
    }

    private func removeErrorLayer() {
        errorTextLayer?.removeFromSuperlayer()
        errorTextLayer = nil
        clearAccessibilityMessage()
    }

    private func publishAccessibilityMessage(
        _ message: String,
        isError: Bool,
        announce: Bool
    ) {
        let presentation = Self.accessibilityAnnouncement(
            message: message,
            isError: isError
        )
        if let contentView = panel?.contentView {
            contentView.setAccessibilityElement(true)
            contentView.setAccessibilityRole(.staticText)
            contentView.setAccessibilityLabel(presentation.label)
            contentView.setAccessibilityValue(presentation.message)
        }
        guard announce, let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: presentation.message,
                .priority: presentation.priority,
            ]
        )
    }

    private func clearAccessibilityMessage() {
        guard let contentView = panel?.contentView else { return }
        contentView.setAccessibilityValue(nil)
        contentView.setAccessibilityLabel(nil)
        contentView.setAccessibilityElement(false)
    }

    /// Safe to call from any thread (audio callback)
    nonisolated func updateLevel(_ level: Float) {
        currentLevel = level
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        let frame = resolvePlacement()?.frame
            ?? NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // `.floating` (3) loses to legacy fullscreen content, which is shown at
        // NSFullScreenModeWindowLevel — the pill vanished behind fullscreen video
        // and games. `.statusBar` (25) is the conventional level for a system
        // overlay. Not cosmetic: with Managed/Transient/Stationary unspecified,
        // NSWindow derives Space and exposé behaviour from the window level, so
        // this belongs with `.canJoinAllApplications` above, not apart from it.
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = Self.panelCollectionBehavior

        let cv = p.contentView!
        cv.wantsLayer = true
        cv.layer!.cornerRadius = pillRadius
        cv.layer!.masksToBounds = true

        // Glass blur
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer!.cornerRadius = pillRadius
        blur.layer!.masksToBounds = true
        blur.layer!.borderWidth = 1.0
        blur.layer!.borderColor = NSColor(white: 1.0, alpha: 0.4).cgColor
        cv.addSubview(blur)

        // Pre-create bar layers
        bars.removeAll()
        let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (pillWidth - totalW) / 2

        for i in 0..<barCount {
            let bar = CALayer()
            let bx = startX + CGFloat(i) * (barWidth + barGap)
            bar.frame = CGRect(x: bx, y: pillHeight / 2 - barMinHeight / 2, width: barWidth, height: barMinHeight)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor(white: 0.25, alpha: 0.6).cgColor
            // Disable implicit animations
            bar.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
            ]
            blur.layer!.addSublayer(bar)
            bars.append(bar)
        }

        panel = p
        smoothLevels = Array(repeating: 0, count: barCount)
    }

    private func applyPlacement(to panel: NSPanel) {
        guard let placement = resolvePlacement() else { return }
        placedScreenFrame = placement.screenFrame
        panel.setFrame(placement.frame, display: false)
        refreshContentsScale()
    }

    private func resolvePlacement() -> OverlayPlacement? {
        OverlayPlacementResolver.resolve(
            OverlayPlacementRequest(
                screens: NSScreen.screens.map(\.frame),
                cursor: NSEvent.mouseLocation,
                mainScreen: NSScreen.main?.frame,
                panelSize: CGSize(width: pillWidth, height: pillHeight)
            )
        )
    }

    private func refreshContentsScale() {
        let scale = panel?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        timerTextLayer?.contentsScale = scale
        segmentProgressLayer?.contentsScale = scale
        progressTextLayer?.contentsScale = scale
        errorTextLayer?.contentsScale = scale
    }

    private func startAnimation() {
        guard timer == nil else { return }
        tick = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        // See screenObserver: dispatch handlers run outside Swift concurrency,
        // where assumeIsolated's executor check crashes on macOS 26.
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.animationTick()
            }
        }
        t.resume()
        timer = t
    }

    private func stopAnimation() {
        timer?.cancel()
        timer = nil
    }

    private func animationTick() {
        tick += 1
        // Walking the cursor to another display posts no notification, so the
        // only way to follow the user there is to look. 5 Hz, and it costs
        // nothing unless the screen actually changed.
        if tick % 6 == 0 { repositionToTargetSurface() }
        // Update recording timer (skip during warning period)
        if mode == .recording, let start = recordingStartTime, let layer = timerTextLayer {
            if let expiry = recordingWarningExpiry {
                if Date() >= expiry {
                    // Warning expired - restore normal timer appearance
                    recordingWarningExpiry = nil
                    layer.foregroundColor = NSColor(white: 0.5, alpha: 0.8).cgColor
                }
                // During warning: don't overwrite the warning text
            } else {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                layer.string = String(format: "%d:%02d", mins, secs)
            }
        }
        // Skip bar updates in downloading mode - bars are hidden, progress bar is shown
        if mode == .downloading { return }

        let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (pillWidth - totalW) / 2
        let level = currentLevel

        for i in 0..<barCount {
            guard i < bars.count, i < smoothLevels.count else { return }
            let target: Float
            switch mode {
            case .recording:
                // Edge bars move less: 1.0 at center, 0.5 at edges
                let center = Float(barCount - 1) / 2
                let edgeDamp = 1.0 - 0.5 * abs(Float(i) - center) / center
                let variation = sin(Float(tick) * 0.3 + Float(i) * 0.5) * 0.3 * edgeDamp
                target = min(1.0, max(0, level + variation * level))
            case .loading:
                let wave = sin(Float(tick) * 0.15 - Float(i) * 0.35)
                target = 0.15 + 0.35 * (wave + 1) / 2
            case .downloading:
                target = 0 // unreachable due to early return above
            case .error, .fileQueue, .fileQueuePaused:
                target = 0
            case nil:
                // Hidden: the animation timer is torn down with the panel, so
                // this only lands on a frame already in flight. Settle the bars.
                target = 0
            }

            // Smooth
            let diff = target - smoothLevels[i]
            smoothLevels[i] += diff * (diff > 0 ? 0.4 : 0.12)

            let h = barMinHeight + CGFloat(smoothLevels[i]) * (barMaxHeight - barMinHeight)
            let bx = startX + CGFloat(i) * (barWidth + barGap)
            let by = (pillHeight - h) / 2

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bars[i].opacity = 1
            bars[i].frame = CGRect(x: bx, y: by, width: barWidth, height: h)
            let alpha = 0.4 + 0.5 * CGFloat(smoothLevels[i])
            bars[i].backgroundColor = NSColor(white: 0.25, alpha: alpha).cgColor
            CATransaction.commit()
        }
    }
}
