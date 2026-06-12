import XCTest
@testable import Voicely

final class RecorderExtractChunkTests: XCTestCase {

    /// Appends samples directly to the internal buffer using reflection-free
    /// access through a test-only helper we'll add in the Recorder file.
    private func recorderWith(samples: [Float]) -> Recorder {
        let r = Recorder()
        r.testAppendSamples(samples)
        return r
    }

    func testRequireFullReturnsNilWhenBufferSmaller() {
        let r = recorderWith(samples: [Float](repeating: 0.1, count: 1000))
        let chunk = r.extractChunk(sampleCount: 5000, requireFull: true)
        XCTAssertNil(chunk,
            "requireFull=true must return nil when buffer smaller than requested")
    }

    func testRequireFullReturnsFullWhenBufferExactlyMatches() {
        let r = recorderWith(samples: [Float](repeating: 0.2, count: 5000))
        let chunk = r.extractChunk(sampleCount: 5000, requireFull: true)
        XCTAssertEqual(chunk?.count, 5000)
        // Buffer drained:
        let next = r.extractChunk(sampleCount: 1, requireFull: true)
        XCTAssertNil(next)
    }

    func testRequireFullReturnsExactlySampleCountWhenBufferLarger() {
        let r = recorderWith(samples: [Float](repeating: 0.3, count: 10000))
        let chunk = r.extractChunk(sampleCount: 5000, requireFull: true)
        XCTAssertEqual(chunk?.count, 5000)
        // 5000 samples should still be in buffer:
        let rest = r.extractChunk(sampleCount: 5000, requireFull: true)
        XCTAssertEqual(rest?.count, 5000)
    }

    /// Pins the legacy partial-read semantics preserved by `requireFull: false`.
    /// The new dictation chunk loop uses `requireFull: true` via Task 1.3.
    func testDefaultReturnsPartialAboveMinSamples() {
        // 10000 > minSamples(8000), ask for 50000 → should get 10000 back
        let r = recorderWith(samples: [Float](repeating: 0.4, count: 10000))
        let chunk = r.extractChunk(sampleCount: 50000)
        XCTAssertEqual(chunk?.count, 10000,
            "default semantics must return what's available when >= minSamples")
    }

    func testDefaultReturnsNilBelowMinSamples() {
        // 100 < minSamples(8000) → nil
        let r = recorderWith(samples: [Float](repeating: 0.5, count: 100))
        let chunk = r.extractChunk(sampleCount: 50000)
        XCTAssertNil(chunk)
    }
}
