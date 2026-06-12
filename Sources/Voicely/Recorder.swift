@preconcurrency import AVFoundation
import Foundation

// MARK: - Error Types

enum RecorderError: Error, LocalizedError {
    case noEngine
    case noSamples
    case formatError

    var errorDescription: String? {
        switch self {
        case .noEngine: return "Recording failed. Try again."
        case .noSamples: return "No audio captured. Check your microphone."
        case .formatError: return "Audio error. Try restarting Voicely."
        }
    }
}

// MARK: - Recorder

final class Recorder: @unchecked Sendable {
    /// Called on audio callback thread with RMS level 0.0-1.0 for visualization
    var onAudioLevel: (@Sendable (Float) -> Void)?
    /// Called on main thread when sustained silence suggests mic disconnect (RMS < threshold for 10+ seconds)
    var onSilenceDetected: (@Sendable () -> Void)?
    /// Called on main thread with remaining seconds when auto-stop is imminent
    var onAutoStopWarning: (@Sendable (Int) -> Void)?
    /// Called on main thread when the audio engine is interrupted (e.g. Bluetooth/USB device switch)
    var onEngineInterrupted: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let stateLock = NSLock()
    /// Format captured while engine is running, before stop() tears it down
    private var capturedFormat: AVAudioFormat?
    private var maxDurationTimer: Timer?
    private var warningTimer: Timer?
    private var configChangeObserver: Any?
    var onMaxDuration: (@Sendable () -> Void)?
    /// Max dictation length. `nil` = unlimited — no auto-stop timer is scheduled,
    /// so dictation runs as long as the user keeps the session open. Was 1 h;
    /// the cap is removed per product decision (unlimited dictation).
    static let maxRecordingDuration: TimeInterval? = nil
    private static let autoStopWarningSeconds: Int = 10
    private static let silenceRMSThreshold: Float = 0.005
    private static let silenceMaxDuration: TimeInterval = 10.0

    /// Accumulated silence duration in seconds. Protected by bufferLock.
    private var silenceDuration: TimeInterval = 0
    /// Whether silence callback has already fired for this recording. Protected by bufferLock.
    private var silenceFired: Bool = false

    // MARK: - Permission check

    /// Check microphone permission without requesting it.
    /// Returns the current authorization status.
    /// Does NOT trigger a permission prompt — that's Onboarding's job.
    func prepare() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Chunk Extraction

