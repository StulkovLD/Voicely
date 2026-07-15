import AVFoundation
import CoreAudioTypes
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit
import VoicelyCore

/// Records both system audio (call participants) and microphone (you) as separate channels
final class CallRecorder: @unchecked Sendable {
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onMaxDuration: (@Sendable () -> Void)?
    var onMaxDurationWarning: (@Sendable (Int) -> Void)?
    var onStreamError: (@Sendable (String) -> Void)?
    /// Fired once when disk capture is degraded because the volume ran low.
    var onDiskSpillStopped: (@Sendable (UInt64) -> Void)?
    /// Fired once per channel if bounded backpressure or a writer failure drops
    /// frames. Recording continues and the final capture metadata stays partial.
    var onCaptureDegraded: (@Sendable (String) -> Void)?

    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var delegate: CallStreamDelegate?
    private var configChangeObserver: NSObjectProtocol?
    private let inputRouteGuard = CallInputRouteGuard()
    private let streamErrorGate = CallRecorderStreamErrorGate()

    private let lifecycle = CallRecorderLifecycleState()

    /// True only after both ScreenCaptureKit and the microphone engine have
    /// started successfully. A partially-initialized start never reports as
    /// running, which keeps retries from accepting a system-only recording.
    var isFullyRunning: Bool {
        lifecycle.isRunning
    }

    /// Atomic handoff truth used by AppDelegate immediately after `start()`
    /// returns. A plain `isFullyRunning` check can miss an interruption that
    /// lands between recorder publication and the app's `.callRecording`
    /// transition.
    var startHandoffStatus: CallRecorderLifecycleState.StartHandoffStatus {
        lifecycle.startHandoffStatus()
    }

    // MARK: - Disk-authoritative channel capture

    /// Typed filesystem capability for this capture. It exposes only the two
    /// fixed WAV paths; directory deletion remains inside VoicelyCore.
    private var pendingCaptureStore: PendingCallRecoveryStore?
    private var pendingCaptureHandle: PendingCallCaptureHandle?

    private let captureLock = NSLock()
    private let captureEventQueue = DispatchQueue(
        label: "voicely.call-capture.events",
        qos: .utility
    )
    private var micCaptureWriter: CallCaptureWAVWriter?
    private var systemCaptureWriter: CallCaptureWAVWriter?
    private var degradedChannels: Set<String> = []
    private var captureTimelineOriginSeconds: Double?
    /// Minimum free bytes required to start/continue capture.
    private static let spillMinFreeBytes: UInt64 = 512 * 1024 * 1024

    // Safety cap on classic-WAV recording length. Default 8 hours stays below
    // the 4 GiB RIFF size ceiling for mono PCM16 at 48 kHz.
    private static var maxHours: Int {
        if let env = ProcessInfo.processInfo.environment["VOICELY_MAX_CALL_HOURS"],
           let h = Int(env), h > 0, h <= 12 {
            return h
        }
        return 8
    }
    private static let effectiveSilenceMinimumDurationSeconds: Double = 2
    private static let effectiveSilenceMeanVolumeFloorDBFS: Double = -75
    private static let effectiveSilencePeakVolumeFloorDBFS: Double = -55

    private let sampleRateLock = NSLock()
    private var micSampleRate: Double = 48000
    private var systemSampleRate: Double = 48000
    // Dedicated lock for the two cap flags. They are touched from both the
    // SCStream thread (system handler) and the AVAudioEngine render thread (mic
    // tap); a single lock — kept separate from the buffer locks — prevents the
    // data race that arose when each path guarded them under its own buffer lock.
    private let limitLock = NSLock()
    private var maxDurationNotified = false
    private var warningFired = false
    private var startTime: Date?

    struct ChannelCaptureTruth: Sendable, Equatable {
        let sampleCount: Int
        let sampleRate: Double
        let durationSeconds: Double
        let rms: Double
        let peakAmplitude: Double
        let meanVolumeDBFS: Double
        let peakVolumeDBFS: Double
        let isEffectivelySilent: Bool
        let droppedSampleCount: Int
        let zeroFilledSampleCount: Int
        let timelineOriginOffsetSeconds: Double
        let maxClockDriftSeconds: Double
        let discontinuityCount: Int
        let failure: String?
        let isDegraded: Bool

        init(
            sampleCount: Int,
            sampleRate: Double,
            durationSeconds: Double,
            rms: Double,
            peakAmplitude: Double,
            meanVolumeDBFS: Double,
            peakVolumeDBFS: Double,
            isEffectivelySilent: Bool,
            droppedSampleCount: Int = 0,
            zeroFilledSampleCount: Int = 0,
            timelineOriginOffsetSeconds: Double = 0,
            maxClockDriftSeconds: Double = 0,
            discontinuityCount: Int = 0,
            failure: String? = nil,
            isDegraded: Bool = false
        ) {
            self.sampleCount = sampleCount
            self.sampleRate = sampleRate
            self.durationSeconds = durationSeconds
            self.rms = rms
            self.peakAmplitude = peakAmplitude
            self.meanVolumeDBFS = meanVolumeDBFS
            self.peakVolumeDBFS = peakVolumeDBFS
            self.isEffectivelySilent = isEffectivelySilent
            self.droppedSampleCount = droppedSampleCount
            self.zeroFilledSampleCount = zeroFilledSampleCount
            self.timelineOriginOffsetSeconds = timelineOriginOffsetSeconds
            self.maxClockDriftSeconds = maxClockDriftSeconds
            self.discontinuityCount = discontinuityCount
            self.failure = failure
            self.isDegraded = isDegraded
        }
    }

    struct CaptureTruth: Sendable, Equatable {
        let mic: ChannelCaptureTruth
        let system: ChannelCaptureTruth
        /// First runtime stream/configuration interruption for this capture.
        /// A nil value means the user stopped a healthy capture normally.
        let interruptionReason: String?

        init(
            mic: ChannelCaptureTruth,
            system: ChannelCaptureTruth,
            interruptionReason: String? = nil
        ) {
            self.mic = mic
            self.system = system
            self.interruptionReason = interruptionReason
        }
    }

    struct CallAudio: Sendable {
        let sourceCapture: PendingCallClaim
        let captureTruth: CaptureTruth

        var micFileURL: URL? {
            captureTruth.mic.sampleCount > 0 ? sourceCapture.micFileURL : nil
        }
        var systemFileURL: URL? {
            captureTruth.system.sampleCount > 0 ? sourceCapture.systemFileURL : nil
        }
        var startTime: Date { sourceCapture.startTime }
        var micSampleRate: Double { captureTruth.mic.sampleRate }
        var systemSampleRate: Double { captureTruth.system.sampleRate }
    }

