import Accelerate
import Foundation

/// NLMS adaptive filter that subtracts speaker-path echo from mic using the
/// digital system-audio stream as reference.
///
/// Stateful across `process()` calls within one recording; call `reset()`
/// between recordings or after audio-route changes.
///
/// Sample rate is fixed for the lifetime of an instance — both mic and
/// reference must be resampled to this rate by the caller.
///
/// Hot loops are vectorized with vDSP. Internally the filter taps are stored
/// in "reversed" order (tap 0 = oldest, tap L-1 = newest) so that one output
/// sample becomes a forward dot product against a contiguous reference window.
final class AcousticEchoCanceller {
    private let sampleRate: Double
    private let filterLength: Int
    private let stepSize: Float
    private let regularization: Float = 1e-6

    /// Filter coefficients stored in reversed order (see class doc).
    private var coefficients: [Float]
    /// Trailing reference window carried across `process()` blocks so that
    /// the first samples of a new block can still see the previous block's
    /// reference tail. Length = filterLength - 1.
    private var referenceTail: [Float]

    private var delaySamples: Int = 0
    private var delayLocked: Bool = false

    private var rollingErrorRMS: Float = 0
    private var rollingInputRMS: Float = 0
    private var cancellationDepthDbRolling: Double = 0

    init(sampleRate: Double, filterLengthSamples: Int = 4800, stepSize: Float = 0.3) {
        self.sampleRate = sampleRate
        self.filterLength = filterLengthSamples
        self.stepSize = stepSize
        self.coefficients = [Float](repeating: 0, count: filterLengthSamples)
        self.referenceTail = [Float](repeating: 0, count: filterLengthSamples - 1)
    }

    var estimatedDelayMs: Double { Double(delaySamples) * 1000.0 / sampleRate }
    var cancellationDepthDb: Double { cancellationDepthDbRolling }

    func reset() {
        for i in 0..<coefficients.count { coefficients[i] = 0 }
        for i in 0..<referenceTail.count { referenceTail[i] = 0 }
        delaySamples = 0
        delayLocked = false
        rollingErrorRMS = 0
        rollingInputRMS = 0
        cancellationDepthDbRolling = 0
    }

