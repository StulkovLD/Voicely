import AVFoundation
import Foundation
import XCTest
@testable import Voicely
@testable import VoicelyCore

final class CallDiskPipelineTests: XCTestCase {
    func testLongCallReaderMaterializesOnlyRequestedThirtySecondWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-call-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("long.wav")
        try writeRepeatedAudio(to: url, seconds: 120, sampleRate: 48_000)

        let samples = try CallAudioFileWindowReader.readMono16k(
            from: url,
            startTime: 60,
            endTime: 120
        )

        XCTAssertEqual(samples.count, 30 * 16_000,
                       "a 120-second source must still allocate one bounded ASR window")
        XCTAssertEqual(try CallAudioFileWindowReader.durationSeconds(of: url), 120, accuracy: 0.01)
    }

    func testTailWindowUsesOriginalTimelineWithoutReadingPastEOF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-call-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tail.wav")
        try writeRepeatedAudio(to: url, seconds: 61, sampleRate: 48_000)

        let samples = try CallAudioFileWindowReader.readMono16k(
            from: url,
            startTime: 60,
            endTime: 90
        )

        XCTAssertLessThanOrEqual(abs(samples.count - 16_000), 1)
    }

    func testAdjacentWindowsShareOneContinuousTargetFrameGrid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicely-call-adjacent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("adjacent.wav")
        try writeRepeatedAudio(to: url, seconds: 2, sampleRate: 48_000)

        // Deliberately choose a boundary that is not aligned to either sample
        // grid. Both readers must quantize that shared boundary identically.
        let boundary = 0.33337
        let first = try CallAudioFileWindowReader.readMono16k(
            from: url,
            startTime: 0,
            endTime: boundary
        )
        let second = try CallAudioFileWindowReader.readMono16k(
            from: url,
            startTime: boundary,
            endTime: 2
        )
        let complete = try CallAudioFileWindowReader.readMono16k(
            from: url,
            startTime: 0,
            endTime: 2
        )

        XCTAssertEqual(first.count + second.count, complete.count)
        XCTAssertEqual(complete.count, 2 * 16_000)
    }

    private func writeRepeatedAudio(
        to url: URL,
        seconds: Int,
        sampleRate: Double
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let framesPerChunk = 4_096
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(framesPerChunk)
        ))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<framesPerChunk {
            channel[index] = 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int(sampleRate) * seconds
        while remaining > 0 {
            let count = min(remaining, framesPerChunk)
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
        }
    }
}