    /// Start recording: system audio via ScreenCaptureKit + mic via AVAudioEngine
    func start() async throws {
        guard beginStart() else { throw CallRecorderError.alreadyRunning }

        var keepInputRoute = false
        var candidateStream: SCStream?
        var candidateEngine: AVAudioEngine?
        var candidateDelegate: CallStreamDelegate?
        var candidateObserver: NSObjectProtocol?
        var micTapInstalled = false

        inputRouteGuard.prepareForCallRecording()
        defer {
            if !keepInputRoute {
                inputRouteGuard.restoreIfNeeded()
            }
        }
        do {
            try Task.checkCancellation()
            NSLog("[Voicely] CallRecorder.start() called")
            sampleRateLock.withLock {
                self.micSampleRate = 48_000
                self.systemSampleRate = 48_000
            }
            limitLock.withLock {
                maxDurationNotified = false
                warningFired = false
            }

            // 1. Get shareable content (we capture entire display audio)
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            try Task.checkCancellation()
            guard let display = content.displays.first else {
                throw CallRecorderError.noDisplay
            }

            // 2. Configure stream for audio only
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            // Establish the shared wall/timeline origin only after discovery and
            // permission work. Startup latency before this point is not call
            // audio; the system channel starts next, and the later mic offset is
            // represented by leading PCM silence.
            startTime = Date()
            captureTimelineOriginSeconds = Self.monotonicHostTimeSeconds()
            try setupCaptureSession()
            let recordingMaxHours = Self.maxHours

            // 3. Keep all resources local until both capture paths are healthy.
            let delegate = CallStreamDelegate(onSamples: {
                [weak self] samples, sampleRate, presentationTimeSeconds in
                guard let self else { return }
                let sampleLimit = Self.sampleLimit(
                    maxHours: recordingMaxHours,
                    sampleRate: sampleRate
                )
                let warningThreshold = Self.warningSampleThreshold(
                    maxHours: recordingMaxHours,
                    sampleRate: sampleRate
                )

                self.sampleRateLock.withLock { self.systemSampleRate = sampleRate }
                let enqueue = self.enqueueSystemCapture(
                    samples,
                    maximumTotalSamples: sampleLimit,
                    presentationTimeSeconds: presentationTimeSeconds
                )
                let count = enqueue.timelineSampleCount
                let atLimit = count >= sampleLimit

                let (shouldNotify, shouldWarn) = self.limitLock.withLock {
                    let shouldNotify = atLimit && !self.maxDurationNotified
                    if shouldNotify { self.maxDurationNotified = true }
                    let shouldWarn = !self.warningFired && count >= warningThreshold
                    if shouldWarn { self.warningFired = true }
                    return (shouldNotify, shouldWarn)
                }
                if shouldWarn {
                    let remaining = Self.remainingSeconds(
                        maxHours: recordingMaxHours,
                        sampleCount: count,
                        sampleRate: sampleRate
                    )
                    self.captureEventQueue.async { [weak self] in
                        self?.onMaxDurationWarning?(remaining)
                    }
                }
                if shouldNotify {
                    self.captureEventQueue.async { [weak self] in
                        self?.onMaxDuration?()
                    }
                    return
                }
            }, onError: { [weak self] message in
                self?.reportStreamInterruption(message)
            })
            delegate.onStreamDied = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.handleStreamDied()
                }
            }
            candidateDelegate = delegate

            let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
            candidateStream = stream
            try stream.addStreamOutput(
                delegate,
                type: .audio,
                sampleHandlerQueue: .global(qos: .userInitiated)
            )
            try await stream.startCapture()
            try Task.checkCancellation()
            NSLog("[Voicely] SCStream started successfully")

