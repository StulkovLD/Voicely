import XCTest
@testable import VoicelyCore

final class FileTranscriptWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleInput(
        basename: String,
        content: FileTranscriptionOptions.Content = .plain,
        format: FileTranscriptionOptions.Format = .markdown
    ) -> FileTranscriptWriter.Input {
        let source = tempDir.appendingPathComponent("\(basename).mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        return FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "Hello world. This is a test.",
            segments: [
                WhisperSegment(start: 0.0, end: 3.24, text: "Hello world."),
                WhisperSegment(start: 3.24, end: 7.50, text: "This is a test."),
            ],
            options: FileTranscriptionOptions(content: content, format: format),
            language: "en",
            modelName: "large-v3_turbo"
        )
    }

    func testWritesMarkdownWithFrontmatter() async throws {
        let input = sampleInput(basename: "video1")
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let nextTo = try XCTUnwrap(result.nextToSourceURL)
        let text = try String(contentsOf: nextTo, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\n"), "expected markdown frontmatter")
        XCTAssertTrue(text.contains("type: file-transcription"))
        XCTAssertTrue(text.contains("source: \(input.sourceURL.path)"))
        XCTAssertTrue(text.contains("language: en"))
        XCTAssertTrue(text.contains("Hello world."))
    }

    func testWritesPlainTextWithoutFrontmatter() async throws {
        let input = sampleInput(basename: "video2", format: .plainText)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let nextTo = try XCTUnwrap(result.nextToSourceURL)
        let text = try String(contentsOf: nextTo, encoding: .utf8)
        XCTAssertFalse(text.contains("---"), "plain text must not have frontmatter")
        XCTAssertTrue(text.contains("Hello world."))
    }

    func testWritesSrtWithCorrectTimecodes() async throws {
        let input = sampleInput(basename: "video3", content: .timestamps)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        // SRT sits next to the main file
        let srtURL = result.nextToSourceURL!.deletingPathExtension()
            .appendingPathExtension("srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:03,240"),
            "got SRT: \(srt)")
        XCTAssertTrue(srt.contains("00:00:03,240 --> 00:00:07,500"),
            "got SRT: \(srt)")
        XCTAssertTrue(srt.contains("Hello world."))
        XCTAssertTrue(srt.contains("This is a test."))
    }

    func testNextToSourceCollisionAppendsSuffix() async throws {
        let input = sampleInput(basename: "collision")
        // Pre-create video.md to force a collision
        let existing = tempDir.appendingPathComponent("collision.md")
        try "pre-existing".write(to: existing, atomically: true, encoding: .utf8)

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let nextTo = try XCTUnwrap(result.nextToSourceURL)
        XCTAssertEqual(nextTo.lastPathComponent, "collision (2).md")
        // Original still intact
        let orig = try String(contentsOf: existing, encoding: .utf8)
        XCTAssertEqual(orig, "pre-existing")
    }

    func testCentralFolderCollisionAppendsSuffix() async throws {
        let input = sampleInput(basename: "cen")
        let centralRoot = tempDir.appendingPathComponent("central")
        // Pre-create files/cen/ to force a collision
        let collidingDir = centralRoot.appendingPathComponent("cen")
        try FileManager.default.createDirectory(
            at: collidingDir, withIntermediateDirectories: true)

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )
        XCTAssertEqual(
            result.centralURL.deletingLastPathComponent().lastPathComponent,
            "cen-2")
    }

    func testSanitizesPunctuationInBasename() async throws {
        // Source filename with characters that shouldn't land in the central folder name
        let badSource = tempDir.appendingPathComponent("hello:world.mp4")
        FileManager.default.createFile(atPath: badSource.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: badSource,
            transcript: "x",
            segments: [],
            options: FileTranscriptionOptions(content: .plain, format: .plainText),
            language: nil,
            modelName: "tiny"
        )

        let centralRoot = tempDir.appendingPathComponent("central")
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )
        let centralDir = result.centralURL.deletingLastPathComponent()
        XCTAssertEqual(centralDir.lastPathComponent, "hello_world")
    }

    func testSrtMillisRoundingHandlesFPDrift() async throws {
        // WhisperKit's TranscriptionSegment.start/end are Float. When cast to
        // Double, 1.234 becomes 1.2339999675750732, and the naive
        // Int((frac) * 1000) truncates to 233 instead of 234. Same for 2.345.
        // These assertions would fail with the unrounded formatter.
        let source = tempDir.appendingPathComponent("drift.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "one two",
            segments: [
                WhisperSegment(start: 0.0, end: Double(Float(1.234)), text: "one"),
                WhisperSegment(start: Double(Float(1.234)), end: Double(Float(2.345)), text: "two"),
            ],
            options: FileTranscriptionOptions(content: .timestamps, format: .markdown),
            language: nil,
            modelName: "test"
        )
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let srtURL = result.nextToSourceURL!.deletingPathExtension()
            .appendingPathExtension("srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        XCTAssertTrue(srt.contains("00:00:01,234"), "expected 1.234s → 01,234; got: \(srt)")
        XCTAssertTrue(srt.contains("00:00:02,345"), "expected 2.345s → 02,345; got: \(srt)")
    }

    // MARK: - Diarization rendering

    private func diarizedInput(
        basename: String,
        content: FileTranscriptionOptions.Content = .plain,
        format: FileTranscriptionOptions.Format = .markdown
    ) -> FileTranscriptWriter.Input {
        let source = tempDir.appendingPathComponent("\(basename).mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let segments = [
            DialogueSegment(speaker: .other, start: 0.0, end: 3.24,
                            text: "Hello world.", language: "en", speakerID: 1),
            DialogueSegment(speaker: .other, start: 3.24, end: 7.50,
                            text: "This is a test.", language: "en", speakerID: 2),
        ]
        return FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "Hello world. This is a test.",
            segments: [
                WhisperSegment(start: 0.0, end: 3.24, text: "Hello world."),
                WhisperSegment(start: 3.24, end: 7.50, text: "This is a test."),
            ],
            options: FileTranscriptionOptions(content: content, format: format, diarize: true),
            language: "en",
            modelName: "large-v3_turbo",
            diarizedSegments: segments
        )
    }

    func testDiarizedMarkdownHasLegendAndSpeakerLabels() async throws {
        let input = diarizedInput(basename: "diar1")
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\n"), "markdown keeps frontmatter")
        XCTAssertTrue(text.contains("Speakers detected: 2"), "legend missing: \(text)")
        XCTAssertTrue(text.contains("Speaker 1: Hello world."), "label missing: \(text)")
        XCTAssertTrue(text.contains("Speaker 2: This is a test."), "label missing: \(text)")
    }

    func testDiarizedPlainTextHasNoFrontmatterButLabels() async throws {
        let input = diarizedInput(basename: "diar2", format: .plainText)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertFalse(text.contains("---"), "plain text must not have frontmatter")
        XCTAssertTrue(text.contains("Speakers detected: 2"))
        XCTAssertTrue(text.contains("Speaker 1: Hello world."))
    }

    func testDiarizedTimestampsKeepsTimecodes() async throws {
        let input = diarizedInput(basename: "diar3", content: .timestamps)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertTrue(text.contains("[00:00 → 00:03] Speaker 1: Hello world."),
            "expected timestamped speaker line, got: \(text)")
    }

    func testNilDiarizedSegmentsRendersUnchanged() async throws {
        // diarize requested but the pass produced nothing (nil) → identical to
        // the non-diarized plain markdown output (frontmatter + raw transcript).
        let source = tempDir.appendingPathComponent("diar-nil.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "Hello world. This is a test.",
            segments: [],
            options: FileTranscriptionOptions(content: .plain, format: .markdown, diarize: true),
            language: "en",
            modelName: "m",
            diarizedSegments: nil
        )
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertFalse(text.contains("Speaker"), "no labels when diarizedSegments nil")
        XCTAssertTrue(text.contains("Hello world. This is a test."))
    }

    func testNextToSourceFailureFallbackInvoked() async throws {
        // Make the source directory read-only so writing next to source fails
        let roDir = tempDir.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(
            at: roDir, withIntermediateDirectories: true)
        let source = roDir.appendingPathComponent("ro.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: roDir.path)

        let fallbackURL = tempDir.appendingPathComponent("fallback.md")
        let callbackFired = CallbackFlag()
        let input = FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "fallback test",
            segments: [],
            options: FileTranscriptionOptions(content: .plain, format: .markdown),
            language: nil,
            modelName: "tiny"
        )

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in
                callbackFired.fire()
                return fallbackURL
            }
        )

        // Restore permissions so tearDown can clean up
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: roDir.path)

        XCTAssertTrue(callbackFired.wasFired)
        XCTAssertEqual(result.nextToSourceURL?.lastPathComponent, "fallback.md")
        let written = try String(contentsOf: fallbackURL, encoding: .utf8)
        XCTAssertTrue(written.contains("fallback test"))
    }
}

/// Sendable flag for use inside @Sendable closures.
private final class CallbackFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() {
        lock.lock(); defer { lock.unlock() }
        fired = true
    }
    var wasFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}
