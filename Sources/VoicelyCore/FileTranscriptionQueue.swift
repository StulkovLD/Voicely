import Foundation
import AVFoundation

/// Serial, main-actor-confined queue that runs file transcription jobs.
///
/// Wraps three collaborators:
/// - `AudioExtractor` to decode any source file into 16 kHz mono Float32 PCM.
/// - A `SampleTranscribing` engine (WhisperKit in production, mock in tests).
/// - `FileTranscriptWriter` to persist results next to the source + centrally.
///
/// Jobs are processed one at a time in insertion order. Individual file
/// failures do not stop the queue — the job is marked `.failed` and the
/// loop moves on. `TranscriberError.silentAudio` on a single chunk is
/// silently skipped (silent chunks should not sink the whole job).
///
/// Pause/resume/cancel are cooperative: the loop checks the flags between
/// chunks, so at most one chunk-worth of work runs past a request.
@MainActor
public final class FileTranscriptionQueue {

    // MARK: - Nested types

    public struct Job: Identifiable, Sendable {
        public let id: UUID
        public let sourceURL: URL
        public let options: FileTranscriptionOptions
        public var status: Status

        public init(
            id: UUID = UUID(),
            sourceURL: URL,
            options: FileTranscriptionOptions,
            status: Status = .pending
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.options = options
            self.status = status
        }
    }