            // 4. Start microphone recording before publishing running state.
            let engine = AVAudioEngine()
            candidateEngine = engine
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard CallCaptureWAVWriter.isSupportedSampleRate(format.sampleRate),
                  format.channelCount > 0 else {
                NSLog(
                    "[Voicely] Invalid mic format: %.0f Hz, %d ch",
                    format.sampleRate,
                    format.channelCount
                )
                throw CallRecorderError.noAudio
            }
            NSLog(
                "[Voicely] Mic format: %.0f Hz, %d ch",
                format.sampleRate,
                format.channelCount
            )
            setMicSampleRate(format.sampleRate)
            let micChannelCount = Int(format.channelCount)
            let micSampleRate = format.sampleRate
            try setupMicCapture(sampleRate: micSampleRate)
            let micSampleLimit = Self.sampleLimit(
                maxHours: recordingMaxHours,
                sampleRate: micSampleRate
            )
            let micWarningThreshold = Self.warningSampleThreshold(
                maxHours: recordingMaxHours,
                sampleRate: micSampleRate
            )
            let micMixer = CallMicMixBuffer(
                capacity: CallCaptureWAVWriter.maximumInputChunkSamples
            )

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
                [weak self] buffer, audioTime in
                guard let self else { return }
                let frameLength = Int(buffer.frameLength)
                guard let floatChannelData = buffer.floatChannelData, frameLength > 0 else { return }
                let basePresentationTime = audioTime.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: audioTime.hostTime)
                    : nil
                var offset = 0
                while offset < frameLength {
                    let count = min(
                        CallCaptureWAVWriter.maximumInputChunkSamples,
                        frameLength - offset
                    )
                    let presentationTime = basePresentationTime.map {
                        $0 + Double(offset) / micSampleRate
                    }
                    if micChannelCount == 1 {
                        self.processMicCaptureCallback(
                            UnsafeBufferPointer(
                                start: floatChannelData[0] + offset,
                                count: count
                            ),
                            sampleRate: micSampleRate,
                            sampleLimit: micSampleLimit,
                            warningThreshold: micWarningThreshold,
                            maxHours: recordingMaxHours,
                            presentationTimeSeconds: presentationTime
                        )
                    } else {
                        micMixer.withMixedSamples(
                            channelData: floatChannelData,
                            channelCount: micChannelCount,
                            offset: offset,
                            count: count
                        ) { mixed in
                            self.processMicCaptureCallback(
                                mixed,
                                sampleRate: micSampleRate,
                                sampleLimit: micSampleLimit,
                                warningThreshold: micWarningThreshold,
                                maxHours: recordingMaxHours,
                                presentationTimeSeconds: presentationTime
                            )
                        }
                    }
                    offset += count
                }
            }
            micTapInstalled = true

            engine.prepare()
            try engine.start()

            // Device switches and Bluetooth/USB route changes can leave an
            // AVAudioEngine alive but no longer delivering mic samples. Treat
            // the change as a capture interruption so the caller saves partial.
            candidateObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.reportStreamInterruption("Microphone configuration changed during call recording")
            }

            // Publish atomically from the caller's perspective only after both
            // engines started. Any interruption observed while starting makes
            // this guard fail and flows through the same full rollback.
            self.stream = stream
            self.micEngine = engine
            self.delegate = delegate
            self.configChangeObserver = candidateObserver
            guard markRunningIfHealthy() else {
                throw CallRecorderError.noAudio
            }

            keepInputRoute = true

            NSLog("[Voicely] Call recording started (system audio + mic)")
        } catch {
            candidateDelegate?.onStreamDied = nil
            if let observer = candidateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if micTapInstalled, let engine = candidateEngine {
                engine.inputNode.removeTap(onBus: 0)
            }
            candidateEngine?.stop()
            if let stream = candidateStream {
                try? await stream.stopCapture()
            }

            self.configChangeObserver = nil
            self.micEngine = nil
            self.stream = nil
            self.delegate = nil
            discardFailedStartArtifacts()
            finishLifecycleStop()
            throw error
        }
    }

    private func beginStart() -> Bool {
        let began = lifecycle.beginStart()
        if began { streamErrorGate.reset() }
        return began
    }

    private func markRunningIfHealthy() -> Bool {
        let result = lifecycle.publishRunningIfHealthy()
        if let pending = result.pendingInterruption {
            NSLog("[Voicely] Call start interrupted before publication: %@", pending)
        }
        return result.healthy
    }

    private func beginLifecycleStop() -> String? {
        lifecycle.beginStop()
    }

    private func finishLifecycleStop() {
        lifecycle.finishStop()
    }

    private func reportStreamInterruption(_ message: String) {
        let shouldReport = lifecycle.recordInterruption(message)
        guard shouldReport, streamErrorGate.claim() else { return }
        onStreamError?(message)
    }

    private func handleStreamDied() {
        let shouldCleanUp = lifecycle.beginStreamDeathCleanup()
        guard shouldCleanUp else { return }

        delegate?.onStreamDied = nil
        removeConfigurationObserver()
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
        }
        inputRouteGuard.restoreIfNeeded()
        stream = nil
        delegate = nil
        // Keep the lifecycle in `.stopping` and retain its interruption reason.
        // AppDelegate's queued stop transition still has to drain the writers,
        // claim the durable capture, and publish partial capture metadata.
    }

    private func removeConfigurationObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func discardFailedStartArtifacts() {
        let snapshots = finalizeCaptureWriters()
        // A cancellation can race with a partially started ScreenCaptureKit
        // stream. Publish the typed capture for recovery; no raw directory URL
        // or recursive-delete capability exists in this layer.
        let capturedPrefixExists = (snapshots.mic?.sampleCount ?? 0) > 0
            || (snapshots.system?.sampleCount ?? 0) > 0
        if capturedPrefixExists {
            markRecoveryCaptured(mic: snapshots.mic, system: snapshots.system)
        } else if let store = captureLock.withLock({ pendingCaptureStore }),
                  let handle = captureLock.withLock({ pendingCaptureHandle }) {
            _ = try? store.discardEmpty(handle)
        }
        clearCaptureSessionReferences()
    }

    private func clearCaptureSessionReferences() {
        captureLock.withLock {
            pendingCaptureHandle = nil
            pendingCaptureStore = nil
        }
        startTime = nil
    }

    /// Synchronous app-termination fallback. Producers stop, every accepted ring
    /// slot drains, and the recovery marker remains on disk for the next launch.
    func forceStop() {
        _ = beginLifecycleStop()
        // Prevent onStreamDied from racing with cleanup
        delegate?.onStreamDied = nil
        removeConfigurationObserver()

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        inputRouteGuard.restoreIfNeeded()

        if let stream = self.stream {
            self.stream = nil
            self.delegate = nil
            // Stop capture synchronously enough for termination
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await stream.stopCapture()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        } else {
            self.delegate = nil
        }

        // Drain both bounded queues and leave the recovery marker in place. The
        // next launch will save this interrupted capture.
        let snapshots = finalizeCaptureWriters()
        markRecoveryCaptured(mic: snapshots.mic, system: snapshots.system)
        finishLifecycleStop()
    }

    /// Stop recording and return disk-backed channel truth. No whole-channel
    /// sample array or PCM buffer crosses this boundary.
    func stop() async -> CallAudio? {
        let interruptionReason = beginLifecycleStop()
        // Prevent onStreamDied from racing with stop()
        delegate?.onStreamDied = nil
        removeConfigurationObserver()
        // #91: Suppress stale audio level callbacks from in-flight delegate calls
        onAudioLevel = nil

        if let stream = self.stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        self.delegate = nil
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
        }
        inputRouteGuard.restoreIfNeeded()

        // Producers are stopped. Drain each fixed ring before closing its WAV
        // header so every accepted frame is durable and readable.
        let snapshots = finalizeCaptureWriters()
        let (micRate, sysRate) = getSampleRates()
        let micTruth = Self.analyzeChannelCapture(
            snapshot: snapshots.mic,
            fallbackSampleRate: micRate
        )
        let systemTruth = Self.analyzeChannelCapture(
            snapshot: snapshots.system,
            fallbackSampleRate: sysRate
        )
        NSLog("[Voicely] Disk capture finalized - System: %d, Mic: %d, dropped: %d/%d",
              systemTruth.sampleCount,
              micTruth.sampleCount,
              systemTruth.droppedSampleCount,
              micTruth.droppedSampleCount)

        markRecoveryCaptured(mic: snapshots.mic, system: snapshots.system)

        guard micTruth.sampleCount > 0 || systemTruth.sampleCount > 0 else {
            NSLog("[Voicely] Capture failure: both disk-backed channels are empty. Check Screen Recording permission")
            if let store = captureLock.withLock({ pendingCaptureStore }),
               let handle = captureLock.withLock({ pendingCaptureHandle }) {
                _ = try? store.discardEmpty(handle)
            }
            clearCaptureSessionReferences()
            finishLifecycleStop()
            return nil
        }

        let captureTruth = CaptureTruth(
            mic: micTruth,
            system: systemTruth,
            interruptionReason: interruptionReason
        )
        guard let store = captureLock.withLock({ pendingCaptureStore }),
              let handle = captureLock.withLock({ pendingCaptureHandle }) else {
            NSLog("[Voicely] Capture failure: typed staging handle disappeared")
            finishLifecycleStop()
            return nil
        }
        let claim: PendingCallClaim
        do {
            claim = try store.claim(handle)
        } catch {
            NSLog("[Voicely] Capture finalized but could not be claimed: %@",
                  error.localizedDescription)
            clearCaptureSessionReferences()
            finishLifecycleStop()
            return nil
        }

        NSLog("[Voicely] Call recording stopped. Mic: %d samples, System: %d samples",
              micTruth.sampleCount, systemTruth.sampleCount)
        clearCaptureSessionReferences()
        finishLifecycleStop()
        return CallAudio(
            sourceCapture: claim,
            captureTruth: captureTruth
        )
    }

    // MARK: - Capture staging helpers

    private func setupCaptureSession() throws {
        let time = startTime ?? Date()
        let root = PendingCallRecoveryStore.defaultRootURL
        if let free = Self.freeBytes(at: root), free < Self.spillMinFreeBytes {
            onDiskSpillStopped?(free)
            throw CallRecorderError.captureStorageUnavailable(
                "Only \(free / (1024 * 1024)) MB is free"
            )
        }

        let store = try PendingCallRecoveryStore()
        let handle = try store.createCapture(
            startTime: time,
            expectedChannels: Set(PendingCallChannel.allCases)
        )
        let systemURL = handle.systemFileURL
        do {
            let systemFD = try store.createChannelFileDescriptor(
                handle,
                channel: .system
            )
            let writer = try CallCaptureWAVWriter(
                url: systemURL,
                sampleRate: 48_000,
                ownedFileDescriptor: systemFD,
                minimumFreeBytes: Self.spillMinFreeBytes,
                timelineOriginSeconds: captureTimelineOriginSeconds,
                onDegraded: { [weak self] reason in
                    self?.handleCaptureDegraded(channel: "system", reason: reason)
                }
            )
            captureLock.withLock {
                pendingCaptureStore = store
                pendingCaptureHandle = handle
                systemCaptureWriter = writer
                micCaptureWriter = nil
                degradedChannels = []
            }
        } catch {
            // Typed cleanup validates that no audio payload exists before it can
            // retire the transaction. A non-empty capture is retained.
            _ = try? store.discardEmpty(handle)
            throw error
        }
    }

    private func setupMicCapture(sampleRate: Double) throws {
        let context: (PendingCallRecoveryStore, PendingCallCaptureHandle)? =
            captureLock.withLock {
                guard let store = pendingCaptureStore,
                      let handle = pendingCaptureHandle else { return nil }
                return (store, handle)
            }
        guard let (store, handle) = context else {
            throw CallRecorderError.captureStorageUnavailable("typed staging handle is missing")
        }
        let url = handle.micFileURL
        let micFD = try store.createChannelFileDescriptor(
            handle,
            channel: .mic
        )
        let writer = try CallCaptureWAVWriter(
            url: url,
            sampleRate: sampleRate,
            ownedFileDescriptor: micFD,
            minimumFreeBytes: Self.spillMinFreeBytes,
            timelineOriginSeconds: captureTimelineOriginSeconds,
            onDegraded: { [weak self] reason in
                self?.handleCaptureDegraded(channel: "mic", reason: reason)
            }
        )
        captureLock.withLock {
            micCaptureWriter = writer
        }
    }

    private func enqueueSystemCapture(
        _ samples: UnsafeBufferPointer<Float>,
        maximumTotalSamples: Int,
        presentationTimeSeconds: Double?
    ) -> CallCaptureWAVWriter.EnqueueResult {
        let writer = captureLock.withLock { systemCaptureWriter }
        guard let writer else {
            handleCaptureDegraded(channel: "system", reason: "capture writer is unavailable")
            return CallCaptureWAVWriter.EnqueueResult(
                acceptedSampleCount: 0,
                droppedSampleCount: samples.count,
                timelineSampleCount: samples.count,
                becameDegraded: true
            )
        }
        return writer.enqueue(
            samples,
            maximumTotalSamples: maximumTotalSamples,
            presentationTimeSeconds: presentationTimeSeconds
        )
    }

    private func enqueueMicCapture(
        _ samples: UnsafeBufferPointer<Float>,
        maximumTotalSamples: Int,
        presentationTimeSeconds: Double?
    ) -> CallCaptureWAVWriter.EnqueueResult {
        let writer = captureLock.withLock { micCaptureWriter }
        guard let writer else {
            handleCaptureDegraded(channel: "mic", reason: "capture writer is unavailable")
            return CallCaptureWAVWriter.EnqueueResult(
                acceptedSampleCount: 0,
                droppedSampleCount: samples.count,
                timelineSampleCount: samples.count,
                becameDegraded: true
            )
        }
        return writer.enqueue(
            samples,
            maximumTotalSamples: maximumTotalSamples,
            presentationTimeSeconds: presentationTimeSeconds
        )
    }

    private func processMicCaptureCallback(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        sampleLimit: Int,
        warningThreshold: Int,
        maxHours: Int,
        presentationTimeSeconds: Double?
    ) {
        let enqueue = enqueueMicCapture(
            samples,
            maximumTotalSamples: sampleLimit,
            presentationTimeSeconds: presentationTimeSeconds
        )
        let count = enqueue.timelineSampleCount
        let atLimit = count >= sampleLimit
        let (shouldNotify, shouldWarn) = limitLock.withLock {
            let shouldNotify = atLimit && !maxDurationNotified
            if shouldNotify { maxDurationNotified = true }
            let shouldWarn = !warningFired && count >= warningThreshold
            if shouldWarn { warningFired = true }
            return (shouldNotify, shouldWarn)
        }
        if shouldWarn {
            let remaining = Self.remainingSeconds(
                maxHours: maxHours,
                sampleCount: count,
                sampleRate: sampleRate
            )
            captureEventQueue.async { [weak self] in
                self?.onMaxDurationWarning?(remaining)
            }
        }
        if shouldNotify {
            captureEventQueue.async { [weak self] in
                self?.onMaxDuration?()
            }
        }
    }

    private func handleCaptureDegraded(channel: String, reason: String) {
        captureEventQueue.async { [weak self] in
            self?.handleCaptureDegradedOffCallback(channel: channel, reason: reason)
        }
    }

    private func handleCaptureDegradedOffCallback(channel: String, reason: String) {
        let first = captureLock.withLock { degradedChannels.insert(channel).inserted }
        guard first else { return }
        NSLog("[Voicely] %@ call capture degraded: %@", channel, reason)
        onCaptureDegraded?(channel)
        if let captureURL = captureLock.withLock({ pendingCaptureHandle?.systemFileURL }),
           let free = Self.freeBytes(at: captureURL),
           free < Self.spillMinFreeBytes {
            onDiskSpillStopped?(free)
        }
    }

    private func finalizeCaptureWriters() -> (
        mic: CallCaptureWAVWriter.Snapshot?,
        system: CallCaptureWAVWriter.Snapshot?
    ) {
        let writers = captureLock.withLock { () -> (
            CallCaptureWAVWriter?,
            CallCaptureWAVWriter?
        ) in
            let mic = micCaptureWriter
            let system = systemCaptureWriter
            micCaptureWriter = nil
            systemCaptureWriter = nil
            return (mic, system)
        }
        let mic = writers.0?.finish()
        let system = writers.1?.finish()
        return (mic, system)
    }

    private func markRecoveryCaptured(
        mic: CallCaptureWAVWriter.Snapshot?,
        system: CallCaptureWAVWriter.Snapshot?
    ) {
        // A second stop/termination pass must not overwrite a previously
        // finalized marker with nil channel metadata after writer ownership was
        // already handed off.
        guard mic != nil || system != nil else { return }
        guard let store = captureLock.withLock({ pendingCaptureStore }),
              let handle = captureLock.withLock({ pendingCaptureHandle }) else { return }
        do {
            try store.markCaptured(
                handle,
                mic: mic.map(Self.pendingChannelMetadata),
                system: system.map(Self.pendingChannelMetadata)
            )
        } catch {
            NSLog("[Voicely] Failed to finalize call recovery marker: %@", error.localizedDescription)
        }
    }

    private static func pendingChannelMetadata(
        _ snapshot: CallCaptureWAVWriter.Snapshot
    ) -> PendingCallChannelMetadata {
        PendingCallChannelMetadata(
            sampleRate: snapshot.sampleRate,
            sampleCount: snapshot.sampleCount,
            droppedSampleCount: snapshot.droppedSampleCount,
            zeroFilledSampleCount: snapshot.zeroFilledSampleCount,
            timelineOriginOffsetSeconds: snapshot.timelineOriginOffsetSeconds,
            maxClockDriftSeconds: snapshot.maxClockDriftSeconds,
            discontinuityCount: snapshot.discontinuityCount,
            isDegraded: snapshot.isDegraded,
            failure: snapshot.failure ?? snapshot.timelineIssue
        )
    }

    /// APFS-aware free space at the spill file's volume; nil if unreadable.
    private static func freeBytes(at url: URL) -> UInt64? {
        let dir = url.deletingLastPathComponent()
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(0, cap))
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path),
           let free = attrs[.systemFreeSize] as? UInt64 {
            return free
        }
        return nil
    }

    private static func monotonicHostTimeSeconds() -> Double? {
        let seconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        return seconds.isFinite ? seconds : nil
    }

    // Sync helpers to avoid NSLock in async context (Swift 6)
    private func setMicSampleRate(_ rate: Double) {
        sampleRateLock.lock()
        micSampleRate = rate
        sampleRateLock.unlock()
    }

    private func getSampleRates() -> (mic: Double, system: Double) {
        sampleRateLock.lock()
        let mic = micSampleRate
        let sys = systemSampleRate
        sampleRateLock.unlock()
        return (mic, sys)
    }

    nonisolated static func sampleLimit(maxHours: Int, sampleRate: Double) -> Int {
        guard maxHours > 0,
              CallCaptureWAVWriter.isSupportedSampleRate(sampleRate) else { return 0 }
        let value = Double(maxHours) * 3_600 * sampleRate
        guard value < Double(Int.max) else {
            return CallCaptureWAVWriter.maximumPCM16SampleCount
        }
        return min(
            Int(value.rounded(.down)),
            CallCaptureWAVWriter.maximumPCM16SampleCount
        )
    }

    nonisolated static func warningSampleThreshold(
        maxHours: Int,
        sampleRate: Double,
        warningLeadSeconds: Int = 5 * 60
    ) -> Int {
        guard maxHours > 0,
              CallCaptureWAVWriter.isSupportedSampleRate(sampleRate) else { return 0 }
        let limit = sampleLimit(maxHours: maxHours, sampleRate: sampleRate)
        let lead = Int((Double(max(0, warningLeadSeconds)) * sampleRate).rounded(.down))
        return max(0, limit - lead)
    }

    nonisolated static func remainingSeconds(
        maxHours: Int,
        sampleCount: Int,
        sampleRate: Double
    ) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let remainingSamples = max(0, sampleLimit(maxHours: maxHours, sampleRate: sampleRate) - sampleCount)
        return Int((Double(remainingSamples) / sampleRate).rounded(.down))
    }

    nonisolated static func analyzeChannelCapture(
        samples: [Float],
        sampleRate: Double
    ) -> ChannelCaptureTruth {
        let durationSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        guard !samples.isEmpty else {
            return ChannelCaptureTruth(
                sampleCount: 0,
                sampleRate: sampleRate,
                durationSeconds: durationSeconds,
                rms: 0,
                peakAmplitude: 0,
                meanVolumeDBFS: dbfs(forAmplitude: 0),
                peakVolumeDBFS: dbfs(forAmplitude: 0),
                isEffectivelySilent: true
            )
        }

        var sumSquares = 0.0
        var peak = 0.0
        for sample in samples {
            let value = Double(sample)
            let magnitude = abs(value)
            sumSquares += value * value
            if magnitude > peak {
                peak = magnitude
            }
        }
        let rms = sqrt(sumSquares / Double(samples.count))
        let meanVolumeDBFS = dbfs(forAmplitude: rms)
        let peakVolumeDBFS = dbfs(forAmplitude: peak)
        let isEffectivelySilent = peak == 0 || (
            durationSeconds >= effectiveSilenceMinimumDurationSeconds &&
            meanVolumeDBFS <= effectiveSilenceMeanVolumeFloorDBFS &&
            peakVolumeDBFS <= effectiveSilencePeakVolumeFloorDBFS
        )
        return ChannelCaptureTruth(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            durationSeconds: durationSeconds,
            rms: rms,
            peakAmplitude: peak,
            meanVolumeDBFS: meanVolumeDBFS,
            peakVolumeDBFS: peakVolumeDBFS,
            isEffectivelySilent: isEffectivelySilent
        )
    }

    private nonisolated static func analyzeChannelCapture(
        snapshot: CallCaptureWAVWriter.Snapshot?,
        fallbackSampleRate: Double
    ) -> ChannelCaptureTruth {
        guard let snapshot else {
            return ChannelCaptureTruth(
                sampleCount: 0,
                sampleRate: fallbackSampleRate,
                durationSeconds: 0,
                rms: 0,
                peakAmplitude: 0,
                meanVolumeDBFS: dbfs(forAmplitude: 0),
                peakVolumeDBFS: dbfs(forAmplitude: 0),
                isEffectivelySilent: true,
                isDegraded: false
            )
        }
        let duration = snapshot.sampleRate > 0
            ? Double(snapshot.sampleCount) / snapshot.sampleRate
            : 0
        let rms = snapshot.sampleCount > 0
            ? sqrt(snapshot.sumSquares / Double(snapshot.sampleCount))
            : 0
        let meanDBFS = dbfs(forAmplitude: rms)
        let peakDBFS = dbfs(forAmplitude: snapshot.peakAmplitude)
        let silent = snapshot.peakAmplitude == 0 || (
            duration >= effectiveSilenceMinimumDurationSeconds &&
            meanDBFS <= effectiveSilenceMeanVolumeFloorDBFS &&
            peakDBFS <= effectiveSilencePeakVolumeFloorDBFS
        )
        return ChannelCaptureTruth(
            sampleCount: snapshot.sampleCount,
            sampleRate: snapshot.sampleRate,
            durationSeconds: duration,
            rms: rms,
            peakAmplitude: snapshot.peakAmplitude,
            meanVolumeDBFS: meanDBFS,
            peakVolumeDBFS: peakDBFS,
            isEffectivelySilent: silent,
            droppedSampleCount: snapshot.droppedSampleCount,
            zeroFilledSampleCount: snapshot.zeroFilledSampleCount,
            timelineOriginOffsetSeconds: snapshot.timelineOriginOffsetSeconds,
            maxClockDriftSeconds: snapshot.maxClockDriftSeconds,
            discontinuityCount: snapshot.discontinuityCount,
            failure: snapshot.failure ?? snapshot.timelineIssue,
            isDegraded: snapshot.isDegraded
        )
    }

    private nonisolated static func dbfs(forAmplitude amplitude: Double) -> Double {
        guard amplitude > 0 else { return -160 }
        return max(-160, 20 * log10(amplitude))
    }

}

