import Foundation
import VoicelyCore

// MARK: - Headless transcription driver
//
// Mirrors FileTranscriptionQueue.processJob but for a single file and stdout:
//   1. load the same WhisperKit model the app uses (Transcriber.preloadModel)
//   2. extract 16 kHz mono PCM (AudioExtractor)
//   3. transcribe in 30 s chunks via the engine's SampleTranscribing interface
//   4. optional single global DiarizationService pass + assignSpeakers
//
// Runs on the main actor because Transcriber is @MainActor (same as the app).

/// Chunk size used by the app's file queue: 30 s at 16 kHz.
private let chunkSampleCount = 16000 * 30

@MainActor
struct TranscribeJob {
    let fileURL: URL
    let diarize: Bool
    let forcedLanguage: String?
    let modelVariant: String?

    func execute() async throws -> TranscribeResult {
        let transcriber = Transcriber()
        if let modelVariant,
           let picked = WhisperModel.all.first(where: { $0.variant == modelVariant }) {
            transcriber.selectModel(picked)
        }
        transcriber.preferredLanguage = forcedLanguage
        transcriber.onProgress = { status in
            let msg = status.message
            if !msg.isEmpty { logErr(msg) }
        }

        // Load the model (download on first run). Progress goes to stderr.
        logErr("Loading model \(transcriber.selectedModel.displayName)…")
        try await transcriber.preloadModel()
        transcriber.resetLanguageSession()

        guard let engine = transcriber.currentEngine as? any SampleTranscribing else {
            throw TranscriberError.modelNotReady
        }

        // 1. Extract PCM (16 kHz mono Float32).
        logErr("Extracting audio…")
        let samples = try await AudioExtractor.extractPCM(from: fileURL) { _ in }

        // 2. Chunked transcription, accumulating absolute-offset segments.
        var accumulatedText: [String] = []
        var accumulatedSegments: [WhisperSegment] = []
        var detectedLanguage: String? = nil

        if !samples.isEmpty {
            let totalChunks = max(1, Int(ceil(Double(samples.count) / Double(chunkSampleCount))))
            var cursor = 0
            var chunkIndex = 0
            while cursor < samples.count {
                let end = min(cursor + chunkSampleCount, samples.count)
                let chunk = Array(samples[cursor..<end])
                let chunkStartSeconds = Double(cursor) / 16000.0
                do {
                    let r = try await engine.transcribeSamples(
                        chunk, translate: false, language: forcedLanguage)
                    let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { accumulatedText.append(trimmed) }
                    for seg in r.segments {
                        accumulatedSegments.append(WhisperSegment(
                            start: seg.start + chunkStartSeconds,
                            end: seg.end + chunkStartSeconds,
                            text: seg.text))
                    }
                    if detectedLanguage == nil { detectedLanguage = r.detectedLanguage }
                } catch TranscriberError.silentAudio {
                    // Silent chunk — skip without failing the run.
                }
                chunkIndex += 1
                logErr("Transcribed chunk \(chunkIndex)/\(totalChunks)")
                cursor = end
            }
        }

        // 3. Optional single global diarization pass.
        var diarized: [DialogueSegment]? = nil
        if diarize, !accumulatedSegments.isEmpty {
            logErr("Diarizing (this may download speaker models on first run)…")
            let service = DiarizationService()
            do {
                let turns = try await service.diarize(
                    samples: samples,
                    sampleRate: DiarizationService.requiredSampleRate)
                let distinctSpeakers = Set(turns.map { $0.speakerIndex }).count
                logErr("Diarization: \(turns.count) turns, \(distinctSpeakers) distinct speaker(s)")
                if !turns.isEmpty {
                    let dialogue = accumulatedSegments.map { seg in
                        DialogueSegment(
                            speaker: .other,
                            start: seg.start,
                            end: seg.end,
                            text: seg.text,
                            language: detectedLanguage)
                    }
                    diarized = DiarizationService.assignSpeakers(to: dialogue, turns: turns)
                }
            } catch {
                logErr("Diarization failed (\(error.localizedDescription)); printing without speaker labels.")
            }
        }

        return TranscribeResult(
            sourceURL: fileURL,
            transcript: accumulatedText.joined(separator: " "),
            segments: accumulatedSegments,
            diarizedSegments: diarized,
            language: detectedLanguage,
            modelName: transcriber.selectedModel.displayName
        )
    }
}

// MARK: - Result

/// Outcome of a headless transcription. Holds both the raw `WhisperSegment`s and
/// (when diarization ran) the speaker-stamped `DialogueSegment`s, so the caller
/// can render plain, timestamped, or labelled output.
struct TranscribeResult: Sendable {
    let sourceURL: URL
    let transcript: String
    let segments: [WhisperSegment]
    let diarizedSegments: [DialogueSegment]?
    let language: String?
    let modelName: String

    /// True when diarization actually stamped at least one speaker.
    var hasSpeakers: Bool {
        guard let diarizedSegments else { return false }
        return diarizedSegments.contains { $0.speakerID != nil }
    }

    /// Dialogue view used by the merger formatters. When diarization ran, the
    /// stamped segments; otherwise plain `.other` segments built from the raw
    /// WhisperSegments so jsonl/human output still works.
    var dialogue: [DialogueSegment] {
        if let diarizedSegments { return diarizedSegments }
        return segments.map {
            DialogueSegment(speaker: .other, start: $0.start, end: $0.end,
                            text: $0.text, language: language)
        }
    }

    /// Persist into ~/Documents/Voicely/files via FileTranscriptWriter, the same
    /// writer the app uses. Runs on the main actor (writer is plain async but the
    /// central root comes from the @MainActor TranscriptStorage layout).
    func persist(timestamps: Bool, format: Transcribe.OutputFormat) async throws {
        let centralRoot = TranscriptStore.directory(for: .files)
        let options = FileTranscriptionOptions(
            content: timestamps ? .timestamps : .plain,
            format: format == .txt ? .plainText : .markdown,
            diarize: diarizedSegments != nil
        )
        let input = FileTranscriptWriter.Input(
            sourceURL: sourceURL,
            transcript: transcript,
            segments: segments,
            options: options,
            language: language,
            modelName: modelName,
            diarizedSegments: diarizedSegments
        )
        _ = try await FileTranscriptWriter.write(
            input: input,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )
    }
}
