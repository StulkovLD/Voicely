import AVFoundation
import CoreAudioTypes
import Foundation
import ScreenCaptureKit

/// Records both system audio (call participants) and microphone (you) as separate channels
final class CallRecorder: @unchecked Sendable {
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onMaxDuration: (@Sendable () -> Void)?
    var onMaxDurationWarning: (@Sendable (Int) -> Void)?
    var onStreamError: (@Sendable (String) -> Void)?
    /// Fired once when the on-disk system-channel spill is disabled because the
    /// volume ran low. RAM capture continues; only the diarization spill stops.
    /// Carries the free-bytes figure that tripped the guard.
    var onDiskSpillStopped: (@Sendable (UInt64) -> Void)?

    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var delegate: CallStreamDelegate?

    // MARK: - System-channel disk spill (N2b prerequisite)

    /// Stable identifier for this call, used as the spill folder name. Set in
    /// `start()`; nil before the first start. Read on main after stop().
    private(set) var callId: String?

    /// Full path to the streamed system.wav once the call has stopped (or nil
    /// if the spill never started / was disabled). The file holds the COMPLETE
    /// `other` channel at 48 kHz mono, written incrementally during the call so
    /// diarization (N2b) can do an offline one-pass over the full channel from
    /// disk without re-holding it all in RAM.
    private(set) var systemWavURL: URL?

    /// Lazily-opened streaming WAV writer for the system channel. Touched only
    /// under `spillLock` plus the dedicated flush queue (never the audio thread
    /// directly — see `spillPending`).
    private let spillLock = NSLock()
    private var spillFile: AVAudioFile?
    /// Samples captured on the SCStream thread but not yet written to disk.
    /// The audio handler only appends here (cheap); the flush queue drains it.
    private var spillPending: [Float] = []
    /// Once true, the disk spill is permanently off for this call (disk-full or
    /// a write error). RAM capture is unaffected.
    private var spillDisabled = false
    private var diskGuardFired = false
    /// Serialises file I/O off the audio callback so the SCStream thread never
    /// blocks on disk. Buffered samples are drained here.
    private let spillQueue = DispatchQueue(label: "voicely.callrecorder.spill", qos: .utility)
    /// Minimum free bytes required to keep spilling. ~512 MB headroom; one hour
    /// of 48 kHz mono float WAV is ~690 MB, so this stops well before a stall.
    private static let spillMinFreeBytes: UInt64 = 512 * 1024 * 1024

    // Soft cap on recording length, in hours. Defaults to 8 hours (was 2);
    // override via VOICELY_MAX_CALL_HOURS env var. The cap exists only to
    // bound RAM usage (float32 mono 48 kHz ≈ 690 MB / hour) - it is not a
    // product constraint. When the cap is reached we stop accepting NEW
    // samples but keep what we already have; the user can stop manually.
    private static var maxHours: Int {
        if let env = ProcessInfo.processInfo.environment["VOICELY_MAX_CALL_HOURS"],
           let h = Int(env), h > 0, h <= 48 {
            return h
        }
        return 8
    }
    private let maxSamples = CallRecorder.maxHours * 3600 * 48000

    private let systemLock = NSLock()
    private var systemSamples: [Float] = []

    private let micLock = NSLock()
    private var micSamples: [Float] = []

    // Offset-based chunk reading: track how far we've read without removing data.
    // Samples stay in memory for the final WAV save via collectSamples().
    private var systemReadOffset: Int = 0
    private var micReadOffset: Int = 0

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
    private let warningSamples = (CallRecorder.maxHours * 3600 - 5 * 60) * 48000  // 5 min before cap

    struct CallAudio {
        let mic: AVAudioPCMBuffer?
        let system: AVAudioPCMBuffer?
        let micSampleRate: Double
        let systemSampleRate: Double
        let startTime: Date
    }

    struct ChannelChunks {
        let mic: AVAudioPCMBuffer?
        let system: AVAudioPCMBuffer?
    }