/// Lock-protected lifecycle truth shared by the producer callbacks and the
/// asynchronous stop/finalize path. The first interruption that happens after
/// publication remains latched until `beginStop()` snapshots it.
final class CallRecorderLifecycleState: @unchecked Sendable {
    struct Publication: Sendable, Equatable {
        let healthy: Bool
        let pendingInterruption: String?
    }

    enum StartHandoffStatus: Sendable, Equatable {
        case healthy
        case interrupted(String)
        case notRunning
    }

    private enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var pendingStartInterruption: String?
    private var captureInterruptionReason: String?

    var isRunning: Bool {
        lock.withLock { phase == .running }
    }

    func beginStart() -> Bool {
        lock.withLock {
            guard phase == .idle else { return false }
            phase = .starting
            pendingStartInterruption = nil
            captureInterruptionReason = nil
            return true
        }
    }

    func publishRunningIfHealthy() -> Publication {
        lock.withLock {
            guard phase == .starting, pendingStartInterruption == nil else {
                return Publication(
                    healthy: false,
                    pendingInterruption: pendingStartInterruption
                )
            }
            phase = .running
            return Publication(healthy: true, pendingInterruption: nil)
        }
    }

    /// Snapshots recorder health at the app-state handoff boundary. Runtime
    /// interruption truth stays visible after producer cleanup moves the phase
    /// to `.stopping`, so the app can still finalize the durable prefix.
    func startHandoffStatus() -> StartHandoffStatus {
        lock.withLock {
            if let captureInterruptionReason {
                return .interrupted(captureInterruptionReason)
            }
            guard phase == .running else { return .notRunning }
            return .healthy
        }
    }

