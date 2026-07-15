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
private let cliChunkSampleCount = 16000 * 30

/// One ASR runtime per CLI process. The MCP server shares one instance across
/// concurrent requests, so they share both the loaded engine and its scheduler.
@MainActor
final class CLITranscriptionRuntime {
    let coordinator: TranscriptionCoordinator
    let transcriber: Transcriber
    private var diarizerStorage: (any FileDiarizing)?

    init(
        coordinator: TranscriptionCoordinator = TranscriptionCoordinator(),
        diarizer: (any FileDiarizing)? = nil
    ) {
        self.coordinator = coordinator
        self.transcriber = Transcriber(coordinator: coordinator)
        self.diarizerStorage = diarizer
    }

    /// Lazily creates one actor-isolated diarizer for the whole CLI process.
    /// MCP heavy admission is acquired before `execute` reaches this method, so
    /// rejected requests never instantiate the backend or trigger model work.
    func sharedDiarizer() -> any FileDiarizing {
        if let diarizerStorage { return diarizerStorage }
        let created = DiarizationService()
        diarizerStorage = created
        return created
    }
}

enum TranscribeJobError: LocalizedError, Equatable {
    case unknownModelVariant(String)
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .unknownModelVariant(let variant):
            return "Unknown model '\(variant)'. Use one of: \(WhisperModel.all.map(\.variant).joined(separator: ", "))."
        case .unsupportedLanguage(let language):
            return "Unsupported language '\(language)'. Use ru or en."
        }
    }
}

@MainActor
private final class CLITranscriptionAccumulator {
    var textFragments: [String] = []
    var segments: [WhisperSegment] = []
    var detectedLanguage: String?
    var completedChunks = 0
}

/// Testable result from the bounded file-processing core. The production CLI
/// returns only `result`; focused tests also assert the decoded-PCM high-water.
struct TranscribeJobExecution: Sendable {
    let result: TranscribeResult
    let maximumBufferedSamples: Int
}

@MainActor
struct TranscribeJob {
    let fileURL: URL
    let diarize: Bool
    let forcedLanguage: String?
    let modelVariant: String?

    func execute(runtime suppliedRuntime: CLITranscriptionRuntime? = nil) async throws -> TranscribeResult {
        try Task.checkCancellation()

        if let forcedLanguage, !["ru", "en"].contains(forcedLanguage) {
            throw TranscribeJobError.unsupportedLanguage(forcedLanguage)
        }
        let selectedModel: WhisperModel?
        if let modelVariant {
            guard let picked = WhisperModel.all.first(where: { $0.variant == modelVariant }) else {
                throw TranscribeJobError.unknownModelVariant(modelVariant)
            }
            selectedModel = picked
        } else {
            selectedModel = nil
        }

        let runtime = suppliedRuntime ?? CLITranscriptionRuntime()
        let transcriber = runtime.transcriber
        if let selectedModel {
            transcriber.selectModel(selectedModel)
        }
        transcriber.preferredLanguage = forcedLanguage
        transcriber.onProgress = { status in
            let msg = status.message
            if !msg.isEmpty { logErr(msg) }
        }

        // Freeze model, engine and request settings before the first await. A
        // concurrent MCP request may mutate the shared Transcriber while this
        // request waits for model preparation or an ASR lease.
        let session = try transcriber.makeSession(priority: .file)
        defer { transcriber.resetLanguageSession(session) }

        // Load the model (download on first run). Progress goes to stderr.
        logErr("Loading model \(session.model.displayName)…")
        try await transcriber.preloadModel(for: session)
        try Task.checkCancellation()

        let engine = transcriber.sampleTranscriber(for: session)

        let diarizer: (any FileDiarizing)? = diarize ? runtime.sharedDiarizer() : nil
        let execution = try await Self.processFile(
            sourceURL: fileURL,
            engine: engine,
            shouldDiarize: diarize,
            forcedLanguage: forcedLanguage,
            modelName: session.model.displayName,
            diarizer: diarizer,
            chunkSampleCount: cliChunkSampleCount
        )
        try Task.checkCancellation()
        return execution.result
    }

