@preconcurrency import AVFoundation
import Accelerate
import CoreML
import Foundation

// Shared between the GigaAM v3 RNNT engine and the GigaAM Multilingual CTC
// engine. Both models use byte-identical mel front-ends (16 kHz, n_fft=320,
// win=320, hop=160, center=false, 64 HTK mels, log(clamp(x,1e-9,1e9))).

extension MLMultiArray {
    var elementCount: Int {
        shape.reduce(1) { $0 * Int(truncating: $1) }
    }

    func flatIndex(for indices: [Int]) -> Int {
        zip(indices, strides).reduce(0) { partial, pair in
            partial + pair.0 * Int(truncating: pair.1)
        }
    }

    func float(atFlatIndex index: Int) -> Float {
        // CoreML exposes Int8 multi-arrays starting with the macOS 26 SDK.
        // Compare the stable Objective-C raw value so this target still
        // compiles with Xcode 16.4 while decoding Int8 on newer runtimes.
        if dataType.rawValue == (0x20000 | 8) {
            let ptr = dataPointer.bindMemory(to: Int8.self, capacity: elementCount)
            return Float(ptr[index])
        }

        switch dataType {
        case .float32:
            let ptr = dataPointer.bindMemory(to: Float32.self, capacity: elementCount)
            return ptr[index]
        case .float16:
            let ptr = dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
            return Float(Float16(bitPattern: ptr[index]))
        case .double:
            let ptr = dataPointer.bindMemory(to: Double.self, capacity: elementCount)
            return Float(ptr[index])
        case .int32:
            let ptr = dataPointer.bindMemory(to: Int32.self, capacity: elementCount)
            return Float(ptr[index])
        default:
            return self[index].floatValue
        }
    }

    func float(at indices: [Int]) -> Float {
        float(atFlatIndex: flatIndex(for: indices))
    }

    func intValue(at indices: [Int]) -> Int {
        Int(round(Double(float(at: indices))))
    }
}

enum GigaAMDSP {
    /// Log-mel features for one fixed window, zero-padded on the right.
    /// Returns the feature array `[1, 64, melFrames]` and the count of frames
    /// backed by real audio.
    static func makeFeatures(
        from samples: [Float],
        melNFFT: Int,
        melWinLength: Int,
        melHopLength: Int,
        melFrames: Int,
        windowSamples: Int
    ) throws -> (MLMultiArray, Int) {
        guard !samples.isEmpty else { throw TranscriberError.recordingTooShort }
        let usableCount = min(samples.count, windowSamples)
        if usableCount < melWinLength {
            throw TranscriberError.recordingTooShort
        }

        var padded = [Float](repeating: 0, count: windowSamples)
        padded.withUnsafeMutableBufferPointer { dest in
            samples.prefix(usableCount).withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = dest.baseAddress else { return }
                dstBase.update(from: srcBase, count: usableCount)
            }
        }

        let trueFrames = max(1, ((usableCount - melWinLength) / melHopLength) + 1)
        let frameCount = melFrames
        let melBins = 64
        let powerBins = melNFFT / 2 + 1
        let filterBank = buildMelFilterBank(sampleRate: 16000, nFFT: melNFFT, melBins: melBins)
        let window = buildHannWindow(count: melWinLength)
        let dft: vDSP.DiscreteFourierTransform<Float>
        do {
            dft = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: melNFFT,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            throw TranscriberError.whisperKitFailed("Failed to create DFT for GigaAM mel frontend")
        }

        let logFloor = Float(log(1e-9))
        var featureValues = [Float](repeating: logFloor, count: melBins * frameCount)
        var realInput = [Float](repeating: 0, count: melNFFT)
        var imagInput = [Float](repeating: 0, count: melNFFT)
        var realOutput = [Float](repeating: 0, count: melNFFT)
        var imagOutput = [Float](repeating: 0, count: melNFFT)
        var power = [Float](repeating: 0, count: powerBins)