    /// Returns the runtime interruption latched before stop won the lifecycle
    /// race. Callbacks that arrive after this transition are shutdown noise.
    func beginStop() -> String? {
        lock.withLock {
            phase = .stopping
            pendingStartInterruption = nil
            return captureInterruptionReason
        }
    }

    /// SCStream has already stopped its producer. Keep `.stopping` and retain
    /// the reason until the app's normal async stop drains the capture writers.
    func beginStreamDeathCleanup() -> Bool {
        lock.withLock {
            guard phase == .running else { return false }
            phase = .stopping
            return true
        }
    }

    func finishStop() {
        lock.withLock {
            phase = .idle
            pendingStartInterruption = nil
            captureInterruptionReason = nil
        }
    }

    /// Records startup failures separately so they still force transactional
    /// rollback. Runtime failures are reported once and become capture truth.
    func recordInterruption(_ message: String) -> Bool {
        lock.withLock {
            switch phase {
            case .starting:
                if pendingStartInterruption == nil {
                    pendingStartInterruption = message
                }
                return false
            case .running:
                guard captureInterruptionReason == nil else { return false }
                captureInterruptionReason = message
                return true
            case .idle, .stopping:
                return false
            }
        }
    }
}

/// One-shot gate shared by ScreenCaptureKit and microphone interruption paths.
/// Both can report the same route failure, but the app must transition to stop
/// exactly once for a recording session.
final class CallRecorderStreamErrorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    func reset() {
        lock.withLock { claimed = false }
    }
}

// MARK: - Disk-authoritative call capture

/// A bounded asynchronous mono PCM16 WAV writer.
///
/// Audio callbacks enqueue chunks into a fixed-size ring and never perform file
/// I/O. The worker owns the file handle and updates the WAV length fields after
/// every successful batch, leaving a readable prefix after a process crash.
final class CallCaptureWAVWriter: @unchecked Sendable {
    static let maximumInputChunkSamples = 4_096
    static let defaultPendingBufferCount = 32
    static let maximumPCM16SampleCount = Int((UInt64(UInt32.max) - 36) / 2)

    private static let minimumSupportedSampleRate = 8_000.0
    private static let maximumSupportedSampleRate = 384_000.0
    private static let timestampToleranceSeconds = 0.001

    static func isSupportedSampleRate(_ value: Double) -> Bool {
        value.isFinite
            && value >= minimumSupportedSampleRate
            && value <= maximumSupportedSampleRate
    }

    private final class RingSlot: @unchecked Sendable {
        var samples: [Float]
        var count = 0
        var startSamplePosition = 0

        init(capacity: Int) {
            samples = [Float](repeating: 0, count: capacity)
        }
    }

    struct Snapshot: Sendable, Equatable {
        let sampleCount: Int
        let sampleRate: Double
        let sumSquares: Double
        let peakAmplitude: Double
        let droppedSampleCount: Int
        let zeroFilledSampleCount: Int
        let timelineOriginOffsetSeconds: Double
        let maxClockDriftSeconds: Double
        let discontinuityCount: Int
        let ringSampleCapacity: Int
        let peakQueuedBufferCount: Int
        let peakQueuedSampleCount: Int
        let failure: String?
        let timelineIssue: String?

        var isDegraded: Bool {
            droppedSampleCount > 0 || failure != nil || timelineIssue != nil
        }
    }

    struct EnqueueResult: Sendable, Equatable {
        let acceptedSampleCount: Int
        let droppedSampleCount: Int
        let timelineSampleCount: Int
        let becameDegraded: Bool
    }

    enum WriterError: Error, LocalizedError {
        case invalidSampleRate(Double)
        case createFailed(String)
        case closed
        case wavSizeLimit