    /// Bounded file-processing core shared by the one-shot CLI and MCP tool.
    /// Decoding is backpressured: a chunk is fully transcribed before
    /// AudioExtractor requests more PCM from AVFoundation.
    static func processFile(
        sourceURL: URL,
        engine: any SampleTranscribing,
        shouldDiarize: Bool,
        forcedLanguage: String?,
        modelName: String,
        diarizer: (any FileDiarizing)?,
        chunkSampleCount: Int = cliChunkSampleCount
    ) async throws -> TranscribeJobExecution {
        try Task.checkCancellation()
        logErr("Extracting audio…")

        let accumulator = CLITranscriptionAccumulator()
        let streamSummary = try await AudioExtractor.streamPCM(
            from: sourceURL,
            chunkSampleCount: chunkSampleCount,
            onProgress: { _ in }
        ) { [accumulator] chunk in
            try await consume(
                chunk,
                engine: engine,
                forcedLanguage: forcedLanguage,
                configuredChunkSampleCount: max(1, chunkSampleCount),
                accumulator: accumulator
            )
        }
        try Task.checkCancellation()

        var diarizedSegments: [DialogueSegment]?
        if shouldDiarize,
           !accumulator.segments.isEmpty,
           let diarizer {
            logErr("Diarizing (this may download speaker models on first run)…")
            do {
                let turns = try await diarizer.diarize(fileURL: sourceURL)
                try Task.checkCancellation()
                let distinctSpeakers = Set(turns.map(\.speakerIndex)).count
                logErr("Diarization: \(turns.count) turns, \(distinctSpeakers) distinct speaker(s)")
                if !turns.isEmpty {
                    let dialogue = accumulator.segments.map { segment in
                        DialogueSegment(
                            speaker: .other,
                            start: segment.start,
                            end: segment.end,
                            text: segment.text,
                            language: accumulator.detectedLanguage
                        )
                    }
                    diarizedSegments = DiarizationService.assignSpeakers(
                        to: dialogue,
                        turns: turns
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logErr("Diarization failed (\(error.localizedDescription)); printing without speaker labels.")
            }
        }

        try Task.checkCancellation()
        let result = TranscribeResult(
            sourceURL: sourceURL,
            transcript: accumulator.textFragments.joined(separator: " "),
            segments: accumulator.segments,
            diarizedSegments: diarizedSegments,
            language: accumulator.detectedLanguage,
            modelName: modelName
        )
        try Task.checkCancellation()
        return TranscribeJobExecution(
            result: result,
            maximumBufferedSamples: streamSummary.maxBufferedSamples
        )
    }

    private static func consume(
        _ chunk: AudioExtractor.PCMChunk,
        engine: any SampleTranscribing,
        forcedLanguage: String?,
        configuredChunkSampleCount: Int,
        accumulator: CLITranscriptionAccumulator
    ) async throws {
        try Task.checkCancellation()
        do {
            let transcription = try await engine.transcribeSamples(
                chunk.samples,
                translate: false,
                language: forcedLanguage
            )
            try Task.checkCancellation()

            let trimmed = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                accumulator.textFragments.append(trimmed)
            }
            let chunkStartSeconds = Double(chunk.startSample) / AudioExtractor.outputSampleRate
            for segment in transcription.segments {
                accumulator.segments.append(WhisperSegment(
                    start: segment.start + chunkStartSeconds,
                    end: segment.end + chunkStartSeconds,
                    text: segment.text
                ))
            }
            if accumulator.detectedLanguage == nil {
                accumulator.detectedLanguage = transcription.detectedLanguage
            }
        } catch TranscriberError.silentAudio {
            // Silent chunk - skip without failing the run.
        } catch is CancellationError {
            throw CancellationError()
        }

        try Task.checkCancellation()
        accumulator.completedChunks += 1
        let estimatedTotalChunks: Int
        if chunk.estimatedTotalSamples > 0 {
            estimatedTotalChunks = max(
                1,
                Int(ceil(
                    Double(chunk.estimatedTotalSamples)
                        / Double(configuredChunkSampleCount)
                ))
            )
        } else {
            estimatedTotalChunks = accumulator.completedChunks
        }
        logErr(
            "Transcribed chunk \(accumulator.completedChunks)/"
                + "\(max(accumulator.completedChunks, estimatedTotalChunks))"
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
