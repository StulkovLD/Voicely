import AVFoundation
import Foundation
import XCTest
@testable import VoicelyCore

private actor RuntimeGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalCount = 0

    func wait() async {
        arrivalCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseNext() -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().resume()
        return true
    }

    func arrivals() -> Int {
        arrivalCount
    }
}

private actor RuntimeProbe {
    struct Invocation: Sendable, Equatable {
        let label: String
        let sessionID: TranscriptionCoordinator.SessionID
        let translate: Bool
        let language: String?
    }

    private var activeCount = 0
    private var maximumActiveCount = 0
    private var invocations: [Invocation] = []

    func enter(_ invocation: Invocation) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        invocations.append(invocation)
    }

    func leave() {
        activeCount -= 1
    }

    func result() -> (maximum: Int, invocations: [Invocation]) {
        (maximumActiveCount, invocations)
    }
}

private final class IntegrationFakeEngine: SessionTranscriberEngine,
    SessionSampleTranscribing,
    SessionLanguageResettable, @unchecked Sendable {

    private let label: String
    private let probe: RuntimeProbe
    private let gate: RuntimeGate?
    private let blocksFirstCallOnly: Bool
    private let compatibilitySessionID = TranscriptionCoordinator.SessionID()
    private let lock = NSLock()
    private var callCount = 0
    private var languages: [TranscriptionCoordinator.SessionID: String] = [:]

    init(
        label: String,
        probe: RuntimeProbe,
        gate: RuntimeGate? = nil,
        blocksFirstCallOnly: Bool = false
    ) {
        self.label = label
        self.probe = probe
        self.gate = gate
        self.blocksFirstCallOnly = blocksFirstCallOnly
    }

    func transcribe(
        audio _: AVAudioPCMBuffer,
        translate: Bool,
        language: String?
    ) async throws -> String {
        let result = try await transcribeSamples(
            [0.1],
            translate: translate,
            language: language,
            sessionID: compatibilitySessionID
        )
        return result.text
    }

    func transcribe(
        audio _: AVAudioPCMBuffer,
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> String {
        let result = try await transcribeSamples(
            [0.1],
            translate: translate,
            language: language,
            sessionID: sessionID
        )
        return result.text
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?
    ) async throws -> WhisperTranscription {
        try await transcribeSamples(
            samples,
            translate: translate,
            language: language,
            sessionID: compatibilitySessionID
        )
    }

    func transcribeSamples(
        _ samples: [Float],
        translate: Bool,
        language: String?,
        sessionID: TranscriptionCoordinator.SessionID
    ) async throws -> WhisperTranscription {
        let callIndex = withLock { () -> Int in
            let current = callCount
            callCount += 1
            if let language {
                languages[sessionID] = language
            } else if languages[sessionID] == nil {
                languages[sessionID] = "auto-\(label)"
            }
            return current
        }

        await probe.enter(RuntimeProbe.Invocation(
            label: label,
            sessionID: sessionID,
            translate: translate,
            language: language
        ))

        if let gate, !blocksFirstCallOnly || callIndex == 0 {
            await gate.wait()
        }

        await probe.leave()
        let detectedLanguage = withLock { languages[sessionID] }
        return WhisperTranscription(
            text: "\(label)-\(callIndex)",
            segments: [
                WhisperSegment(start: 0, end: 0.5, text: "\(label)-\(callIndex)")
            ],
            detectedLanguage: detectedLanguage
        )
    }

    func resetLanguageSession(_ sessionID: TranscriptionCoordinator.SessionID) {
        _ = withLock {
            languages.removeValue(forKey: sessionID)
        }
    }

    func language(for sessionID: TranscriptionCoordinator.SessionID) -> String? {
        withLock { languages[sessionID] }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

@MainActor
final class TranscriptionRuntimeIntegrationTests: XCTestCase {

    /// Whisper left the shipped catalog (owner's call, 2026-08-19); these
    /// integration tests exercise the runtime with fake engines, so the model
    /// is only a settings carrier — pinned here as a fixture.
    static func whisperFixture(variant: String) -> WhisperModel {
        WhisperModel(
            variant: variant,
            displayName: variant,
            sizeLabel: "~1 MB",
            sizeBytes: 1_000_000,
            minRAMGB: 8,
            backend: .whisperKit
        )
    }

    private func waitUntil(
        _ message: String,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail(message)
        return false
    }

    private func makeTranscriber(
        coordinator: TranscriptionCoordinator,
        model: WhisperModel,
        engine: IntegrationFakeEngine
    ) -> Transcriber {
        Transcriber(
            coordinator: coordinator,
            selectedModel: model,
            engineFactory: { _, _ in engine }
        )
    }

    func testConcurrentMCPStyleSessionsNeverOverlapSharedEngine() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = RuntimeGate()
        let probe = RuntimeProbe()
        let engine = IntegrationFakeEngine(
            label: "mcp",
            probe: probe,
            gate: gate,
            blocksFirstCallOnly: true
        )
        let model = Self.whisperFixture(variant: "large-v3_turbo")
        let transcriber = makeTranscriber(
            coordinator: coordinator,
            model: model,
            engine: engine
        )
        let firstSession = try transcriber.makeSession(priority: .file)
        let secondSession = try transcriber.makeSession(priority: .file)
        let firstEngine = transcriber.sampleTranscriber(for: firstSession)
        let secondEngine = transcriber.sampleTranscriber(for: secondSession)

        let first = Task {
            try await firstEngine.transcribeSamples(
                [0.1], translate: false, language: nil)
        }
        guard await waitUntil("first MCP-style request did not enter engine", condition: {
            await gate.arrivals() == 1
        }) else { return }

        let second = Task {
            try await secondEngine.transcribeSamples(
                [0.1], translate: false, language: nil)
        }
        guard await waitUntil("second MCP-style request was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [secondSession.id]
        }) else { return }

        let whileBlocked = await probe.result()
        XCTAssertEqual(whileBlocked.maximum, 1)
        XCTAssertEqual(whileBlocked.invocations.map(\.sessionID), [firstSession.id])

        let released = await gate.releaseNext()
        XCTAssertTrue(released)
        _ = try await first.value
        _ = try await second.value

        let result = await probe.result()
        XCTAssertEqual(result.maximum, 1)
        XCTAssertEqual(
            result.invocations.map(\.sessionID),
            [firstSession.id, secondSession.id]
        )
    }

    func testLiveSnapshotRunsBeforeEarlierFileSnapshots() async throws {
        let coordinator = TranscriptionCoordinator()
        let holder = try await coordinator.acquire(
            sessionID: TranscriptionCoordinator.SessionID(),
            priority: .background
        )
        let probe = RuntimeProbe()
        let engine = IntegrationFakeEngine(label: "priority", probe: probe)
        let model = Self.whisperFixture(variant: "large-v3_turbo")
        let transcriber = makeTranscriber(
            coordinator: coordinator,
            model: model,
            engine: engine
        )
        let firstFile = try transcriber.makeSession(priority: .file)
        let secondFile = try transcriber.makeSession(priority: .file)
        let live = try transcriber.makeSession(priority: .live)

        let firstTask = Task {
            try await transcriber.sampleTranscriber(for: firstFile)
                .transcribeSamples([0.1], translate: false, language: nil)
        }
        guard await waitUntil("first file snapshot was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [firstFile.id]
        }) else { return }

        let secondTask = Task {
            try await transcriber.sampleTranscriber(for: secondFile)
                .transcribeSamples([0.1], translate: false, language: nil)
        }
        guard await waitUntil("second file snapshot was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [firstFile.id, secondFile.id]
        }) else { return }

        let liveTask = Task {
            try await transcriber.sampleTranscriber(for: live)
                .transcribeSamples([0.1], translate: false, language: nil)
        }
        guard await waitUntil("live snapshot was not prioritized", condition: {
            await coordinator.snapshot().queuedSessionIDs
                == [live.id, firstFile.id, secondFile.id]
        }) else { return }

        let releasedHolder = await coordinator.release(holder)
        XCTAssertTrue(releasedHolder)
        _ = try await liveTask.value
        _ = try await firstTask.value
        _ = try await secondTask.value

        let result = await probe.result()
        XCTAssertEqual(
            result.invocations.map(\.sessionID),
            [live.id, firstFile.id, secondFile.id]
        )
    }

    func testQueuedSessionKeepsOriginalSettingsModelAndEngine() async throws {
        let defaults = WhisperModel.SharedDefaults.store
        let previousSavedModel = defaults.string(forKey: "whisperModel")
        defer {
            if let previousSavedModel {
                defaults.set(previousSavedModel, forKey: "whisperModel")
            } else {
                defaults.removeObject(forKey: "whisperModel")
            }
        }

        let coordinator = TranscriptionCoordinator()
        let holder = try await coordinator.acquire(
            sessionID: TranscriptionCoordinator.SessionID(),
            priority: .background
        )
        let probeA = RuntimeProbe()
        let probeB = RuntimeProbe()
        let engineA = IntegrationFakeEngine(label: "A", probe: probeA)
        let engineB = IntegrationFakeEngine(label: "B", probe: probeB)
        let modelA = Self.whisperFixture(variant: "large-v3_turbo")
        let modelB = Self.whisperFixture(variant: "medium")
        let transcriber = Transcriber(
            coordinator: coordinator,
            selectedModel: modelA,
            engineFactory: { model, _ in
                model == modelA ? engineA : engineB
            }
        )
        transcriber.preferredLanguage = "ru"
        transcriber.translateToEnglish = false
        let session = try transcriber.makeSession(priority: .file)
        let sessionEngine = transcriber.sampleTranscriber(for: session)

        let task = Task {
            try await sessionEngine.transcribeSamples(
                [0.1], translate: true, language: "en")
        }
        guard await waitUntil("snapshotted request was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [session.id]
        }) else { return }

        transcriber.preferredLanguage = "en"
        transcriber.translateToEnglish = true
        transcriber.selectModel(modelB)

        let releasedHolder = await coordinator.release(holder)
        XCTAssertTrue(releasedHolder)
        _ = try await task.value

        XCTAssertEqual(session.model, modelA)
        XCTAssertEqual(session.preferredLanguage, "ru")
        XCTAssertFalse(session.translateToEnglish)
        let resultA = await probeA.result()
        let resultB = await probeB.result()
        let callsA = resultA.invocations
        let callsB = resultB.invocations
        XCTAssertEqual(callsA.count, 1)
        XCTAssertEqual(callsA.first?.language, "ru")
        XCTAssertEqual(callsA.first?.translate, false)
        XCTAssertTrue(callsB.isEmpty)
    }

    func testResettingOneSessionDoesNotClearAnotherSessionLanguage() async throws {
        let coordinator = TranscriptionCoordinator()
        let probe = RuntimeProbe()
        let engine = IntegrationFakeEngine(label: "language", probe: probe)
        let model = Self.whisperFixture(variant: "large-v3_turbo")
        let transcriber = makeTranscriber(
            coordinator: coordinator,
            model: model,
            engine: engine
        )

        transcriber.preferredLanguage = "ru"
        let first = try transcriber.makeSession(priority: .file)
        transcriber.preferredLanguage = "en"
        let second = try transcriber.makeSession(priority: .file)
        _ = try await transcriber.sampleTranscriber(for: first)
            .transcribeSamples([0.1], translate: false, language: nil)
        _ = try await transcriber.sampleTranscriber(for: second)
            .transcribeSamples([0.1], translate: false, language: nil)

        transcriber.resetLanguageSession(first)

        XCTAssertNil(engine.language(for: first.id))
        XCTAssertEqual(engine.language(for: second.id), "en")
    }

    func testCancellationKeepsLeaseUntilIgnoringEngineActuallyExits() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = RuntimeGate()
        let probe = RuntimeProbe()
        let engine = IntegrationFakeEngine(
            label: "cancel",
            probe: probe,
            gate: gate,
            blocksFirstCallOnly: true
        )
        let model = Self.whisperFixture(variant: "large-v3_turbo")
        let transcriber = makeTranscriber(
            coordinator: coordinator,
            model: model,
            engine: engine
        )
        let first = try transcriber.makeSession(priority: .file)
        let second = try transcriber.makeSession(priority: .live)
        let firstEngine = transcriber.sampleTranscriber(for: first)
        let secondEngine = transcriber.sampleTranscriber(for: second)

        let firstTask = Task {
            try await firstEngine.transcribeSamples(
                [0.1], translate: false, language: nil)
        }
        guard await waitUntil("cancellation test engine did not start", condition: {
            await gate.arrivals() == 1
        }) else { return }

        let secondTask = Task {
            try await secondEngine.transcribeSamples(
                [0.1], translate: false, language: nil)
        }
        guard await waitUntil("live request was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [second.id]
        }) else { return }

        firstTask.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        let blocked = await probe.result()
        XCTAssertEqual(blocked.invocations.map(\.sessionID), [first.id])
        let blockedSnapshot = await coordinator.snapshot()
        XCTAssertEqual(blockedSnapshot.activeSessionID, first.id)

        let releasedFirst = await gate.releaseNext()
        XCTAssertTrue(releasedFirst)
        _ = try await secondTask.value
        do {
            _ = try await firstTask.value
            XCTFail("cancelled session should throw after engine exit")
        } catch is CancellationError {
            // Expected.
        }

        let result = await probe.result()
        XCTAssertEqual(result.maximum, 1)
        XCTAssertEqual(result.invocations.map(\.sessionID), [first.id, second.id])
    }

    func testFileQueueReleasesBetweenChunksSoLiveSessionCanRun() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = RuntimeGate()
        let probe = RuntimeProbe()
        let fileEngine = IntegrationFakeEngine(
            label: "file",
            probe: probe,
            gate: gate,
            blocksFirstCallOnly: true
        )
        let liveEngine = IntegrationFakeEngine(label: "live", probe: probe)
        let sourceURL = try writeWav(seconds: 1.1)
        let nextToSourceURL = sourceURL.deletingPathExtension()
            .appendingPathExtension("txt")
        let centralRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-integration-\(UUID().uuidString)/files")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: nextToSourceURL)
            try? FileManager.default.removeItem(
                at: centralRoot.deletingLastPathComponent()
            )
        }

        let queue = FileTranscriptionQueue(
            transcriber: fileEngine,
            modelName: "fake",
            centralRoot: centralRoot,
            chunkSampleCount: 8_000,
            coordinator: coordinator
        )
        queue.enqueue(
            [sourceURL],
            options: FileTranscriptionOptions(content: .plain, format: .plainText)
        )
        guard await waitUntil("file queue did not start first chunk", condition: {
            await gate.arrivals() == 1
        }) else { return }

        let model = Self.whisperFixture(variant: "large-v3_turbo")
        let transcriber = makeTranscriber(
            coordinator: coordinator,
            model: model,
            engine: liveEngine
        )
        let live = try transcriber.makeSession(priority: .live)
        let liveTask = Task {
            try await transcriber.sampleTranscriber(for: live)
                .transcribeSamples([0.1], translate: false, language: nil)
        }
        guard await waitUntil("live work was not queued behind file chunk", condition: {
            await coordinator.snapshot().queuedSessionIDs == [live.id]
        }) else { return }

        let releasedFileChunk = await gate.releaseNext()
        XCTAssertTrue(releasedFileChunk)
        _ = try await liveTask.value
        guard await waitUntil("file queue did not finish", condition: {
            await MainActor.run {
                queue.jobs.first?.status.isTerminal == true
            }
        }) else { return }

        let result = await probe.result()
        XCTAssertGreaterThanOrEqual(result.invocations.count, 3)
        XCTAssertEqual(
            Array(result.invocations.prefix(3).map(\.label)),
            ["file", "live", "file"]
        )
        XCTAssertEqual(result.maximum, 1)
    }

    private func writeWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-\(UUID().uuidString).wav")
        let sampleRate: Double = 16_000
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount
        let pointer = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            pointer[index] = 0.1
        }
        try file.write(from: buffer)
        return url
    }
}