        for frame in 0..<frameCount {
            let start = frame * melHopLength
            let slice = padded[start..<(start + melWinLength)]
            var idx = 0
            for value in slice {
                realInput[idx] = value * window[idx]
                idx += 1
            }
            if idx < melNFFT {
                for i in idx..<melNFFT { realInput[i] = 0 }
            }
            imagInput.withUnsafeMutableBufferPointer { buffer in
                buffer.initialize(repeating: 0)
            }
            dft.transform(inputReal: realInput, inputImaginary: imagInput, outputReal: &realOutput, outputImaginary: &imagOutput)
            for bin in 0..<powerBins {
                let real = realOutput[bin]
                let imag = imagOutput[bin]
                power[bin] = real * real + imag * imag
            }
            for mel in 0..<melBins {
                let weights = filterBank[mel]
                var energy: Float = 0
                for bin in 0..<powerBins {
                    energy += weights[bin] * power[bin]
                }
                let logged = Float(log(Double(min(1e9 as Float, max(1e-9 as Float, energy)))))
                featureValues[mel * frameCount + frame] = logged
            }
        }

        return (try makeFloat32Array(shape: [1, melBins, frameCount], values: featureValues), trueFrames)
    }

    private static func buildHannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [Float](repeating: 1, count: max(1, count)) }
        let denominator = Float(count)
        return (0..<count).map { i in
            0.5 - 0.5 * cosf((2.0 * .pi * Float(i)) / denominator)
        }
    }

    private static func buildMelFilterBank(sampleRate: Int, nFFT: Int, melBins: Int) -> [[Float]] {
        let nyquist = Float(sampleRate) / 2.0
        let fftBins = nFFT / 2 + 1
        let melMin: Float = hzToMel(0)
        let melMax: Float = hzToMel(nyquist)
        let melPoints = (0..<(melBins + 2)).map { i -> Float in
            let ratio = Float(i) / Float(melBins + 1)
            return melMin + ratio * (melMax - melMin)
        }
        let hzPoints = melPoints.map(melToHz)
        let freqs = (0..<fftBins).map { Float($0) * Float(sampleRate) / Float(nFFT) }

        return (0..<melBins).map { band in
            let left = hzPoints[band]
            let center = hzPoints[band + 1]
            let right = hzPoints[band + 2]
            return freqs.map { freq in
                if freq < left || freq > right { return 0 }
                if freq <= center {
                    return (freq - left) / max(center - left, .leastNonzeroMagnitude)
                }
                return (right - freq) / max(right - center, .leastNonzeroMagnitude)
            }
        }
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10f(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
    }

    static func makeFloat32Array(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let count = array.elementCount
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
        if values.count == count {
            values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ptr.update(from: base, count: count)
            }
        } else {
            for i in 0..<count { ptr[i] = 0 }
            for (index, value) in values.enumerated() where index < count {
                ptr[index] = value
            }
        }
        return array
    }

    static func makeInt32Array(shape: [Int], values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        let count = array.elementCount
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: count)
        for i in 0..<count { ptr[i] = 0 }
        for (index, value) in values.enumerated() where index < count {
            ptr[index] = value
        }
        return array
    }

    static func normalizeTo16kMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let targetRate: Double = 16000
        let needsConversion = abs(buffer.format.sampleRate - targetRate) >= 1
            || buffer.format.channelCount != 1
            || buffer.format.commonFormat != .pcmFormatFloat32
            || buffer.format.isInterleaved
        if !needsConversion {
            return buffer
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriberError.whisperKitFailed("Failed to create 16kHz mono format")
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw TranscriberError.whisperKitFailed("Failed to create audio converter")
        }
        let ratio = targetRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            throw TranscriberError.whisperKitFailed("Failed to create resampling buffer")
        }
        var error: NSError?
        let input = SingleBufferAudioConverterInput(buffer)
        converter.convert(to: output, error: &error) { _, outStatus in
            input.provide(status: outStatus)
        }
        if let error {
            throw TranscriberError.whisperKitFailed("Resampling failed: \(error)")
        }
        return output
    }

    static func peakWindowRMS(_ samples: [Float], windowSize: Int = 8000) -> Float {
        guard !samples.isEmpty else { return 0 }
        let win = max(1, min(windowSize, samples.count))
        var best: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(i + win, samples.count)
            let slice = samples[i..<end]
            var sum: Float = 0
            for s in slice { sum += s * s }
            let rms = sqrtf(sum / Float(max(1, end - i)))
            if rms > best { best = rms }
            i += win
        }
        return best
    }
}