        var errorDescription: String? {
            switch self {
            case let .invalidSampleRate(rate):
                return "Invalid capture sample rate: \(rate)"
            case let .createFailed(detail):
                return "Could not create call capture file. \(detail)"
            case .closed:
                return "Call capture writer is closed."
            case .wavSizeLimit:
                return "Call capture exceeded the WAV size limit."
            }
        }
    }

    let url: URL
    let sampleRate: Double

    private let lock = NSLock()
    private let worker: DispatchQueue
    private let ring: [RingSlot]
    private var head = 0
    private var tail = 0
    private var queuedBufferCount = 0
    private var queuedSampleCount = 0
    private var peakQueuedBufferCount = 0
    private var peakQueuedSampleCount = 0
    private var drainScheduled = false
    private var accepting = true
    private var handle: FileHandle?
    private var acceptedSampleCount = 0
    /// End of the source timeline seen by enqueue, including leading alignment
    /// and input frames replaced with silence under backpressure.
    private var timelineInputEndSample = 0
    private var writtenSampleCount = 0
    private var droppedSampleCount = 0
    private var zeroFilledSampleCount = 0
    private var sumSquares = 0.0
    private var peakAmplitude = 0.0
    private var failure: String?
    private var degradationReported = false
    private let artificialWriteDelay: TimeInterval
    private let minimumFreeBytes: UInt64?
    private var writtenBatchCount = 0
    private let onDegraded: (@Sendable (String) -> Void)?
    private let timelineOriginSeconds: Double?
    private var firstPresentationTimeSeconds: Double?
    private var firstTimelineSamplePosition = 0
    private var timelineOriginOffsetSeconds = 0.0
    private var maxClockDriftSeconds = 0.0
    private var discontinuityCount = 0
    private var timelineIssue: String?

