import XCTest
import AVFoundation
@testable import Voicely

final class CallRecorderChannelTests: XCTestCase {
    // CallRecorder's read API must return both channels independently
    // without mixing them together.
    func testExtractChannelChunks_returnsIndependentBuffers() throws {
        let recorder = CallRecorder()
        recorder.testInject(
            system: [Float](repeating: 0.5, count: 48000),
            systemRate: 48000,
            mic: [Float](repeating: 0.25, count: 44100),
            micRate: 44100
        )
        let pair = recorder.extractChannelChunks(seconds: 1.0)
        XCTAssertNotNil(pair.system)
        XCTAssertNotNil(pair.mic)
        // System buffer at its native rate — no mixing, no resampling
        XCTAssertEqual(pair.system!.format.sampleRate, 48000)
        XCTAssertEqual(pair.mic!.format.sampleRate, 44100)
        // Peak level preserved (no averaging with the other channel)
        XCTAssertEqual(pair.system!.floatChannelData![0][0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(pair.mic!.floatChannelData![0][0], 0.25, accuracy: 0.0001)
    }

    func testExtractChannelChunks_nilWhenChannelEmpty() throws {
        let recorder = CallRecorder()
        recorder.testInject(
            system: [Float](repeating: 0.5, count: 48000),
            systemRate: 48000,
            mic: [],
            micRate: 44100
        )
        let pair = recorder.extractChannelChunks(seconds: 1.0)
        XCTAssertNotNil(pair.system)
        XCTAssertNil(pair.mic)
    }

    func testExtractChannelChunks_advancesOffsetsIndependently() throws {
        let recorder = CallRecorder()
        recorder.testInject(
            system: [Float](repeating: 0.5, count: 96000),
            systemRate: 48000,
            mic: [Float](repeating: 0.25, count: 88200),
            micRate: 44100
        )
        _ = recorder.extractChannelChunks(seconds: 1.0)
        let second = recorder.extractChannelChunks(seconds: 1.0)
        XCTAssertNotNil(second.system)
        XCTAssertNotNil(second.mic)
        let third = recorder.extractChannelChunks(seconds: 1.0, minSamples: 1000)
        XCTAssertNil(third.system)
        XCTAssertNil(third.mic)
    }
}