    /// Start recording: system audio via ScreenCaptureKit + mic via AVAudioEngine
    func start() async throws {
        guard stream == nil else { throw CallRecorderError.alreadyRunning }
        NSLog("[Voicely] CallRecorder.start() called")
        startTime = Date()
        systemSamples = []
        micSamples = []
        systemReadOffset = 0
        micReadOffset = 0
        setupSystemSpill()
        // Swift 6: NSLock.lock()/unlock() are unavailable across async
        // suspension points. Scoped withLock is async-safe (no suspension
        // inside the critical section).
        limitLock.withLock {
            maxDurationNotified = false
            warningFired = false
        }

        // 1. Get shareable content (we capture entire display audio)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CallRecorderError.noDisplay
        }

        // 2. Configure stream for audio only
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // Don't capture our own app sounds
        config.sampleRate = 48000
        config.channelCount = 1

        // Don't capture video - audio only
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum

        // 3. Create stream with display filter
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        // 4. Set up delegate to receive audio samples (and stream errors)
        let delegate = CallStreamDelegate(onSamples: { [weak self] samples, sampleRate in
            guard let self else { return }
            self.systemLock.lock()
            let count = self.systemSamples.count
            let atLimit = count >= self.maxSamples
            if !atLimit { self.systemSamples.append(contentsOf: samples) }
            self.systemLock.unlock()

            // Spill the system channel to disk for the full-channel diarization
            // pass (N2b). Buffered append here (cheap, lock-guarded); the actual
            // file write happens on spillQueue so this audio thread never blocks.
            if !atLimit { self.enqueueSpill(samples) }

            self.limitLock.lock()
            let shouldNotify = atLimit && !self.maxDurationNotified
            if shouldNotify { self.maxDurationNotified = true }
            let shouldWarn = !self.warningFired && count >= self.warningSamples
            if shouldWarn { self.warningFired = true }
            self.limitLock.unlock()
            let remaining = shouldWarn ? max(0, self.maxSamples - count) / 48000 : 0
            if shouldWarn { self.onMaxDurationWarning?(remaining) }
            if shouldNotify { self.onMaxDuration?(); return }
            self.sampleRateLock.lock()
            self.systemSampleRate = sampleRate
            self.sampleRateLock.unlock()

            // Calculate RMS for visualization
            var rms: Float = 0
            for s in samples { rms += s * s }
            rms = sqrt(rms / max(1, Float(samples.count)))
            self.onAudioLevel?(min(1.0, rms * 8.0))
        }, onError: { [weak self] message in
            self?.onStreamError?(message)
        })
        delegate.onStreamDied = { [weak self] in
            // Runs on the SCStream thread. Hop to main so teardown of micEngine/
            // stream/delegate doesn't race stop()/forceStop(), which mutate the
            // same fields on main.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let engine = self.micEngine {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    self.micEngine = nil
                }
                self.stream = nil
                self.delegate = nil
            }
        }
        self.delegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
        NSLog("[Voicely] SCStream started successfully")

        // 5. Start microphone recording in parallel
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // #92: Validate mic format before installing tap
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[Voicely] Invalid mic format: %.0f Hz, %d ch", format.sampleRate, format.channelCount)
            throw CallRecorderError.noAudio
        }
        NSLog("[Voicely] Mic format: %.0f Hz, %d ch", format.sampleRate, format.channelCount)
        setMicSampleRate(format.sampleRate)
        let micChannelCount = Int(format.channelCount)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = Int(buffer.frameLength)
            guard let floatChannelData = buffer.floatChannelData, frameLength > 0 else { return }
            // Mix all channels to mono (matches Recorder behavior)
            let samples: [Float]
            if micChannelCount == 1 {
                samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
            } else {
                var mixed = [Float](repeating: 0, count: frameLength)
                let gain = 1.0 / Float(micChannelCount)
                for ch in 0..<micChannelCount {
                    let chData = floatChannelData[ch]
                    for i in 0..<frameLength {
                        mixed[i] += chData[i] * gain
                    }
                }
                samples = mixed
            }
            self.micLock.lock()
            let count = self.micSamples.count
            let atLimit = count >= self.maxSamples
            if !atLimit { self.micSamples.append(contentsOf: samples) }
            self.micLock.unlock()

            self.limitLock.lock()
            let shouldNotify = atLimit && !self.maxDurationNotified
            if shouldNotify { self.maxDurationNotified = true }
            let shouldWarn = !self.warningFired && count >= self.warningSamples
            if shouldWarn { self.warningFired = true }
            self.limitLock.unlock()
            let remaining = shouldWarn ? max(0, self.maxSamples - count) / 48000 : 0
            if shouldWarn { self.onMaxDurationWarning?(remaining) }
            if shouldNotify { self.onMaxDuration?() }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            self.micEngine = nil
            if let s = self.stream {
                self.stream = nil
                self.delegate = nil
                try? await s.stopCapture()
            }
            // Close the just-opened spill so a failed start doesn't leak an open
            // file handle while the caller's retry backoff runs (#5).
            finalizeSystemSpill()
            throw error
        }
        self.micEngine = engine

        NSLog("[Voicely] Call recording started (system audio + mic)")
    }

    /// Synchronous cleanup for app termination - releases resources without collecting samples
    func forceStop() {
        // Prevent onStreamDied from racing with cleanup
        delegate?.onStreamDied = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

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

        // Close the spill so the partial system.wav on disk is a valid file
        // even on abrupt termination (best effort, no save of RAM samples).
        finalizeSystemSpill()
    }

    /// Stop recording and return both audio channels (no mixing).
    func stop() async -> CallAudio? {
        // Prevent onStreamDied from racing with stop()
        delegate?.onStreamDied = nil
        // #91: Suppress stale audio level callbacks from in-flight delegate calls
        onAudioLevel = nil

        if let stream = self.stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            micEngine = nil
        }

        // Drain and close the system-channel spill before collecting samples so
        // diarization (N2b) sees the COMPLETE channel on disk. `systemWavURL` is
        // left populated (or nil if spill was disabled / never opened).
        finalizeSystemSpill()

        let (sysSamples, micSamps) = collectSamples()
        NSLog("[Voicely] Collected samples - System: %d, Mic: %d", sysSamples.count, micSamps.count)

        guard !sysSamples.isEmpty || !micSamps.isEmpty else {
            NSLog("[Voicely] Capture failure: both system and mic sample arrays empty. Check Screen Recording permission")
            return nil
        }

        let (micRate, sysRate) = getSampleRates()
        let time = startTime ?? Date()

        let sysBuf = sysSamples.isEmpty ? nil : makePCMBuffer(from: sysSamples, sampleRate: sysRate)
        let micBuf = micSamps.isEmpty ? nil : makePCMBuffer(from: micSamps, sampleRate: micRate)

        NSLog("[Voicely] Call recording stopped. Mic: %d samples, System: %d samples", micSamps.count, sysSamples.count)
        return CallAudio(
            mic: micBuf,
            system: sysBuf,
            micSampleRate: micRate,
            systemSampleRate: sysRate,
            startTime: time
        )
    }

    /// Read `seconds` of new samples from each channel, advance offsets
    /// independently. Each channel takes its OWN sample count from its OWN rate
    /// (system: systemSampleRate * seconds, mic: micSampleRate * seconds) so the
    /// you/other timelines stay aligned even when the mic runs at a native rate
    /// other than 48 kHz (built-in 44.1k, AirPods 16-24k). Non-destructive:
    /// samples stay resident until `collectSamples()` at stop. Either channel may
    /// be nil if it has no fresh data ≥ minSamples.
    ///
    /// `minSamples` is a threshold in samples (not seconds).
    ///
    /// No mixing — downstream AEC and transcription consume channels separately.
    func extractChannelChunks(seconds: Double, minSamples: Int = 8000) -> ChannelChunks {
        let (micRate, sysRate) = getSampleRates()
        let sysCount = samplesFor(seconds: seconds, rate: sysRate)
        let micCount = samplesFor(seconds: seconds, rate: micRate)

        systemLock.lock()
        let sysAvailable = systemSamples.count - systemReadOffset
        let sysTake = min(sysCount, max(0, sysAvailable))
        let sysChunk: [Float]
        if sysTake >= minSamples {
            let end = systemReadOffset + sysTake
            sysChunk = Array(systemSamples[systemReadOffset..<end])
            systemReadOffset = end
        } else {
            sysChunk = []
        }
        systemLock.unlock()

        micLock.lock()
        let micAvailable = micSamples.count - micReadOffset
        let micTake = min(micCount, max(0, micAvailable))
        let micChunk: [Float]
        if micTake >= minSamples {
            let end = micReadOffset + micTake
            micChunk = Array(micSamples[micReadOffset..<end])
            micReadOffset = end
        } else {
            micChunk = []
        }
        micLock.unlock()

        let sysBuf = sysChunk.isEmpty ? nil : makePCMBuffer(from: sysChunk, sampleRate: sysRate)
        let micBuf = micChunk.isEmpty ? nil : makePCMBuffer(from: micChunk, sampleRate: micRate)
        return ChannelChunks(mic: micBuf, system: sysBuf)
    }

    /// Convert a duration in seconds to a sample count at `rate`, clamped to
    /// `Int.max` (avoids a trap when `seconds` is `.greatestFiniteMagnitude`,
    /// used by the tail flush to drain the whole channel).
    private func samplesFor(seconds: Double, rate: Double) -> Int {
        let raw = seconds * rate
        guard raw.isFinite, raw >= 0 else { return 0 }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw)
    }

    /// Tail flush: everything still unread in both channels since the last
    /// `extractChannelChunks` call.
    func extractRemainingChannels() -> ChannelChunks {
        extractChannelChunks(seconds: .greatestFiniteMagnitude, minSamples: 1)
    }

    /// Unread backlog in SECONDS for the lagging channel: the larger of the two
    /// channels' (unread samples / that channel's rate). Used by the chunk loop
    /// to decide whether transcription has fallen behind real-time capture and
    /// it must greedily drain more than one 30 s window to let the offset catch
    /// up. Lock-guarded reads; cheap (no copy).
    func pendingBacklogSeconds() -> Double {
        let (micRate, sysRate) = getSampleRates()

        systemLock.lock()
        let sysUnread = max(0, systemSamples.count - systemReadOffset)
        systemLock.unlock()

        micLock.lock()
        let micUnread = max(0, micSamples.count - micReadOffset)
        micLock.unlock()

        let sysSec = sysRate > 0 ? Double(sysUnread) / sysRate : 0
        let micSec = micRate > 0 ? Double(micUnread) / micRate : 0
        return max(sysSec, micSec)
    }

    #if DEBUG
    /// Test-only hook: inject raw samples without running SCStream/AVAudioEngine.
    func testInject(system: [Float], systemRate: Double, mic: [Float], micRate: Double) {
        systemLock.lock()
        systemSamples = system
        systemReadOffset = 0
        systemLock.unlock()
        micLock.lock()
        micSamples = mic
        micReadOffset = 0
        micLock.unlock()
        sampleRateLock.lock()
        self.systemSampleRate = systemRate
        self.micSampleRate = micRate
        sampleRateLock.unlock()
    }
    #endif

    // MARK: - System spill helpers

    /// Open a fresh streaming WAV file for this call's system channel. Failure
    /// to create the file disables the spill but never blocks recording.
    private func setupSystemSpill() {
        spillLock.lock()
        spillFile = nil
        spillPending = []
        spillDisabled = false
        diskGuardFired = false
        spillLock.unlock()

        let id = CallSpillNaming.folderName(from: startTime ?? Date())
        callId = id
        systemWavURL = nil

        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Voicely/calls")
            .appendingPathComponent(id)
        let url = baseDir.appendingPathComponent("system.wav")
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48000, channels: 1, interleaved: false) else {
                disableSpill()
                return
            }
            // Persist as 16-bit PCM to roughly halve disk footprint vs float32;
            // AVAudioFile converts on write. Diarization reads back fine.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: false)
            spillLock.lock()
            spillFile = file
            spillLock.unlock()
            systemWavURL = url
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSLog("[Voicely] system spill opened at %@", url.path)
        } catch {
            NSLog("[Voicely] system spill open failed: %@ — continuing RAM-only", error.localizedDescription)
            disableSpill()
        }
    }

    /// Audio-thread side: stash samples and kick a background flush. O(append).
    private func enqueueSpill(_ samples: [Float]) {
        spillLock.lock()
        if spillDisabled {
            spillLock.unlock()
            return
        }
        spillPending.append(contentsOf: samples)
        spillLock.unlock()
        spillQueue.async { [weak self] in self?.flushSpill() }
    }

    /// Background side: write whatever is pending to the WAV file. Runs the
    /// disk-full guard before writing. Never touches the audio thread.
    private func flushSpill() {
        spillLock.lock()
        if spillDisabled || spillFile == nil || spillPending.isEmpty {
            spillLock.unlock()
            return
        }
        var batch: [Float] = []
        swap(&batch, &spillPending)
        let file = spillFile
        spillLock.unlock()

        guard let file else { return }

        // Disk-full guard (#2): stop spilling if the volume is low, keep RAM
        // data and already-written bytes. Fire the user-facing callback once.
        if let free = Self.freeBytes(at: file.url), free < Self.spillMinFreeBytes {
            NSLog("[Voicely] system spill low disk (%llu bytes free) — stopping spill", free)
            disableSpill()
            fireDiskGuard(free)
            return
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(batch.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(batch.count)
        if let dst = buffer.floatChannelData?[0] {
            batch.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { dst.initialize(from: base, count: batch.count) }
            }
        }
        do {
            try file.write(from: buffer)
        } catch {
            // A write error (e.g. ENOSPC slipping past the guard) must not crash
            // the call; disable the spill and keep RAM capture intact.
            NSLog("[Voicely] system spill write failed: %@ — stopping spill", error.localizedDescription)
            let free = Self.freeBytes(at: file.url) ?? 0
            disableSpill()
            fireDiskGuard(free)
        }
    }

    /// Drain remaining pending samples and close the file. Synchronous wrt the
    /// spill queue so `systemWavURL` points to a complete, closed WAV on return.
    private func finalizeSystemSpill() {
        spillQueue.sync { [weak self] in self?.flushSpill() }
        spillLock.lock()
        let hadFile = spillFile != nil
        spillFile = nil
        spillPending = []
        spillLock.unlock()
        if hadFile, let url = systemWavURL {
            NSLog("[Voicely] system spill finalized at %@", url.path)
        }
    }

    private func disableSpill() {
        spillLock.lock()
        spillDisabled = true
        spillFile = nil
        spillPending = []
        spillLock.unlock()
    }

    private func fireDiskGuard(_ freeBytes: UInt64) {
        spillLock.lock()
        let already = diskGuardFired
        diskGuardFired = true
        spillLock.unlock()
        if !already { onDiskSpillStopped?(freeBytes) }
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

    private func collectSamples() -> ([Float], [Float]) {
        var sys: [Float] = []
        systemLock.lock()
        swap(&sys, &systemSamples)
        systemLock.unlock()

        var mic: [Float] = []
        micLock.lock()
        swap(&mic, &micSamples)
        micLock.unlock()

        return (sys, mic)
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

    private func makePCMBuffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                data[i] = samples[i]
            }
        }
        return buffer
    }
}

