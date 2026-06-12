import ArgumentParser
import Foundation
import VoicelyCore

// MARK: - voicely transcribe
//
// Headless one-shot transcription. Mirrors the app's file path: load the same
// WhisperKit model, extract 16 kHz mono PCM via AudioExtractor, transcribe in
// 30 s chunks through the engine's SampleTranscribing interface, optionally run
// a single global DiarizationService pass, then print the rendered transcript
// to stdout. With --save it also persists into ~/Documents/Voicely/files via
// FileTranscriptWriter so `voicely show`/`list` pick it up.

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio/video file offline and print the result to stdout."
    )

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case md
        case txt
        case jsonl
    }

    enum Language: String, ExpressibleByArgument, CaseIterable {
        case auto
        case ru
        case en

        /// nil = auto-detect-then-latch; otherwise a hard-forced language code.
        var forcedCode: String? { self == .auto ? nil : rawValue }
    }

    @Argument(help: "Path to the audio or video file to transcribe.")
    var path: String

    @Flag(name: .long, help: "Run speaker diarization (who spoke when) and label segments.")
    var diarize = false

    @Option(name: .long, help: "Output format: md | txt | jsonl.")
    var format: OutputFormat = .md

    @Option(name: .long, help: "Language: auto | ru | en.")
    var language: Language = .auto

    @Flag(name: .long, help: "Include per-segment timestamps in md/txt output.")
    var timestamps = false

    @Flag(name: .long, help: "Also save the transcript into ~/Documents/Voicely/files.")
    var save = false

    @Option(name: .long, help: "Whisper model variant (default: RAM-based recommendation).")
    var model: String?

    func run() async throws {
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(fileURL.path)")
        }

        let job = await TranscribeJob(
            fileURL: fileURL,
            diarize: diarize,
            forcedLanguage: language.forcedCode,
            modelVariant: model
        )
        let result = try await job.execute()

        let rendered = Self.render(
            result,
            format: format,
            timestamps: timestamps
        )
        emit(rendered.hasSuffix("\n") ? rendered : rendered + "\n")

        if save {
            try await result.persist(timestamps: timestamps, format: format)
            logErr("Saved transcript under \(TranscriptStore.directory(for: .files).path)")
        }
    }

    // MARK: - Rendering

    /// Render a finished job into the requested output. `jsonl` always emits one
    /// JSON object per segment (timestamps implied); md/txt honor --timestamps
    /// and the diarization labels when present.
    static func render(
        _ result: TranscribeResult,
        format: OutputFormat,
        timestamps: Bool
    ) -> String {
        switch format {
        case .jsonl:
            return CallTranscriptMerger.jsonlFormat(segments: result.dialogue)
        case .md, .txt:
            if result.hasSpeakers {
                // File-appropriate labelled output: "Speaker N" per segment, no
                // microphone "You" line (that's call-only). Mirrors the writer's
                // diarized document so stdout matches --save output.
                return renderLabelled(result.dialogue, timestamps: timestamps)
            }
            if timestamps {
                return result.segments.map { seg in
                    "[\(mmss(seg.start)) → \(mmss(seg.end))] \(seg.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                }.joined(separator: "\n")
            }
            return result.transcript
        }
    }

    /// "Speaker N:" prefixed body with a leading legend, optionally timestamped.
    private static func renderLabelled(
        _ segments: [DialogueSegment],
        timestamps: Bool
    ) -> String {
        let ids = CallTranscriptMerger.detectedSpeakerIDs(in: segments)
        var legendLines = ["Speakers detected: \(ids.count)"]
        for id in ids { legendLines.append("- Speaker \(id)") }
        let legend = legendLines.joined(separator: "\n")

        let body = segments.map { seg -> String in
            let label = seg.speakerID.map { "Speaker \($0)" } ?? "Speaker ?"
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if timestamps {
                return "[\(mmss(seg.start)) → \(mmss(seg.end))] \(label): \(text)"
            }
            return "\(label): \(text)"
        }.joined(separator: "\n")

        return ids.isEmpty ? body : (legend + "\n\n" + body)
    }

    private static func mmss(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
