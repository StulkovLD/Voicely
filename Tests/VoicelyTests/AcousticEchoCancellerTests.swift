import XCTest
import Accelerate
@testable import Voicely

final class AcousticEchoCancellerTests: XCTestCase {
    // With an all-zero reference, the filter has nothing to subtract;
    // mic output must equal mic input within floating-point noise.
    func testZeroReference_passesMicThrough() {
        let aec = AcousticEchoCanceller(sampleRate: 48000)
        let mic: [Float] = (0..<48000).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        let ref = [Float](repeating: 0, count: 48000)
        let out = aec.process(mic: mic, reference: ref)
        XCTAssertEqual(out.count, mic.count)
        for i in stride(from: 0, to: mic.count, by: 100) {
            XCTAssertEqual(out[i], mic[i], accuracy: 1e-5, "idx \(i)")
        }
    }

    // Synthetic: mic = speaker_signal * 0.3 (pure attenuation, zero delay).
    // Expect ≥ 20 dB suppression after convergence.
    func testSyntheticEcho_cancellationDepthAtLeast20dB() {
        let aec = AcousticEchoCanceller(sampleRate: 48000)
        let N = 48000 * 5  // 5 s
        var reference = [Float](repeating: 0, count: N)
        for i in 0..<N {
            let t = Double(i) / 48000.0
            reference[i] = Float(sin(2 * .pi * 400 * t) + 0.5 * sin(2 * .pi * 900 * t)) * 0.3
        }
        let gain: Float = 0.3
        var mic = [Float](repeating: 0, count: N)
        for i in 0..<N { mic[i] = reference[i] * gain }

        // Warm up — first 2 seconds for the filter to converge
        _ = aec.process(mic: Array(mic[0..<48000]),
                        reference: Array(reference[0..<48000]))
        _ = aec.process(mic: Array(mic[48000..<96000]),
                        reference: Array(reference[48000..<96000]))
        let out = aec.process(mic: Array(mic[96000..<N]),
                              reference: Array(reference[96000..<N]))

        var inRMS: Float = 0
        let micTail = Array(mic[96000..<N])
        vDSP_rmsqv(micTail, 1, &inRMS, vDSP_Length(micTail.count))
        var outRMS: Float = 0
        vDSP_rmsqv(out, 1, &outRMS, vDSP_Length(out.count))
        let depthDb = 20.0 * log10(Double(inRMS / max(outRMS, 1e-9)))
        XCTAssertGreaterThan(depthDb, 20.0, "Expected ≥ 20 dB cancellation, got \(depthDb) dB")
    }

    // Inject known delays and verify the estimator locks within ±1 ms.
    // Uses a deterministic-seeded broadband reference (white-noise-like) so
    // cross-correlation has a single unambiguous peak. Pure sinusoids produce
    // periodic autocorrelation with multiple ties at integer-period lags,
    // which the estimator cannot disambiguate by design.
    func testDelayEstimator_recoversKnownDelays() {
        for delayMs: Double in [0, 5, 15, 40] {
            let aec = AcousticEchoCanceller(sampleRate: 48000)
            let delaySamples = Int(delayMs * 48)
            let N = 48000 * 2
            var rng = SplitMix64(seed: 0xDEADBEEF)
            var reference = [Float](repeating: 0, count: N)
            for i in 0..<N {
                reference[i] = Float(rng.nextUnitFloat()) * 0.5
            }
            var mic = [Float](repeating: 0, count: N)
            for i in delaySamples..<N {
                mic[i] = reference[i - delaySamples] * 0.4
            }
            _ = aec.estimateDelayMs(mic: mic, reference: reference)
            XCTAssertEqual(aec.estimatedDelayMs, delayMs, accuracy: 1.0,
                           "Expected \(delayMs)ms ± 1ms, got \(aec.estimatedDelayMs)ms")
        }
    }

    // Adversarial: high step size + uncorrelated mic/ref would cause NLMS
    // to diverge. Guard must bound output so it doesn't exceed input substantially.
    func testDivergenceGuard_resetsAndBoundsOutput() {
        let aec = AcousticEchoCanceller(sampleRate: 48000, stepSize: 2.0)
        let N = 48000  // 1 s
        var mic = [Float](repeating: 0, count: N)
        var ref = [Float](repeating: 0, count: N)
        for i in 0..<N {
            mic[i] = Float.random(in: -1...1) * 2.0
            ref[i] = Float.random(in: -1...1)
        }
        let out = aec.process(mic: mic, reference: ref)
        var inRMS: Float = 0
        vDSP_rmsqv(mic, 1, &inRMS, vDSP_Length(mic.count))
        var outRMS: Float = 0
        vDSP_rmsqv(out, 1, &outRMS, vDSP_Length(out.count))
        XCTAssertLessThan(outRMS, inRMS * 2.0, "Divergence guard should prevent runaway output")
    }
}

/// Deterministic PRNG for reproducible test signals.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Float in (-1, 1).
    mutating func nextUnitFloat() -> Double {
        let u = Double(next() >> 11) / Double(1 << 53)
        return u * 2.0 - 1.0
    }
}
