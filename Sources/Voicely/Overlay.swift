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

@MainActor
final class Overlay {
    private var panel: NSPanel?
    private var bars: [CALayer] = []
    private var timer: DispatchSourceTimer?
    private var mode: OverlayMode = .recording
    private var smoothLevels: [Float] = Array(repeating: 0, count: 32)
    private var tick: Int = 0
    private var progressTrackLayer: CALayer?
    private var progressLayer: CALayer?
    private var progressTextLayer: CATextLayer?
    private var errorTextLayer: CATextLayer?
    private var generation: Int = 0
    var isVisible: Bool { panel?.isVisible ?? false }
    var currentMode: OverlayMode { mode }
    private var timerTextLayer: CATextLayer?
    private var recordingStartTime: Date?
    private var segmentProgressLayer: CATextLayer?
    private var pendingHide: DispatchWorkItem?
    /// Brief warning shown via timer text during recording (e.g. "10s remaining")
    private var recordingWarningExpiry: Date?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    // Audio level updated from background audio thread - nonisolated access via lock
    private let levelLock = NSLock()
    nonisolated(unsafe) private var _currentLevel: Float = 0
    nonisolated var currentLevel: Float {
        get { levelLock.withLock { _currentLevel } }
        set { levelLock.withLock { _currentLevel = newValue } }
    }

    private let barCount = 32
    private let pillWidth: CGFloat = 160
    private let pillHeight: CGFloat = 56
    private let pillRadius: CGFloat = 28
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1.2
    private let barMinHeight: CGFloat = 6
    private let barMaxHeight: CGFloat = 40

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionToCurrentScreen()
            }
        }
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
    }

    /// Reposition overlay to the screen containing the mouse cursor.
    private func repositionToCurrentScreen() {
        guard let p = panel, p.isVisible else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let screen = screen {
            let x = screen.frame.origin.x + (screen.frame.width - pillWidth) / 2
            let y = screen.frame.origin.y + 140
            p.setFrame(NSRect(x: x, y: y, width: pillWidth, height: pillHeight), display: false)
        }
    }

    func show(mode: OverlayMode) {
        self.mode = mode
        generation += 1
        pendingHide?.cancel()
        pendingHide = nil
        createPanelIfNeeded()
        guard let p = panel else { return }

        // Reposition to current screen on every show()
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let screen = screen {
            let x = screen.frame.origin.x + (screen.frame.width - pillWidth) / 2
            let y = screen.frame.origin.y + 140
            p.setFrame(NSRect(x: x, y: y, width: pillWidth, height: pillHeight), display: false)
        }

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
        text.string = formatFileQueueMessage(title: title, progress: progress, paused: paused)
        cv.addSublayer(text)
        errorTextLayer = text
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
        layer.string = formatFileQueueMessage(title: title, progress: progress, paused: false)
        CATransaction.commit()
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
        showMessage(message, color: NSColor(white: 0.7, alpha: 1))
    }

    /// Show a brief error message (red tint), auto-hides after 5 seconds.
    func showError(_ message: String) {
        showMessage(message, color: NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1))
    }

    private func showMessage(_ message: String, color: NSColor) {
        createPanelIfNeeded()
        guard let p = panel, let cv = p.contentView?.subviews.first?.layer else { return }

        self.mode = .error
        stopAnimation()
        removeProgressBar()
        removeErrorLayer()
        for bar in bars { bar.opacity = 0 }

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

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.mode == .error else { return }
            self?.removeErrorLayer()
            self?.hide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func removeErrorLayer() {
        errorTextLayer?.removeFromSuperlayer()
        errorTextLayer = nil
    }

    /// Safe to call from any thread (audio callback)
    nonisolated func updateLevel(_ level: Float) {
        currentLevel = level
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen = screen else { return }
        let x = screen.frame.origin.x + (screen.frame.width - pillWidth) / 2
        let y = screen.frame.origin.y + 140

        let frame = NSRect(x: x, y: y, width: pillWidth, height: pillHeight)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

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

    private func startAnimation() {
        guard timer == nil else { return }
        tick = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
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