    /// Cross-correlate mic against reference over the first ~2 seconds and lock
    /// the lag with the strongest positive correlation. Search range 0-50 ms.
    @discardableResult
    func estimateDelayMs(mic: [Float], reference: [Float]) -> Double {
        let maxDelaySamples = Int(0.05 * sampleRate)
        let window = min(mic.count, reference.count, Int(2.0 * sampleRate))
        guard window > maxDelaySamples * 2 else { return 0 }

        var bestLag = 0
        var bestCorr: Float = -.infinity
        for lag in 0...maxDelaySamples {
            var corr: Float = 0
            let count = window - lag
            mic.withUnsafeBufferPointer { mptr in
                reference.withUnsafeBufferPointer { rptr in
                    vDSP_dotpr(
                        mptr.baseAddress!.advanced(by: lag), 1,
                        rptr.baseAddress!, 1,
                        &corr, vDSP_Length(count)
                    )
                }
            }
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        if bestCorr > 0 {
            delaySamples = bestLag
            delayLocked = true
        }
        return Double(delaySamples) * 1000.0 / sampleRate
    }

    /// Process one block. Both arrays must be at the configured sample rate
    /// and have the same length. Returns the AEC-cleaned mic signal.
    func process(mic: [Float], reference: [Float]) -> [Float] {
        precondition(mic.count == reference.count,
                     "mic (\(mic.count)) and reference (\(reference.count)) must match")
        let B = mic.count
        guard B > 0 else { return [] }

        // Fast path: silent reference → nothing to subtract.
        var refMeanSq: Float = 0
        vDSP_measqv(reference, 1, &refMeanSq, vDSP_Length(B))
        if refMeanSq < 1e-12 {
            // Preserve tail update so the next block with real reference has
            // the right history.
            let newTail = lastSamplesAsTail(reference: reference)
            referenceTail = newTail
            return mic
        }

        // Build a linear reference window of length (filterLength - 1 + B):
        //   [0 ..< filterLength-1]      = tail from previous block
        //   [filterLength-1 ..< end]    = current block's reference (delay-shifted)
        var linearRef = [Float](repeating: 0, count: filterLength - 1 + B)
        for i in 0..<(filterLength - 1) {
            linearRef[i] = referenceTail[i]
        }
        if delayLocked {
            for i in 0..<B {
                let src = i - delaySamples
                linearRef[filterLength - 1 + i] = src >= 0 ? reference[src] : 0
            }
        } else {
            for i in 0..<B {
                linearRef[filterLength - 1 + i] = reference[i]
            }
        }

        var output = [Float](repeating: 0, count: B)

        // Initial xPow = Σ linearRef[0..filterLength]²
        var xPow: Float = 0
        linearRef.withUnsafeBufferPointer { rptr in
            vDSP_svesq(rptr.baseAddress!, 1, &xPow, vDSP_Length(filterLength))
        }

        coefficients.withUnsafeMutableBufferPointer { cptr in
            linearRef.withUnsafeBufferPointer { rptr in
                for n in 0..<B {
                    // y[n] = coefficients (reversed-order) · linearRef[n..n+L]
                    var y: Float = 0
                    vDSP_dotpr(cptr.baseAddress!, 1,
                               rptr.baseAddress!.advanced(by: n), 1,
                               &y, vDSP_Length(filterLength))
                    let e = mic[n] - y
                    output[n] = e

                    // NLMS: c += (mu * e / (xPow + delta)) * linearRef[n..n+L]
                    var scale = stepSize * e / (xPow + regularization)
                    vDSP_vsma(rptr.baseAddress!.advanced(by: n), 1,
                              &scale,
                              cptr.baseAddress!, 1,
                              cptr.baseAddress!, 1,
                              vDSP_Length(filterLength))

                    // Update xPow incrementally for next sample: drop the
                    // sample leaving the window, add the one entering.
                    if n + 1 < B {
                        let leaving = rptr[n]
                        let entering = rptr[n + filterLength]
                        xPow = xPow - leaving * leaving + entering * entering
                        if xPow < 0 { xPow = 0 }
                    }
                }
            }
        }

        // Save the tail for the next block: last (filterLength - 1) samples
        // of linearRef, i.e. linearRef[B ... B + filterLength - 2].
        for i in 0..<(filterLength - 1) {
            referenceTail[i] = linearRef[B + i]
        }

        // Rolling metrics
        var outRMS: Float = 0
        vDSP_rmsqv(output, 1, &outRMS, vDSP_Length(B))
        var inRMS: Float = 0
        vDSP_rmsqv(mic, 1, &inRMS, vDSP_Length(B))
        rollingErrorRMS = 0.9 * rollingErrorRMS + 0.1 * outRMS
        rollingInputRMS = 0.9 * rollingInputRMS + 0.1 * inRMS
        if rollingInputRMS > 1e-6 && rollingErrorRMS > 1e-9 {
            cancellationDepthDbRolling = 20.0 * log10(Double(rollingInputRMS / rollingErrorRMS))
        }

        // Divergence guard: error energy sustainedly exceeds input energy →
        // coefficients are diverging. Reset them and return mic pass-through.
        if rollingErrorRMS > rollingInputRMS * 1.5 && rollingInputRMS > 0 {
            for i in 0..<coefficients.count { coefficients[i] = 0 }
            rollingErrorRMS = rollingInputRMS
            return mic
        }

        return output
    }

    /// Compute the tail that would carry over to the next block if only the
    /// raw reference (no delay) were consumed this turn. Used by the silent-
    /// reference fast path.
    private func lastSamplesAsTail(reference: [Float]) -> [Float] {
        let L = filterLength - 1
        if reference.count >= L {
            return Array(reference.suffix(L))
        }
        // Reference shorter than filter length: prepend zeros
        var tail = [Float](repeating: 0, count: L)
        let offset = L - reference.count
        for i in 0..<reference.count {
            tail[offset + i] = reference[i]
        }
        return tail
    }
}
