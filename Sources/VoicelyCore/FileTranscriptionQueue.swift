import Foundation
import AVFoundation

@MainActor
private final class FileTranscriptionAccumulator {
    var textFragments: [String] = []
    var segments: [WhisperSegment] = []
    var detectedLanguage: String?
}

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

    /// Immutable ASR semantics captured when a file enters the queue. Menu
    /// changes made while an earlier file is running cannot alter queued work.
    public struct RequestSettings: Sendable, Equatable {
        public let modelName: String
        public let translateToEnglish: Bool
        public let preferredLanguage: String?

        public init(
            modelName: String,
            translateToEnglish: Bool,
            preferredLanguage: String?
        ) {
            self.modelName = modelName
            self.translateToEnglish = translateToEnglish
            self.preferredLanguage = preferredLanguage
        }
    }

    public struct Job: Identifiable, Sendable {
        public let id: UUID
        public let sourceURL: URL
        public let options: FileTranscriptionOptions
        public let requestSettings: RequestSettings
        public var status: Status

        public init(
            id: UUID = UUID(),
            sourceURL: URL,
            options: FileTranscriptionOptions,
            requestSettings: RequestSettings,
            status: Status = .pending
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.options = options
            self.requestSettings = requestSettings
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
    private let defaultRequestSettings: RequestSettings
    private let centralRoot: URL
    private let chunkSampleCount: Int
    private let coordinator: TranscriptionCoordinator
    /// Optional speaker-diarization backend. When nil, the "Identify speakers"
    /// option is silently a no-op (tests construct the queue without one). When
    /// present, a job whose options request `diarize` runs a single global pass
    /// over the whole file before writing.
    private let diarizer: (any FileDiarizing)?

    // MARK: - Mutable state (main-actor isolated)

    public private(set) var jobs: [Job] = []
    private var runTask: Task<Void, Never>?
    /// Monotonic ownership token for the task currently allowed to mutate queue
    /// state. A cancelled task keeps this token until it has actually unwound;
    /// enqueueing more work cannot make a stale task the owner of a new batch.
    private var nextRunGeneration: UInt64 = 0
    private var activeRunGeneration: UInt64?
    /// Jobs present when `cancelAll()` was requested. They remain addressable
    /// until the cancelled task exits, then are removed as one batch. Jobs
    /// enqueued while cancellation drains are deliberately not included.
    private var cancelledJobIDs: Set<UUID> = []
    private var isPaused: Bool = false
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var lastNotifiedState: QueueState?
    /// True while a `transcribeSamples` call is in flight on the engine.
    /// `awaitPaused()` polls this so dictation can safely run the engine.
    private var isEngineBusy: Bool = false
    /// Diagnostic high-water mark for decoded PCM retained by the streaming
    /// extractor during the latest job. Internal so tests can enforce the bound.
    private(set) var maximumBufferedSamplesObserved: Int = 0

    public var onStateChange: (@MainActor @Sendable (QueueState, [Job]) -> Void)?

    // MARK: - Init

    public init(
        transcriber: any SampleTranscribing,
        modelName: String,
        centralRoot: URL,
        chunkSampleCount: Int = 16000 * 30,
        coordinator: TranscriptionCoordinator = TranscriptionCoordinator(),
        diarizer: (any FileDiarizing)? = nil
    ) {
        self.transcriber = transcriber
        self.defaultRequestSettings = RequestSettings(
            modelName: modelName,
            translateToEnglish: false,
            preferredLanguage: nil
        )
        self.centralRoot = centralRoot
        self.chunkSampleCount = max(1, chunkSampleCount)
        self.coordinator = coordinator
        self.diarizer = diarizer
    }

    // MARK: - Public API

    public func enqueue(
        _ urls: [URL],
        options: FileTranscriptionOptions,
        requestSettings: RequestSettings? = nil
    ) {
        // Starting a fresh batch (run loop idle): drop the previous batch's
        // finished jobs first. The loop walks `jobs` by index from 0, so a
        // leftover terminal job would be re-transcribed and the n/total counter
        // would still include the old batch. Mid-batch enqueues (runTask != nil)
        // keep the running jobs intact and just append.
        if runTask == nil {
            jobs.removeAll { $0.status.isTerminal }
        }
        let settingsSnapshot = requestSettings ?? defaultRequestSettings
        for url in urls {
            jobs.append(Job(
                sourceURL: url,
                options: options,
                requestSettings: settingsSnapshot
            ))
        }
        // New work clears any stale "idle" dedupe so the next idle still fires.
        if !jobs.isEmpty { lastNotifiedState = nil }
        // Don't emit a state-change here: either the run loop is already
        // running and will notify on its own, or we're about to start it
        // and it will notify from processJob. Emitting now would produce a
        // phantom .processing callback before any real work began.
        startRunIfNeeded()
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
        guard let runTask else {
            jobs.removeAll()
            notifyState(force: .idle)
            return
        }

        // Do not clear `runTask`, the engine-busy flag, or the jobs here. Some
        // model and writer backends ignore cooperative cancellation. The task
        // remains the sole owner until its awaited operation really returns.
        cancelledJobIDs.formUnion(jobs.map(\.id))
        // Mark non-terminal jobs as .cancelled so the UI can tell a
        // user-initiated stop apart from a real failure.
        for i in jobs.indices {
            if !jobs[i].status.isTerminal {
                jobs[i].status = .cancelled
            }
        }
        // Release any pending pause wait so the loop can unwind.
        isPaused = false
        if let cont = resumeContinuation {
            resumeContinuation = nil
            cont.resume()
        }
        runTask.cancel()
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

    private func startRunIfNeeded() {
        guard runTask == nil,
              jobs.contains(where: { !$0.status.isTerminal }) else { return }

        nextRunGeneration &+= 1
        let generation = nextRunGeneration
        activeRunGeneration = generation
        runTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: UInt64) async {
        defer { finishRun(generation: generation) }
        var index = 0
        while index < jobs.count {
            guard activeRunGeneration == generation, !Task.isCancelled else { return }
            await waitIfPaused(currentIndex: index)
            guard activeRunGeneration == generation, !Task.isCancelled else { return }

            // Enqueues only append while a run is active, so this identity is
            // stable even when more jobs arrive while the current await runs.
            let jobID = jobs[index].id

            do {
                try await processJob(id: jobID, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let currentIndex = mutableJobIndex(
                    id: jobID,
                    generation: generation
                ) else { return }
                jobs[currentIndex].status = .failed(error.localizedDescription)
                notifyState()
            }

            index += 1
        }
    }

    private func finishRun(generation: UInt64) {
        guard activeRunGeneration == generation else { return }

        runTask = nil
        activeRunGeneration = nil
        // Every engine call has returned before runLoop reaches this point.
        isEngineBusy = false

        let cancelledSnapshot = jobs.filter { cancelledJobIDs.contains($0.id) }
        if !cancelledJobIDs.isEmpty {
            jobs.removeAll { cancelledJobIDs.contains($0.id) }
            cancelledJobIDs.removeAll()
        }

        if jobs.contains(where: { !$0.status.isTerminal }) {
            // Work enqueued while a cancellation-ignoring backend was draining
            // starts only after that backend released the old generation.
            startRunIfNeeded()
            return
        }

        if !cancelledSnapshot.isEmpty {
            // Preserve the historical callback contract: observers receive the
            // cancelled statuses once, but only after the old task is truly idle.
            if case .idle = lastNotifiedState { return }
            lastNotifiedState = .idle
            onStateChange?(.idle, cancelledSnapshot)
        } else {
            notifyState(force: .idle)
        }
    }

    private func processJob(id jobID: UUID, generation: UInt64) async throws {
        let index = try requireMutableJobIndex(id: jobID, generation: generation)
        // Defensive: never re-run a job already in a terminal state. `enqueue`
        // prunes finished jobs before a fresh batch, but the loop advances by
        // index — this guard makes re-transcribing a completed file impossible
        // even if a terminal job ever survives into the array.
        guard !jobs[index].status.isTerminal else { return }
        let requestSettings = jobs[index].requestSettings
        let sessionID = TranscriptionCoordinator.SessionID(rawValue: jobID)
        defer {
            (transcriber as? any SessionLanguageResettable)?
                .resetLanguageSession(sessionID)
        }

        // 1. Stream-decode + transcribe. AudioExtractor applies backpressure:
        // AVFoundation does not decode the next buffer until this chunk returns.
        jobs[index].status = .extracting
        notifyState()

        let accumulator = FileTranscriptionAccumulator()
        maximumBufferedSamplesObserved = 0

        let streamSummary = try await AudioExtractor.streamPCM(
            from: jobs[index].sourceURL,
            chunkSampleCount: chunkSampleCount,
            onProgress: { _ in }
        ) { [weak self, accumulator] chunk in
            guard let self else { throw CancellationError() }
            try await self.transcribeStreamedChunk(
                chunk,
                jobID: jobID,
                generation: generation,
                requestSettings: requestSettings,
                accumulator: accumulator
            )
        }
        _ = try requireMutableJobIndex(id: jobID, generation: generation)
        maximumBufferedSamplesObserved = max(
            maximumBufferedSamplesObserved,
            streamSummary.maxBufferedSamples
        )
        if streamSummary.chunkCount > 0 {
            jobs[index].status = .transcribing(progress: 1)
            notifyState()
        }

        try requireRunOwnership(generation: generation)
        await waitIfPaused(currentIndex: index)
        _ = try requireMutableJobIndex(id: jobID, generation: generation)

        let accumulatedText = accumulator.textFragments
        let accumulatedSegments = accumulator.segments
        let outputLanguage = requestSettings.translateToEnglish
            ? "en"
            : requestSettings.preferredLanguage ?? accumulator.detectedLanguage

        // 2. Optional diarization (single global disk-backed pass).
        //    Runs after transcription so the progress bar reaches 100% first;
        //    the brief stall here is end-of-job only. Chunk PCM has already been
        //    released; FluidAudio maps/streams from the source URL instead of
        //    materializing another full-file `[Float]`. Any failure degrades to
        //    an unlabelled transcript — it never sinks the job or the queue.
        //    Surface the `.writing` phase up front so the (possibly slow, first-
        //    run model download) pass shows activity instead of a frozen bar.
        jobs[index].status = .writing
        notifyState()

        let diarizedSegments = try await diarizeIfRequested(
            options: jobs[index].options,
            sourceURL: jobs[index].sourceURL,
            segments: accumulatedSegments,
            language: outputLanguage
        )

        _ = try requireMutableJobIndex(id: jobID, generation: generation)
        await waitIfPaused(currentIndex: index)
        _ = try requireMutableJobIndex(id: jobID, generation: generation)

        // 3. Write
        let joinedText = accumulatedText.joined(separator: " ")
        let writerInput = FileTranscriptWriter.Input(
            sourceURL: jobs[index].sourceURL,
            transcript: joinedText,
            segments: accumulatedSegments,
            options: jobs[index].options,
            language: outputLanguage,
            modelName: requestSettings.modelName,
            diarizedSegments: diarizedSegments
        )

        let result = try await FileTranscriptWriter.write(
            input: writerInput,
            centralRoot: centralRoot,
            onNextToSourceFailure: { _, _ in nil }
        )

        let completionIndex = try requireMutableJobIndex(
            id: jobID,
            generation: generation
        )

        jobs[completionIndex].status = .completed(
            nextToSourceURL: result.nextToSourceURL,
            centralURL: result.centralURL
        )
        notifyState()
    }

    private func transcribeStreamedChunk(
        _ chunk: AudioExtractor.PCMChunk,
        jobID: UUID,
        generation: UInt64,
        requestSettings: RequestSettings,
        accumulator: FileTranscriptionAccumulator
    ) async throws {
        var index = try requireMutableJobIndex(id: jobID, generation: generation)
        await waitIfPaused(currentIndex: index)
        index = try requireMutableJobIndex(id: jobID, generation: generation)

        maximumBufferedSamplesObserved = max(
            maximumBufferedSamplesObserved,
            chunk.samples.count
        )
        let chunkStartSeconds = Double(chunk.startSample) / AudioExtractor.outputSampleRate

        do {
            let sessionID = TranscriptionCoordinator.SessionID(rawValue: jobID)
            let result = try await callTranscribe(
                chunk.samples,
                sessionID: sessionID,
                jobID: jobID,
                generation: generation,
                requestSettings: requestSettings
            )
            index = try requireMutableJobIndex(id: jobID, generation: generation)
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                accumulator.textFragments.append(trimmed)
            }
            for segment in result.segments {
                accumulator.segments.append(WhisperSegment(
                    start: segment.start + chunkStartSeconds,
                    end: segment.end + chunkStartSeconds,
                    text: segment.text
                ))
            }
            if accumulator.detectedLanguage == nil {
                accumulator.detectedLanguage = result.detectedLanguage
            }
        } catch TranscriberError.silentAudio {
            // Silent chunk — skip without failing the job.
        } catch is CancellationError {
            throw CancellationError()
        }
        // Any other error bubbles up and fails the job.

        index = try requireMutableJobIndex(id: jobID, generation: generation)
        jobs[index].status = .transcribing(progress: chunk.progress)
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
        sourceURL: URL,
        segments: [WhisperSegment],
        language: String?
    ) async throws -> [DialogueSegment]? {
        guard options.diarize, let diarizer, !segments.isEmpty else { return nil }

        let turns: [SpeakerTurn]
        do {
            turns = try await diarizer.diarize(fileURL: sourceURL)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
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
    private func callTranscribe(
        _ chunk: [Float],
        sessionID: TranscriptionCoordinator.SessionID,
        jobID: UUID,
        generation: UInt64,
        requestSettings: RequestSettings
    ) async throws -> WhisperTranscription {
        isEngineBusy = true
        defer { isEngineBusy = false }
        let result = try await coordinator.withLease(
            sessionID: sessionID,
            priority: .file
        ) {
            if let sessionTranscriber = transcriber as? any SessionSampleTranscribing {
                return try await sessionTranscriber.transcribeSamples(
                    chunk,
                    translate: requestSettings.translateToEnglish,
                    language: requestSettings.preferredLanguage,
                    sessionID: sessionID
                )
            }
            return try await transcriber.transcribeSamples(
                chunk,
                translate: requestSettings.translateToEnglish,
                language: requestSettings.preferredLanguage
            )
        }
        _ = try requireMutableJobIndex(id: jobID, generation: generation)
        return result
    }

    // MARK: - Run ownership

    private func requireRunOwnership(generation: UInt64) throws {
        try Task.checkCancellation()
        guard activeRunGeneration == generation else {
            throw CancellationError()
        }
    }

    private func requireMutableJobIndex(
        id: UUID,
        generation: UInt64
    ) throws -> Int {
        try requireRunOwnership(generation: generation)
        guard !cancelledJobIDs.contains(id),
              let index = jobs.firstIndex(where: { $0.id == id }),
              !jobs[index].status.isTerminal else {
            throw CancellationError()
        }
        return index
    }

    private func mutableJobIndex(
        id: UUID,
        generation: UInt64
    ) -> Int? {
        guard !Task.isCancelled,
              activeRunGeneration == generation,
              !cancelledJobIDs.contains(id),
              let index = jobs.firstIndex(where: { $0.id == id }),
              !jobs[index].status.isTerminal else { return nil }
        return index
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