    /// Extract up to `sampleCount` samples from the front of the buffer without stopping recording.
    ///
    /// - Parameters:
    ///   - sampleCount: Desired number of samples.
    ///   - minSamples: Minimum samples that must be present for a partial return (default mode).
    ///   - requireFull: When `true`, returns nil unless at least `sampleCount` samples are
    ///                  available. Used by chunked dictation so WhisperKit sees full 30-second
    ///                  windows instead of 1-second fragments.
    /// - Returns: A slice of samples, or nil if the buffer doesn't satisfy the threshold.
    func extractChunk(sampleCount: Int,
                      minSamples: Int = 8000,
                      requireFull: Bool = false) -> [Float]? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let threshold = requireFull ? sampleCount : minSamples
        guard audioBuffer.count >= threshold else { return nil }
        let count = min(sampleCount, audioBuffer.count)
        let chunk = Array(audioBuffer.prefix(count))
        audioBuffer.removeFirst(count)
        return chunk
    }

    #if DEBUG
    /// Test-only helper. Appends raw samples to the internal buffer so unit tests
    /// can exercise `extractChunk` without running a real `AVAudioEngine`.
    func testAppendSamples(_ samples: [Float]) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        audioBuffer.append(contentsOf: samples)
    }
    #endif

    /// Current audio sample rate (valid while recording).
    var currentSampleRate: Double? {
        capturedFormat?.sampleRate ?? engine?.inputNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Recording

    /// Start recording from default microphone. Returns false if engine failed to start.
    @discardableResult
    func startMic() -> Bool {
        // #21: Serialize engine creation to prevent concurrent calls leaking engines
        stateLock.lock()
        defer { stateLock.unlock() }

        if let existing = engine, existing.isRunning { return true }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // #6 minor: Validate format instead of checking numberOfInputs
        guard format.channelCount > 0, format.sampleRate > 0 else {
            print("[Voicely] Invalid input format: channels=\(format.channelCount), sampleRate=\(format.sampleRate)")
            return false
        }

        let channelCount = Int(format.channelCount)

        // #23: Acquire bufferLock around buffer/silence state reset
        bufferLock.lock()
        audioBuffer = []
        silenceDuration = 0
        silenceFired = false
        bufferLock.unlock()

        // Save format now while the engine is alive
        capturedFormat = format

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = Int(buffer.frameLength)
            guard let floatChannelData = buffer.floatChannelData, frameLength > 0 else { return }

            // #7 minor: Mix all channels to mono instead of assuming channel 0
            let samples: [Float]
            if channelCount == 1 {
                samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
            } else {
                var mixed = [Float](repeating: 0, count: frameLength)
                let gain = 1.0 / Float(channelCount)
                for ch in 0..<channelCount {
                    let chData = floatChannelData[ch]
                    for i in 0..<frameLength {
                        mixed[i] += chData[i] * gain
                    }
                }
                samples = mixed
            }

            self.bufferLock.lock()
            self.audioBuffer.append(contentsOf: samples)
            self.bufferLock.unlock()

            // Calculate RMS for visualization (from mono samples)
            var rms: Float = 0
            for s in samples {
                rms += s * s
            }
            rms = sqrt(rms / Float(frameLength))
            let level = min(1.0, rms * 8.0)
            self.onAudioLevel?(level)

            // Silence detection: track consecutive low-RMS duration
            let bufferDuration = Double(frameLength) / format.sampleRate
            self.bufferLock.lock()
            if rms < Self.silenceRMSThreshold {
                self.silenceDuration += bufferDuration
            } else {
                self.silenceDuration = 0
                // #75: Reset silenceFired when speech resumes so silence
                // detection can fire again if mic disconnects later
                self.silenceFired = false
            }
            let shouldFireSilence = self.silenceDuration >= Self.silenceMaxDuration && !self.silenceFired
            if shouldFireSilence { self.silenceFired = true }
            self.bufferLock.unlock()

            if shouldFireSilence {
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceDetected?()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine

            // #5 minor: Pre-allocate buffer capacity now that format is known
            bufferLock.lock()
            // With chunked transcription draining every 30s, buffer stays under 60s
            audioBuffer.reserveCapacity(Int(format.sampleRate * 60))
            bufferLock.unlock()

            // #22: Subscribe to engine configuration changes (Bluetooth/USB switch)
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.onEngineInterrupted?()
                }
            }

            print("[Voicely] Recording started, format: \(format)")
            // Auto-stop after max duration to prevent unbounded buffer growth.
            // Skipped entirely when the cap is nil (unlimited dictation).
            // Schedule on main RunLoop so timers fire even if startMic() is called off-main
            if let maxDuration = Self.maxRecordingDuration {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.maxDurationTimer?.invalidate()
                    self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
                        self?.onMaxDuration?()
                    }
                    // Warning before auto-stop
                    let warningDelay = maxDuration - TimeInterval(Self.autoStopWarningSeconds)
                    self.warningTimer?.invalidate()
                    self.warningTimer = Timer.scheduledTimer(withTimeInterval: warningDelay, repeats: false) { [weak self] _ in
                        self?.onAutoStopWarning?(Self.autoStopWarningSeconds)
                    }
                }
            }
            return true
        } catch {
            print("[Voicely] Failed to start recording: \(error)")
            inputNode.removeTap(onBus: 0)
            capturedFormat = nil
            return false
        }
    }

    // MARK: - Stop & collect

    /// Stop recording and return audio buffer or a typed error.
    func stop() -> Result<AVAudioPCMBuffer, RecorderError> {
        // #24: Invalidate timers on main thread where they were scheduled
        DispatchQueue.main.async { [weak self] in
            self?.maxDurationTimer?.invalidate()
            self?.maxDurationTimer = nil
            self?.warningTimer?.invalidate()
            self?.warningTimer = nil
        }

        // #70: Remove config observer BEFORE stopping engine to prevent stale callbacks
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        guard let engine = self.engine else {
            return .failure(.noEngine)
        }

        // CRITICAL: Capture format BEFORE stopping the engine.
        // After engine.stop() the inputNode may return a zero/wrong format.
        let format = capturedFormat ?? engine.inputNode.outputFormat(forBus: 0)

        // #58/#66: Validate format immediately, including fallback from stopped engine
        guard format.sampleRate > 0, format.channelCount > 0 else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.capturedFormat = nil
            return .failure(.formatError)
        }

        // #100: Safe cleanup - removeTap before stop, nil engine even if stop fails
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        bufferLock.lock()
        let samples = audioBuffer
        audioBuffer = []
        bufferLock.unlock()

        self.engine = nil
        self.capturedFormat = nil

        guard !samples.isEmpty else {
            return .failure(.noSamples)
        }

        // Build a mono PCM buffer from the collected samples
        let sampleRate = format.sampleRate
        guard sampleRate > 0,
              let outputFormat = AVAudioFormat(
                  standardFormatWithSampleRate: sampleRate, channels: 1
              )
        else {
            return .failure(.formatError)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return .failure(.formatError)
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelData[i] = samples[i]
            }
        }

        return .success(buffer)
    }

    /// Get the sample rate of the current/last engine
    var sampleRate: Double {
        engine?.inputNode.outputFormat(forBus: 0).sampleRate ?? 44100
    }
}
