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

    func testPlainDocumentUsesParagraphBreaksFromSegmentTimeline() async throws {
        let source = tempDir.appendingPathComponent("paragraphs.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "First sentence. Second sentence. Third sentence.",
            segments: [
                WhisperSegment(start: 0.0, end: 1.0, text: "First sentence."),
                WhisperSegment(start: 1.05, end: 2.0, text: "Second sentence."),
                WhisperSegment(start: 4.4, end: 5.2, text: "Third sentence."),
            ],
            options: FileTranscriptionOptions(content: .plain, format: .plainText),
            language: "en",
            modelName: "large-v3_turbo"
        )

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertTrue(
            text.contains("First sentence. Second sentence.\n\nThird sentence."),
            "expected paragraph break from segment gap, got: \(text)"
        )
        XCTAssertFalse(
            text.contains("First sentence. Second sentence. Third sentence."),
            "writer should not flatten the document back into one transport line"
        )
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

    func testSRTOnlyCollisionMovesWholeOutputSetToOneSuffix() async throws {
        let input = sampleInput(basename: "srt-only", content: .timestamps)
        let existingSRT = tempDir.appendingPathComponent("srt-only.srt")
        try "original subtitles".write(
            to: existingSRT,
            atomically: true,
            encoding: .utf8
        )

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central-srt-only"),
            onNextToSourceFailure: { _, _ in nil }
        )

        let main = try XCTUnwrap(result.nextToSourceURL)
        XCTAssertEqual(main.lastPathComponent, "srt-only (2).md")
        XCTAssertEqual(
            try String(contentsOf: existingSRT, encoding: .utf8),
            "original subtitles"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("srt-only (2).srt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("srt-only.md").path
            )
        )
    }

    func testPrimaryAndSRTCollisionsPreserveBothExistingFiles() async throws {
        let input = sampleInput(basename: "both", content: .timestamps)
        let existingMain = tempDir.appendingPathComponent("both.md")
        let existingSRT = tempDir.appendingPathComponent("both.srt")
        try "original transcript".write(
            to: existingMain,
            atomically: true,
            encoding: .utf8
        )
        try "original subtitles".write(
            to: existingSRT,
            atomically: true,
            encoding: .utf8
        )

        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central-both"),
            onNextToSourceFailure: { _, _ in nil }
        )

        let main = try XCTUnwrap(result.nextToSourceURL)
        XCTAssertEqual(main.lastPathComponent, "both (2).md")
        XCTAssertEqual(
            try String(contentsOf: existingMain, encoding: .utf8),
            "original transcript"
        )
        XCTAssertEqual(
            try String(contentsOf: existingSRT, encoding: .utf8),
            "original subtitles"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("both (2).srt").path
            )
        )
    }

    func testConcurrentTimestampWritersPublishDistinctCompleteSets() async throws {
        let input = sampleInput(basename: "concurrent", content: .timestamps)
        let firstCentral = tempDir.appendingPathComponent("central-concurrent-a")
        let secondCentral = tempDir.appendingPathComponent("central-concurrent-b")

        async let first = FileTranscriptWriter.write(
            input: input,
            centralRoot: firstCentral,
            onNextToSourceFailure: { _, _ in nil }
        )
        async let second = FileTranscriptWriter.write(
            input: input,
            centralRoot: secondCentral,
            onNextToSourceFailure: { _, _ in nil }
        )
        let (firstResult, secondResult) = try await (first, second)
        let mainURLs = try [firstResult, secondResult].map {
            try XCTUnwrap($0.nextToSourceURL)
        }

        XCTAssertEqual(
            Set(mainURLs.map(\.lastPathComponent)),
            Set(["concurrent.md", "concurrent (2).md"])
        )
        for mainURL in mainURLs {
            let main = try String(contentsOf: mainURL, encoding: .utf8)
            XCTAssertTrue(main.contains("Hello world."))
            let srtURL = mainURL.deletingPathExtension().appendingPathExtension("srt")
            let srt = try String(contentsOf: srtURL, encoding: .utf8)
            XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:03,240"))
        }
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

    func testSanitizePreservesCyrillic() {
        // APFS is UTF-8: non-ASCII names are valid and must survive verbatim.
        XCTAssertEqual(
            FileTranscriptWriter.sanitize("Запись разговора"),
            "Запись разговора",
            "Cyrillic letters and spaces must be preserved, not turned into '_'")
        // Path-hostile characters are still replaced, even around Cyrillic.
        XCTAssertEqual(
            FileTranscriptWriter.sanitize("Запись/разговора:2"),
            "Запись_разговора_2")
    }

    func testSanitizeWritesCyrillicFolder() async throws {
        let src = tempDir.appendingPathComponent("Запись разговора.mp4")
        FileManager.default.createFile(atPath: src.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: src,
            transcript: "x",
            segments: [],
            options: FileTranscriptionOptions(content: .plain, format: .plainText),
            language: nil,
            modelName: "tiny"
        )
        let centralRoot = tempDir.appendingPathComponent("central-cyr")
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )
        let centralDir = result.centralURL.deletingLastPathComponent()
        XCTAssertEqual(centralDir.lastPathComponent, "Запись разговора")
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

    func testSrtRoundingCarriesIntoNextMinute() async throws {
        let source = tempDir.appendingPathComponent("carry.mp4")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let input = FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "boundary",
            segments: [
                WhisperSegment(start: 59.9996, end: 3_599.9996, text: "boundary"),
            ],
            options: FileTranscriptionOptions(content: .timestamps, format: .markdown),
            language: "en",
            modelName: "test"
        )
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let srtURL = try XCTUnwrap(result.nextToSourceURL)
            .deletingPathExtension()
            .appendingPathExtension("srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)

        XCTAssertTrue(srt.contains("00:01:00,000 --> 01:00:00,000"), "got SRT: \(srt)")
        XCTAssertFalse(srt.contains(",1000"))
    }

    func testTranscriptArtifactsArePrivate() async throws {
        let input = sampleInput(basename: "private", content: .timestamps)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central-private"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let nextToSource = try XCTUnwrap(result.nextToSourceURL)
        let centralDirectory = result.centralURL.deletingLastPathComponent()

        for url in [
            nextToSource,
            nextToSource.deletingPathExtension().appendingPathExtension("srt"),
            result.centralURL,
            centralDirectory.appendingPathComponent("transcript.srt"),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: centralDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
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
            DialogueSegment(speaker: .other, start: 3.24, end: 5.00,
                            text: "How are you?", language: "en", speakerID: 1),
            DialogueSegment(speaker: .other, start: 7.50, end: 10.00,
                            text: "This is a test.", language: "en", speakerID: 2),
        ]
        return FileTranscriptWriter.Input(
            sourceURL: source,
            transcript: "Hello world. How are you? This is a test.",
            segments: [
                WhisperSegment(start: 0.0, end: 3.24, text: "Hello world."),
                WhisperSegment(start: 3.24, end: 5.00, text: "How are you?"),
                WhisperSegment(start: 7.50, end: 10.00, text: "This is a test."),
            ],
            options: FileTranscriptionOptions(content: content, format: format, diarize: true),
            language: "en",
            modelName: "large-v3_turbo",
            diarizedSegments: segments
        )
    }

    func testDiarizedMarkdownUsesSpeakerSectionsWithoutLegend() async throws {
        let input = diarizedInput(basename: "diar1")
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\n"), "markdown keeps frontmatter")
        XCTAssertFalse(text.contains("Speakers detected:"), "legend should be removed: \(text)")
        XCTAssertTrue(text.contains("## Speaker 1\n\nHello world. How are you?"), "speaker section missing: \(text)")
        XCTAssertTrue(text.contains("## Speaker 2\n\nThis is a test."), "speaker section missing: \(text)")
        XCTAssertFalse(text.contains("Speaker 1:"), "speaker should be a section heading, not repeated inline: \(text)")
    }

    func testDiarizedPlainTextUsesSpeakerSectionsWithoutFrontmatter() async throws {
        let input = diarizedInput(basename: "diar2", format: .plainText)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertFalse(text.contains("---"), "plain text must not have frontmatter")
        XCTAssertFalse(text.contains("Speakers detected:"))
        XCTAssertTrue(text.contains("Speaker 1\n\nHello world. How are you?"))
        XCTAssertTrue(text.contains("Speaker 2\n\nThis is a test."))
        XCTAssertFalse(text.contains("Speaker 1:"))
    }

    func testDiarizedTimestampsKeepTimecodesInsideSpeakerSections() async throws {
        let input = diarizedInput(basename: "diar3", content: .timestamps)
        let result = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: tempDir.appendingPathComponent("central"),
            onNextToSourceFailure: { _, _ in nil }
        )
        let text = try String(contentsOf: try XCTUnwrap(result.nextToSourceURL), encoding: .utf8)
        XCTAssertTrue(text.contains("## Speaker 1"), "expected speaker heading, got: \(text)")
        XCTAssertTrue(text.contains("- [00:00 → 00:03] Hello world."),
            "expected timestamped entry, got: \(text)")
        XCTAssertTrue(text.contains("- [00:03 → 00:05] How are you?"),
            "expected timestamped entry, got: \(text)")
        XCTAssertTrue(text.contains("## Speaker 2"), "expected second speaker heading, got: \(text)")
        XCTAssertFalse(text.contains("Speaker 1:"),
            "timestamped body should sit under a section heading, got: \(text)")
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
