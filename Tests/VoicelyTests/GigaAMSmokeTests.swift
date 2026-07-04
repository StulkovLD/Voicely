import AVFoundation
import Foundation
import XCTest
@testable import VoicelyCore

@MainActor
final class GigaAMSmokeTests: XCTestCase {
    func testGigaAMPreloadsAndTranscribesShortRussianSpeech() async throws {
        guard ProcessInfo.processInfo.environment["VOICELY_RUN_GIGAAM_SMOKE"] == "1" else {
            throw XCTSkip("Set VOICELY_RUN_GIGAAM_SMOKE=1 to run the network/model smoke test")
        }
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("GigaAM model option missing")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let audioURL = tempDir.appendingPathComponent("gigaam-smoke.aiff")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", "Milena",
            "-o", audioURL.path,
            "Привет мир"
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "say failed with status \(process.terminationStatus)")

        let file = try AVAudioFile(forReading: audioURL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Failed to allocate buffer for smoke audio")
            return
        }
        try file.read(into: buffer)

        let transcriber = Transcriber(locale: Locale(identifier: "ru_RU"))
        transcriber.selectModel(model)
        try await transcriber.preloadModel()
        let text = try await transcriber.transcribe(audio: buffer)
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(normalized.isEmpty, "GigaAM smoke transcript must not be empty")
        XCTAssertTrue(
            normalized.contains("привет") || normalized.contains("прив") || normalized.contains("мир"),
            "Unexpected GigaAM smoke transcript: \(text)"
        )
    }
}