// MARK: - Stream Delegate

private final class CallStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let onSamples: ([Float], Double) -> Void
    let onError: ((String) -> Void)?
    var onStreamDied: (() -> Void)?

    init(onSamples: @escaping ([Float], Double) -> Void, onError: ((String) -> Void)? = nil) {
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
        guard let formatDesc = sampleBuffer.formatDescription else { return }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

        // Validate audio format: must be Float32, mono, packed
        if let desc = asbd {
            guard desc.mChannelsPerFrame == 1,
                  desc.mBitsPerChannel == 32,
                  desc.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                return
            }
        }

        // Guard against 0 or invalid sample rate
        let sampleRate = (asbd?.mSampleRate ?? 0) > 0 ? asbd!.mSampleRate : 48000

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return }

        let floatCount = length / MemoryLayout<Float>.size
        let floats = data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }

        onSamples(floats, sampleRate)
    }
}

// MARK: - Spill folder naming

/// Folder name for a call's on-disk artifacts. Matches the format
/// `TranscriptStorage.saveCall` uses (`yyyy-MM-dd_HH-mm-ss-SSS`) so the spilled
/// `system.wav` lands in the same directory the final transcript is written to,
/// given the same `startTime`.
enum CallSpillNaming {
    static func folderName(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f.string(from: date)
    }
}

// MARK: - Errors

enum CallRecorderError: Error, LocalizedError {
    case noDisplay
    case noAudio
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for screen capture"
        case .noAudio: return "No audio captured"
        case .alreadyRunning: return "Call recording is already running"
        }
    }
}