    init(
        url: URL,
        sampleRate: Double,
        ownedFileDescriptor: Int32? = nil,
        pendingBufferCount: Int = defaultPendingBufferCount,
        artificialWriteDelay: TimeInterval = 0,
        minimumFreeBytes: UInt64? = nil,
        timelineOriginSeconds: Double? = nil,
        onDegraded: (@Sendable (String) -> Void)? = nil
    ) throws {
        guard Self.isSupportedSampleRate(sampleRate) else {
            if let ownedFileDescriptor { Darwin.close(ownedFileDescriptor) }
            throw WriterError.invalidSampleRate(sampleRate)
        }
        self.url = url
        self.sampleRate = sampleRate
        self.ring = (0..<max(1, pendingBufferCount)).map { _ in
            RingSlot(capacity: Self.maximumInputChunkSamples)
        }
        self.worker = DispatchQueue(
            label: "voicely.call-capture.\(url.lastPathComponent)",
            qos: .utility
        )
        self.artificialWriteDelay = max(0, artificialWriteDelay)
        self.minimumFreeBytes = minimumFreeBytes
        self.timelineOriginSeconds = timelineOriginSeconds.flatMap {
            $0.isFinite ? $0 : nil
        }
        self.onDegraded = onDegraded

        if let ownedFileDescriptor {
            var closeDescriptor = true
            defer {
                if closeDescriptor { Darwin.close(ownedFileDescriptor) }
            }
            try Self.initializeOwnedDescriptor(
                ownedFileDescriptor,
                sampleRate: sampleRate
            )
            self.handle = FileHandle(
                fileDescriptor: ownedFileDescriptor,
                closeOnDealloc: true
            )
            closeDescriptor = false
        } else {
            do {
                let fm = FileManager.default
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard fm.createFile(atPath: url.path, contents: Self.wavHeader(
                    sampleRate: sampleRate,
                    dataByteCount: 0
                )) else {
                    throw WriterError.createFailed("createFile returned false")
                }
                self.handle = try FileHandle(forUpdating: url)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch let error as WriterError {
                throw error
            } catch {
                throw WriterError.createFailed(error.localizedDescription)
            }
        }
    }

    /// Enqueue at most `maximumTotalSamples` on a monotonic source timeline.
    /// A saturated ring loses payload, but the source position still advances;
    /// the worker writes zero PCM for that exact interval so later timestamps do
    /// not move earlier.
    func enqueue(
        _ samples: [Float],
        maximumTotalSamples: Int = .max,
        presentationTimeSeconds: Double? = nil
    ) -> EnqueueResult {
        samples.withUnsafeBufferPointer {
            enqueue(
                $0,
                maximumTotalSamples: maximumTotalSamples,
                presentationTimeSeconds: presentationTimeSeconds
            )
        }
    }

    func enqueue(
        _ samples: UnsafeBufferPointer<Float>,
        maximumTotalSamples: Int,
        presentationTimeSeconds: Double?
    ) -> EnqueueResult {
        guard samples.count > 0 else {
            return lock.withLock {
                EnqueueResult(
                    acceptedSampleCount: acceptedSampleCount,
                    droppedSampleCount: droppedSampleCount,
                    timelineSampleCount: timelineInputEndSample,
                    becameDegraded: false
                )
            }
        }

        var shouldSchedule = false
        var report: String?
        let result = lock.withLock { () -> EnqueueResult in
            let wasDegraded = isDegradedLocked
            guard accepting, failure == nil else {
                droppedSampleCount += samples.count
                let became = !wasDegraded
                if became { report = failure ?? WriterError.closed.localizedDescription }
                return EnqueueResult(
                    acceptedSampleCount: acceptedSampleCount,
                    droppedSampleCount: droppedSampleCount,
                    timelineSampleCount: timelineInputEndSample,
                    becameDegraded: became
                )
            }

            let hardLimit = min(
                max(0, maximumTotalSamples),
                Self.maximumPCM16SampleCount
            )
            let presentationStart = timelineStartPositionLocked(
                presentationTimeSeconds: presentationTimeSeconds,
                hardLimit: hardLimit,
                report: &report
            )
            if presentationStart > timelineInputEndSample {
                timelineInputEndSample = presentationStart
            }

            var offset = 0
            while offset < samples.count {
                let remainingCapacity = max(0, hardLimit - timelineInputEndSample)
                guard remainingCapacity > 0 else {
                    droppedSampleCount += samples.count - offset
                    break
                }

                let count = min(
                    Self.maximumInputChunkSamples,
                    samples.count - offset,
                    remainingCapacity
                )
                let startPosition = timelineInputEndSample
                if queuedBufferCount < ring.count {
                    let slot = ring[tail]
                    for index in 0..<count {
                        slot.samples[index] = samples[offset + index]
                    }
                    slot.count = count
                    slot.startSamplePosition = startPosition
                    tail = (tail + 1) % ring.count
                    queuedBufferCount += 1
                    queuedSampleCount += count
                    peakQueuedBufferCount = max(peakQueuedBufferCount, queuedBufferCount)
                    peakQueuedSampleCount = max(peakQueuedSampleCount, queuedSampleCount)
                    acceptedSampleCount += count
                } else {
                    droppedSampleCount += count
                }
                timelineInputEndSample += count
                offset += count
            }

            if !drainScheduled, queuedBufferCount > 0 {
                drainScheduled = true
                shouldSchedule = true
            }
            let isDegraded = isDegradedLocked
            let became = !wasDegraded && isDegraded
            if became, report == nil {
                report = "Call capture queue saturated; audio frames were dropped."
            }
            return EnqueueResult(
                acceptedSampleCount: acceptedSampleCount,
                droppedSampleCount: droppedSampleCount,
                timelineSampleCount: timelineInputEndSample,
                becameDegraded: became
            )
        }

        if shouldSchedule {
            worker.async { [weak self] in self?.drain() }
        }
        if let report {
            // Never run logging, filesystem checks, or UI-facing callbacks on
            // the audio callback thread.
            worker.async { [weak self] in self?.reportDegradationOnce(report) }
        }
        return result
    }

    /// Stop accepting frames, drain the worker, finalize the header, and close.
    func finish() -> Snapshot {
        lock.withLock { accepting = false }
        worker.sync {
            drain()
            do {
                try writePendingTimelineTail()
                try handle?.synchronize()
                try handle?.close()
            } catch {
                markFailure(error.localizedDescription)
            }
            handle = nil
        }
        return snapshot()
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                sampleCount: writtenSampleCount,
                sampleRate: sampleRate,
                sumSquares: sumSquares,
                peakAmplitude: peakAmplitude,
                droppedSampleCount: droppedSampleCount,
                zeroFilledSampleCount: zeroFilledSampleCount,
                timelineOriginOffsetSeconds: timelineOriginOffsetSeconds,
                maxClockDriftSeconds: maxClockDriftSeconds,
                discontinuityCount: discontinuityCount,
                ringSampleCapacity: ring.count * Self.maximumInputChunkSamples,
                peakQueuedBufferCount: peakQueuedBufferCount,
                peakQueuedSampleCount: peakQueuedSampleCount,
                failure: failure,
                timelineIssue: timelineIssue
            )
        }
    }

    private func drain() {
        while let slot = peekNextSlot() {
            do {
                if artificialWriteDelay > 0 {
                    Thread.sleep(forTimeInterval: artificialWriteDelay)
                }
                try write(slot)
                consume(slot)
            } catch {
                // The failed head remains in the ring and is counted together
                // with every later queued slot by discardQueuedAfterFailure().
                markFailure(error.localizedDescription)
                discardQueuedAfterFailure()
                return
            }
        }
    }

    private func peekNextSlot() -> RingSlot? {
        lock.withLock {
            guard queuedBufferCount > 0 else {
                drainScheduled = false
                return nil
            }
            return ring[head]
        }
    }

    private func consume(_ slot: RingSlot) {
        lock.withLock {
            guard queuedBufferCount > 0, ring[head] === slot else { return }
            queuedSampleCount -= slot.count
            slot.count = 0
            head = (head + 1) % ring.count
            queuedBufferCount -= 1
        }
    }

    private func write(_ slot: RingSlot) throws {
        guard let handle else { throw WriterError.closed }
        writtenBatchCount += 1
        if writtenBatchCount == 1 || writtenBatchCount.isMultiple(of: 64),
           let minimumFreeBytes,
           let free = Self.freeBytes(at: url),
           free < minimumFreeBytes {
            throw WriterError.createFailed(
                "Low disk space: \(free / (1024 * 1024)) MB free"
            )
        }

        let currentPosition = lock.withLock { writtenSampleCount }
        if slot.startSamplePosition > currentPosition {
            try writeSilence(sampleCount: slot.startSamplePosition - currentPosition)
        }

        let updatedPosition = lock.withLock { writtenSampleCount }
        let overlap = max(0, updatedPosition - slot.startSamplePosition)
        guard overlap < slot.count else {
            lock.withLock {
                droppedSampleCount += slot.count
                setTimelineIssueLocked("Overlapping capture timestamps discarded a complete audio block.")
            }
            return
        }

        var pcm = [Int16]()
        pcm.reserveCapacity(slot.count - overlap)
        var batchSquares = 0.0
        var batchPeak = 0.0
        var invalidSampleCount = 0
        for index in overlap..<slot.count {
            let rawValue = slot.samples[index]
            let value = rawValue.isFinite ? Double(rawValue) : 0
            if !rawValue.isFinite { invalidSampleCount += 1 }
            batchSquares += value * value
            batchPeak = max(batchPeak, abs(value))
            let clamped = max(-1.0, min(1.0, value))
            let scaled = clamped < 0 ? clamped * 32_768.0 : clamped * 32_767.0
            pcm.append(Int16(scaled.rounded()).littleEndian)
        }

        let previousCount = lock.withLock { writtenSampleCount }
        let newCount = previousCount + pcm.count
        let dataBytes64 = UInt64(newCount) * UInt64(MemoryLayout<Int16>.size)
        guard dataBytes64 <= UInt64(UInt32.max - 36) else {
            throw WriterError.wavSizeLimit
        }

        try handle.seekToEnd()
        try pcm.withUnsafeBytes { raw in
            try handle.write(contentsOf: raw)
        }
        try Self.updateWAVHeader(
            handle: handle,
            dataByteCount: UInt32(dataBytes64)
        )

        lock.withLock {
            writtenSampleCount = newCount
            sumSquares += batchSquares
            peakAmplitude = max(peakAmplitude, batchPeak)
            if overlap > 0 {
                droppedSampleCount += overlap
                setTimelineIssueLocked("Overlapping capture timestamps required audio trimming.")
            }
            if invalidSampleCount > 0 {
                droppedSampleCount += invalidSampleCount
                zeroFilledSampleCount += invalidSampleCount
                setTimelineIssueLocked("Non-finite capture samples were replaced with silence.")
            }
        }
        if invalidSampleCount > 0 {
            reportDegradationOnce("Non-finite capture samples were replaced with silence.")
        }
    }

    private func writePendingTimelineTail() throws {
        let (target, canWrite) = lock.withLock {
            (timelineInputEndSample, failure == nil)
        }
        guard canWrite else { return }
        let current = lock.withLock { writtenSampleCount }
        if target > current {
            try writeSilence(sampleCount: target - current)
        }
    }

    private func writeSilence(sampleCount: Int) throws {
        guard sampleCount > 0, let handle else { return }
        let previousCount = lock.withLock { writtenSampleCount }
        let newCount = previousCount + sampleCount
        let dataBytes64 = UInt64(newCount) * UInt64(MemoryLayout<Int16>.size)
        guard dataBytes64 <= UInt64(UInt32.max - 36) else {
            throw WriterError.wavSizeLimit
        }
        var remaining = sampleCount
        let zeroChunk = [UInt8](
            repeating: 0,
            count: Self.maximumInputChunkSamples * MemoryLayout<Int16>.size
        )
        try handle.seekToEnd()
        while remaining > 0 {
            let count = min(remaining, Self.maximumInputChunkSamples)
            try zeroChunk.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(
                    start: raw.baseAddress,
                    count: count * MemoryLayout<Int16>.size
                )
                try handle.write(contentsOf: bytes)
            }
            remaining -= count
        }
        try Self.updateWAVHeader(
            handle: handle,
            dataByteCount: UInt32(dataBytes64)
        )
        lock.withLock {
            writtenSampleCount = newCount
            zeroFilledSampleCount += sampleCount
        }
    }

    private var isDegradedLocked: Bool {
        droppedSampleCount > 0 || failure != nil || timelineIssue != nil
    }

    /// Establish the shared origin on the first buffer and detect later clock
    /// discontinuities. Positive timestamp gaps advance the file position; the
    /// worker then writes silence for the missing interval. Negative overlap is
    /// marked degraded and kept monotonic rather than moving audio backwards.
    private func timelineStartPositionLocked(
        presentationTimeSeconds: Double?,
        hardLimit: Int,
        report: inout String?
    ) -> Int {
        guard let presentationTimeSeconds,
              presentationTimeSeconds.isFinite else {
            if timelineOriginSeconds != nil, firstPresentationTimeSeconds == nil {
                setTimelineIssueLocked("Capture timestamp unavailable; channel alignment is unverified.")
                report = timelineIssue
            }
            return timelineInputEndSample
        }

        if firstPresentationTimeSeconds == nil {
            firstPresentationTimeSeconds = presentationTimeSeconds
            if let origin = timelineOriginSeconds {
                let offset = presentationTimeSeconds - origin
                guard offset.isFinite, offset >= -0.05, offset <= 60 else {
                    setTimelineIssueLocked("Capture timestamp did not share the session host-time origin.")
                    report = timelineIssue
                    return timelineInputEndSample
                }
                timelineOriginOffsetSeconds = max(0, offset)
                let samples = Int((timelineOriginOffsetSeconds * sampleRate).rounded())
                firstTimelineSamplePosition = min(hardLimit, max(0, samples))
                return max(timelineInputEndSample, firstTimelineSamplePosition)
            }
            firstTimelineSamplePosition = timelineInputEndSample
            return timelineInputEndSample
        }

        guard let firstPresentationTimeSeconds else { return timelineInputEndSample }
        let expectedTime = firstPresentationTimeSeconds
            + Double(timelineInputEndSample - firstTimelineSamplePosition) / sampleRate
        let drift = presentationTimeSeconds - expectedTime
        guard drift.isFinite else {
            maxClockDriftSeconds = max(
                maxClockDriftSeconds,
                Double(hardLimit) / sampleRate
            )
            discontinuityCount += 1
            setTimelineIssueLocked("Capture clock discontinuity exceeded the bounded recording timeline.")
            report = timelineIssue
            return presentationTimeSeconds > expectedTime
                ? hardLimit
                : timelineInputEndSample
        }
        maxClockDriftSeconds = max(maxClockDriftSeconds, abs(drift))
        guard abs(drift) > Self.timestampToleranceSeconds else {
            return timelineInputEndSample
        }

        discontinuityCount += 1
        setTimelineIssueLocked("Capture clock discontinuity detected; timeline alignment is degraded.")
        report = timelineIssue
        if drift > 0 {
            let timestampOffset = (
                (presentationTimeSeconds - firstPresentationTimeSeconds) * sampleRate
            ).rounded()
            guard timestampOffset.isFinite else { return hardLimit }
            if timestampOffset >= Double(hardLimit) { return hardLimit }
            if timestampOffset <= 0 { return timelineInputEndSample }
            let timestampPosition = firstTimelineSamplePosition + Int(timestampOffset)
            return min(hardLimit, max(timelineInputEndSample, timestampPosition))
        }
        return timelineInputEndSample
    }

    private func setTimelineIssueLocked(_ message: String) {
        if timelineIssue == nil { timelineIssue = message }
    }

    private func markFailure(_ message: String, failedBatchCount: Int = 0) {
        let shouldReport = lock.withLock { () -> Bool in
            if failure == nil { failure = message }
            accepting = false
            droppedSampleCount += failedBatchCount
            let should = !degradationReported
            degradationReported = true
            return should
        }
        if shouldReport { onDegraded?(message) }
    }

    private func discardQueuedAfterFailure() {
        lock.withLock {
            for slot in ring where slot.count > 0 {
                droppedSampleCount += slot.count
                slot.count = 0
            }
            queuedBufferCount = 0
            queuedSampleCount = 0
            head = 0
            tail = 0
            drainScheduled = false
        }
    }

    private func reportDegradationOnce(_ message: String) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !degradationReported else { return false }
            degradationReported = true
            return true
        }
        if shouldReport { onDegraded?(message) }
    }

    private static func wavHeader(sampleRate: Double, dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        let rate = UInt32(sampleRate.rounded())
        data.appendLittleEndian(rate)
        data.appendLittleEndian(rate * UInt32(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(16))
        data.append("data".data(using: .ascii)!)
        data.appendLittleEndian(dataByteCount)
        return data
    }

    private static func updateWAVHeader(
        handle: FileHandle,
        dataByteCount: UInt32
    ) throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(littleEndian: UInt32(36) + dataByteCount))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(littleEndian: dataByteCount))
        try handle.seekToEnd()
    }

    /// Takes ownership of a securely preopened, empty regular file. Callers can
    /// create it with `openat(..., O_EXCL | O_NOFOLLOW)` and keep the writer on
    /// that pinned inode for its entire lifetime.
    private static func initializeOwnedDescriptor(
        _ fd: Int32,
        sampleRate: Double
    ) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size == 0 else {
            throw WriterError.createFailed(
                "preopened descriptor must be an empty, owner-matched, single-link regular file"
            )
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw WriterError.createFailed(
                "could not secure preopened descriptor: \(String(cString: strerror(errno)))"
            )
        }
        let header = wavHeader(sampleRate: sampleRate, dataByteCount: 0)
        var offset = 0
        while offset < header.count {
            let count = header.withUnsafeBytes { bytes in
                pwrite(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    header.count - offset,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw WriterError.createFailed(
                    "could not initialize preopened descriptor: \(String(cString: strerror(errno)))"
                )
            }
            offset += count
        }
        guard fsync(fd) == 0 else {
            throw WriterError.createFailed(
                "could not sync preopened descriptor: \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func freeBytes(at url: URL) -> UInt64? {
        let directory = url.deletingLastPathComponent()
        if let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(0, capacity))
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: directory.path
        ), let free = attributes[.systemFreeSize] as? UInt64 {
            return free
        }
        return nil
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    init<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        self = Swift.withUnsafeBytes(of: &little) { Data($0) }
    }
}