    public enum Status: Sendable {
        case pending
        case extracting
        case transcribing(progress: Double)
        case writing
        case completed(nextToSourceURL: URL?, centralURL: URL)
        case failed(String)
        /// Job was cancelled via `cancelAll()` before it could finish. Distinct
        /// from `.failed` so the UI can hide itself instead of reporting errors.
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .pending, .extracting, .transcribing, .writing: return false
            }
        }
    }

    public enum QueueState: Sendable, Equatable {
        case idle
        case processing(currentIndex: Int, total: Int)
        case paused(currentIndex: Int, total: Int)
    }

    // MARK: - Inputs

    private let transcriber: any SampleTranscribing
    private let modelName: String
    private let centralRoot: URL
    private let chunkSampleCount: Int
    /// Optional speaker-diarization backend. When nil, the "Identify speakers"
    /// option is silently a no-op (tests construct the queue without one). When
    /// present, a job whose options request `diarize` runs a single global pass
    /// over the whole file before writing.
    private let diarizer: DiarizationService?

    // MARK: - Mutable state (main-actor isolated)

    public private(set) var jobs: [Job] = []
    private var runTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var lastNotifiedState: QueueState?
    /// True while a `transcribeSamples` call is in flight on the engine.
    /// `awaitPaused()` polls this so dictation can safely run the engine.
    private var isEngineBusy: Bool = false

    public var onStateChange: (@MainActor @Sendable (QueueState, [Job]) -> Void)?

    // MARK: - Init

    public init(
        transcriber: any SampleTranscribing,
        modelName: String,
        centralRoot: URL,
        chunkSampleCount: Int = 16000 * 30,
        diarizer: DiarizationService? = nil
    ) {
        self.transcriber = transcriber
        self.modelName = modelName
        self.centralRoot = centralRoot
        self.chunkSampleCount = max(1, chunkSampleCount)
        self.diarizer = diarizer
    }

    // MARK: - Public API

    public func enqueue(_ urls: [URL], options: FileTranscriptionOptions) {
        for url in urls {
            jobs.append(Job(sourceURL: url, options: options))
        }
        // New work clears any stale "idle" dedupe so the next idle still fires.
        if !jobs.isEmpty { lastNotifiedState = nil }
        // Don't emit a state-change here: either the run loop is already
        // running and will notify on its own, or we're about to start it
        // and it will notify from processJob. Emitting now would produce a
        // phantom .processing callback before any real work began.
        if runTask == nil {
            runTask = Task { [weak self] in
                await self?.runLoop()
            }
        }
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        notifyState()
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if let cont = resumeContinuation {
            resumeContinuation = nil
            cont.resume()
        }
        notifyState()
    }

    public func cancelAll() {
        runTask?.cancel()
        runTask = nil
        // Mark non-terminal jobs as .cancelled so the UI can tell a
        // user-initiated stop apart from a real failure.
        for i in jobs.indices {
            if !jobs[i].status.isTerminal {
                jobs[i].status = .cancelled
            }
        }
        // Release any pending pause wait so the loop can unwind.
        isPaused = false
        isEngineBusy = false
        if let cont = resumeContinuation {
            resumeContinuation = nil
            cont.resume()
        }
        notifyState(force: .idle)
        jobs.removeAll()
    }

    /// Wait until the queue is actually paused AND no transcribe call is
    /// in flight on the engine. Returns false if the deadline passes first.
    ///
    /// Call this from code paths that are about to use the WhisperKit engine
    /// (dictation transcribe, call transcribe) to avoid racing with an
    /// in-flight chunk.
    public func awaitPaused() async -> Bool {
        // Queue already finished — engine is free by definition.
        if runTask == nil { return true }
        let maxPolls = 100  // 100 × 50 ms = 5 s
        for _ in 0..<maxPolls {
            if runTask == nil { return true }
            if isPaused && !isEngineBusy { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Run loop

    private func runLoop() async {
        var index = 0
        while index < jobs.count {
            if Task.isCancelled { return }
            await waitIfPaused(currentIndex: index)
            if Task.isCancelled { return }

            do {
                try await processJob(at: index)
            } catch is CancellationError {
                return
            } catch {
                jobs[index].status = .failed(error.localizedDescription)
                notifyState()
            }

            index += 1
        }
        // Loop done.
        runTask = nil
        notifyState(force: .idle)
    }

    private func processJob(at index: Int) async throws {
        // 1. Extract audio
        jobs[index].status = .extracting
        notifyState()

        let samples = try await AudioExtractor.extractPCM(
            from: jobs[index].sourceURL,
            onProgress: { _ in }
        )

        if Task.isCancelled { throw CancellationError() }
        await waitIfPaused(currentIndex: index)
        if Task.isCancelled { throw CancellationError() }

        // 2. Chunk + transcribe
        let chunkSize = chunkSampleCount
        let totalChunks = samples.isEmpty
            ? 0
            : max(1, Int(ceil(Double(samples.count) / Double(chunkSize))))

        var accumulatedText: [String] = []
        var accumulatedSegments: [WhisperSegment] = []
        var detectedLanguage: String? = nil

        if totalChunks > 0 {
            var chunkIndex = 0
            var cursor = 0
            while cursor < samples.count {
                if Task.isCancelled { throw CancellationError() }
                await waitIfPaused(currentIndex: index)
                if Task.isCancelled { throw CancellationError() }

                let end = min(cursor + chunkSize, samples.count)
                let chunk = Array(samples[cursor..<end])
                let chunkStartSeconds = Double(cursor) / 16000.0

                do {
                    let result = try await callTranscribe(chunk)
                    let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        accumulatedText.append(trimmed)
                    }
                    for seg in result.segments {
                        accumulatedSegments.append(WhisperSegment(
                            start: seg.start + chunkStartSeconds,
                            end: seg.end + chunkStartSeconds,
                            text: seg.text
                        ))
                    }
                    if detectedLanguage == nil {
                        detectedLanguage = result.detectedLanguage
                    }
                } catch TranscriberError.silentAudio {
                    // Silent chunk — skip without failing the job.
                } catch is CancellationError {
                    throw CancellationError()
                }
                // Any other error bubbles up and fails the job.

                chunkIndex += 1
                let progress = Double(chunkIndex) / Double(totalChunks)
                jobs[index].status = .transcribing(progress: progress)
                notifyState()

                cursor = end
            }
        }

        if Task.isCancelled { throw CancellationError() }
        await waitIfPaused(currentIndex: index)
        if Task.isCancelled { throw CancellationError() }

        // 3. Optional diarization (single global pass over the whole file).
        //    Runs after transcription so the progress bar reaches 100% first;
        //    the brief stall here is end-of-job only. `samples` are already
        //    16 kHz mono Float32 (AudioExtractor's output), the same timeline as
        //    the accumulated segments' absolute offsets, so the stamped speaker
        //    turns line up with `assignSpeakers`. Any failure degrades to an
        //    unlabelled transcript — it never sinks the job or the queue.
        //    Surface the `.writing` phase up front so the (possibly slow, first-
        //    run model download) pass shows activity instead of a frozen bar.
        jobs[index].status = .writing
        notifyState()

        let diarizedSegments = await diarizeIfRequested(
            options: jobs[index].options,
            samples: samples,
            segments: accumulatedSegments,
            language: detectedLanguage
        )

        if Task.isCancelled { throw CancellationError() }
        await waitIfPaused(currentIndex: index)
        if Task.isCancelled { throw CancellationError() }

        // 4. Write
        let joinedText = accumulatedText.joined(separator: " ")
        let writerInput = FileTranscriptWriter.Input(
            sourceURL: jobs[index].sourceURL,
            transcript: joinedText,
            segments: accumulatedSegments,
            options: jobs[index].options,
            language: detectedLanguage,
            modelName: modelName,
            diarizedSegments: diarizedSegments
        )

        let result = try await FileTranscriptWriter.write(
            input: writerInput,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )

        jobs[index].status = .completed(
            nextToSourceURL: result.nextToSourceURL,
            centralURL: result.centralURL
        )
        notifyState()
    }

    // MARK: - Diarization

    /// Run a single global diarization pass when the job requested it and a
    /// backend is wired. Returns the speaker-stamped segments (one per
    /// `WhisperSegment`, same chronological order and timeline) for the writer,
    /// or nil to render an unlabelled transcript.
    ///
    /// Failure modes that all degrade gracefully to nil (job still completes):
    /// - diarization not requested, or no backend injected;
    /// - no segments to label (nothing to attribute);
    /// - the diarization pass throws (models unavailable, OOM on a huge file,
    ///   read failure) — logged, transcript written without speaker labels.
    private func diarizeIfRequested(
        options: FileTranscriptionOptions,
        samples: [Float],
        segments: [WhisperSegment],
        language: String?
    ) async -> [DialogueSegment]? {
        guard options.diarize, let diarizer, !segments.isEmpty else { return nil }

        let turns: [SpeakerTurn]
        do {
            turns = try await diarizer.diarize(
                samples: samples,
                sampleRate: DiarizationService.requiredSampleRate
            )
        } catch {
            // Heavy one-pass diarization can fail on giant files (RAM/time) or
            // when models can't be fetched. Keep the transcript; drop the labels.
            NSLog("FileTranscriptionQueue: diarization failed, writing without speaker labels: \(error.localizedDescription)")
            return nil
        }

        guard !turns.isEmpty else { return nil }

        // One DialogueSegment per WhisperSegment, sharing the file timeline.
        // `speaker` is .other purely to satisfy the type; file transcription has
        // no local "You" channel and the writer reads only `speakerID`.
        let dialogue = segments.map { seg in
            DialogueSegment(
                speaker: .other,
                start: seg.start,
                end: seg.end,
                text: seg.text,
                language: language
            )
        }
        return DiarizationService.assignSpeakers(to: dialogue, turns: turns)
    }

    /// Wrapper around `transcribeSamples` that tracks engine busy state so
    /// `awaitPaused()` can tell callers when the engine is actually free.
    private func callTranscribe(_ chunk: [Float]) async throws -> WhisperTranscription {
        isEngineBusy = true
        defer { isEngineBusy = false }
        return try await transcriber.transcribeSamples(
            chunk, translate: false, language: nil)
    }

    // MARK: - Pause coordination

    private func waitIfPaused(currentIndex: Int) async {
        guard isPaused else { return }
        notifyState(force: .paused(currentIndex: currentIndex, total: jobs.count))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // If resume() was called in between, fire immediately.
            if !isPaused {
                cont.resume()
                return
            }
            resumeContinuation = cont
        }
    }

    // MARK: - State notification

    private func notifyState(force: QueueState? = nil) {
        let resolved: QueueState = force ?? derivedState()
        // Dedupe terminal idle so fulfill/expectation callbacks don't fire twice.
        if case .idle = resolved, case .idle = lastNotifiedState { return }
        lastNotifiedState = resolved
        onStateChange?(resolved, jobs)
    }

    private func derivedState() -> QueueState {
        // Find the first non-terminal job; that's our "current".
        if let idx = jobs.firstIndex(where: { !$0.status.isTerminal }) {
            if isPaused {
                return .paused(currentIndex: idx, total: jobs.count)
            }
            return .processing(currentIndex: idx, total: jobs.count)
        }
        return .idle
    }
}