// MARK: - Stream Delegate

/// Reusable scratch storage for microphone downmixing. AVAudioEngine invokes a
/// tap serially, so one preallocated buffer removes per-callback heap growth.
private final class CallMicMixBuffer: @unchecked Sendable {
    private var samples: [Float]

    init(capacity: Int) {
        samples = [Float](repeating: 0, count: max(1, capacity))
    }

    func withMixedSamples(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        offset: Int,
        count: Int,
        body: (UnsafeBufferPointer<Float>) -> Void
    ) {
        guard channelCount > 0, count > 0, count <= samples.count else { return }
        for index in 0..<count { samples[index] = 0 }
        let gain = 1 / Float(channelCount)
        for channel in 0..<channelCount {
            let source = channelData[channel] + offset
            for index in 0..<count {
                samples[index] += source[index] * gain
            }
        }
        samples.withUnsafeBufferPointer { buffer in
            body(UnsafeBufferPointer(rebasing: buffer[..<count]))
        }
    }
}

private final class CallStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The sample pointer is borrowed only for the synchronous callback. The
    /// writer copies it directly into a preallocated ring slot before returning.
    let onSamples: (UnsafeBufferPointer<Float>, Double, Double?) -> Void
    let onError: ((String) -> Void)?
    var onStreamDied: (() -> Void)?
    private let formatErrorLock = NSLock()
    private var formatErrorReported = false

    init(
        onSamples: @escaping (UnsafeBufferPointer<Float>, Double, Double?) -> Void,
        onError: ((String) -> Void)? = nil
    ) {
        self.onSamples = onSamples
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "Screen recording stream stopped: \(error.localizedDescription)"
        NSLog("[Voicely] %@", message)
        onError?(message)
        onStreamDied?()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let desc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              desc.mFormatID == kAudioFormatLinearPCM,
              desc.mChannelsPerFrame == 1,
              desc.mBitsPerChannel == 32,
              desc.mBytesPerFrame == MemoryLayout<Float>.size,
              desc.mFramesPerPacket == 1,
              desc.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              desc.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              CallCaptureWAVWriter.isSupportedSampleRate(desc.mSampleRate),
              abs(desc.mSampleRate - 48_000) < 0.5 else {
            reportFormatErrorOnce("Screen capture returned an unsupported audio format.")
            return
        }
        let sampleRate = desc.mSampleRate

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == 0,
              let data = dataPointer,
              length > 0,
              length.isMultiple(of: MemoryLayout<Float>.size) else {
            reportFormatErrorOnce("Screen capture returned a non-contiguous audio buffer.")
            return
        }

        let floatCount = length / MemoryLayout<Float>.size
        let ptsSeconds = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        let presentationTimeSeconds = ptsSeconds.isFinite ? ptsSeconds : nil
        data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            var offset = 0
            while offset < floatCount {
                let count = min(
                    CallCaptureWAVWriter.maximumInputChunkSamples,
                    floatCount - offset
                )
                onSamples(
                    UnsafeBufferPointer(start: ptr + offset, count: count),
                    sampleRate,
                    presentationTimeSeconds.map {
                        $0 + Double(offset) / sampleRate
                    }
                )
                offset += count
            }
        }
    }

    private func reportFormatErrorOnce(_ message: String) {
        let shouldReport = formatErrorLock.withLock {
            guard !formatErrorReported else { return false }
            formatErrorReported = true
            return true
        }
        if shouldReport { onError?(message) }
    }
}

// MARK: - Errors

enum CallRecorderError: Error, LocalizedError {
    case noDisplay
    case noAudio
    case alreadyRunning
    case captureStorageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for screen capture"
        case .noAudio: return "No audio captured"
        case .alreadyRunning: return "Call recording is already running"
        case let .captureStorageUnavailable(detail):
            return "Call capture storage is unavailable. \(detail)"
        }
    }
}
