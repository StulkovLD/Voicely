import XCTest
@testable import VoicelyCLI

private actor MCPResponseRecorder {
    private var responses: [JSONRPCResponse] = []

    func append(_ response: JSONRPCResponse) {
        responses.append(response)
    }

    func count() -> Int { responses.count }
}

private actor CancellationIgnoringMCPOperation {
    private var started = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async -> JSONRPCResponse {
        started = true
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return .result(id: .int(7), result: .string("stale transcript"))
    }

    func hasStarted() -> Bool { started }

    func release() {
        released = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
final class MCPRequestCoordinatorTests: XCTestCase {
    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testCancellationNotificationRequestIDParsing() {
        XCTAssertEqual(
            MCPServer.cancelledRequestID(from: .object([
                "requestId": .string("transcription-42"),
            ])),
            .string("transcription-42")
        )
        XCTAssertEqual(
            MCPServer.cancelledRequestID(from: .object(["requestId": .int(42)])),
            .int(42)
        )
        XCTAssertNil(MCPServer.cancelledRequestID(from: .object([:])))
    }

    func testCancelledRequestCannotPublishLateResult() async throws {
        let recorder = MCPResponseRecorder()
        let operation = CancellationIgnoringMCPOperation()
        let coordinator = MCPRequestCoordinator { response in
            await recorder.append(response)
        }

        let accepted = await coordinator.submit(id: .int(7)) {
            await operation.run()
        }
        XCTAssertEqual(accepted, .accepted)
        let started = await waitUntil { await operation.hasStarted() }
        guard started else {
            await coordinator.shutdown()
            await operation.release()
            XCTFail("timed out waiting for the request operation")
            return
        }

        let cancelled = await coordinator.cancel(id: .int(7))
        XCTAssertTrue(cancelled)
        await operation.release()
        try await Task.sleep(for: .milliseconds(50))

        let publishedCount = await recorder.count()
        XCTAssertEqual(publishedCount, 0)
        let activeCount = await coordinator.activeRequestCount
        XCTAssertEqual(activeCount, 0)
    }

    func testShutdownCancelsPendingRequestsAndRejectsNewWork() async throws {
        let recorder = MCPResponseRecorder()
        let operation = CancellationIgnoringMCPOperation()
        let coordinator = MCPRequestCoordinator { response in
            await recorder.append(response)
        }

        let accepted = await coordinator.submit(id: .int(7)) {
            await operation.run()
        }
        XCTAssertEqual(accepted, .accepted)
        let started = await waitUntil { await operation.hasStarted() }
        guard started else {
            await coordinator.shutdown()
            await operation.release()
            XCTFail("timed out waiting for the request operation")
            return
        }

        await coordinator.shutdown()
        let stillAccepting = await coordinator.isAcceptingRequests
        XCTAssertFalse(stillAccepting)
        let acceptedAfterShutdown = await coordinator.submit(id: .int(8)) {
            .result(id: .int(8), result: .string("must not run"))
        }
        XCTAssertEqual(acceptedAfterShutdown, .shuttingDown)

        await operation.release()
        try await Task.sleep(for: .milliseconds(50))
        // Contract change (2026-08-19): a response the operation still managed
        // to compute publishes even after shutdown — the client asked and the
        // answer exists. The old token-strip silently threw away initialize's
        // ready answer on stdin-EOF (measured live). Only an explicit
        // cancel(id:) suppresses publication.
        let publishedCount = await recorder.count()
        XCTAssertEqual(publishedCount, 1)
        let activeCount = await coordinator.activeRequestCount
        XCTAssertEqual(activeCount, 0)
    }

    func testCompletedRequestPublishesExactlyOnce() async throws {
        let recorder = MCPResponseRecorder()
        let coordinator = MCPRequestCoordinator { response in
            await recorder.append(response)
        }

        let accepted = await coordinator.submit(id: .int(9)) {
            .result(id: .int(9), result: .string("ok"))
        }
        XCTAssertEqual(accepted, .accepted)

        for _ in 0..<50 {
            if await recorder.count() == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let publishedCount = await recorder.count()
        XCTAssertEqual(publishedCount, 1)
        let activeCount = await coordinator.activeRequestCount
        XCTAssertEqual(activeCount, 0)
    }

    func testRequestRegistryHardCapRejectsOverflowWithoutStartingIt() async {
        XCTAssertEqual(MCPRequestCoordinator.defaultMaximumRequests, 32)
        let recorder = MCPResponseRecorder()
        let coordinator = MCPRequestCoordinator(maximumRequests: 2) { response in
            await recorder.append(response)
        }

        let first = await coordinator.submit(id: .int(1)) {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let second = await coordinator.submit(id: .int(2)) {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let overflow = await coordinator.submit(id: .int(3)) {
            return nil
        }

        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(second, .accepted)
        XCTAssertEqual(overflow, .serverBusy)
        let duplicate = await coordinator.submit(id: .int(1)) { nil }
        XCTAssertEqual(duplicate, .duplicateID)
        await coordinator.shutdown()
    }

    func testHeavyAdmissionAllowsOneActiveTwoQueuedAndRejectsFourth() async throws {
        XCTAssertEqual(MCPHeavyRequestAdmission.defaultMaximumQueued, 2)
        let admission = MCPHeavyRequestAdmission(maximumQueued: 2)
        let first = try await admission.acquire()
        let secondTask = Task { try await admission.acquire() }
        let secondQueued = await waitUntil { await admission.queuedCount == 1 }
        XCTAssertTrue(secondQueued)
        let thirdTask = Task { try await admission.acquire() }
        let thirdQueued = await waitUntil { await admission.queuedCount == 2 }
        XCTAssertTrue(thirdQueued)

        do {
            _ = try await admission.acquire()
            XCTFail("fourth heavy request must be rejected")
        } catch MCPHeavyRequestAdmission.AdmissionError.serverBusy {
            // Expected.
        }

        await admission.release(first)
        let second = try await secondTask.value
        let activeAfterFirst = await admission.activeCount
        let queuedAfterFirst = await admission.queuedCount
        XCTAssertEqual(activeAfterFirst, 1)
        XCTAssertEqual(queuedAfterFirst, 1)
        await admission.release(second)
        let third = try await thirdTask.value
        await admission.release(third)
        let finalActive = await admission.activeCount
        let finalQueued = await admission.queuedCount
        XCTAssertEqual(finalActive, 0)
        XCTAssertEqual(finalQueued, 0)
    }

    func testCancelledHeavyWaiterNeverBecomesActive() async throws {
        let admission = MCPHeavyRequestAdmission(maximumQueued: 2)
        let first = try await admission.acquire()
        let cancelledTask = Task { try await admission.acquire() }
        let queued = await waitUntil { await admission.queuedCount == 1 }
        XCTAssertTrue(queued)

        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("cancelled waiter must not acquire a permit")
        } catch is CancellationError {
            // Expected.
        }
        let removed = await waitUntil { await admission.queuedCount == 0 }
        let activeBeforeRelease = await admission.activeCount
        XCTAssertTrue(removed)
        XCTAssertEqual(activeBeforeRelease, 1)
        await admission.release(first)
        let activeAfterRelease = await admission.activeCount
        XCTAssertEqual(activeAfterRelease, 0)
    }

    func testJSONRPCRejectsUnsafeOrAmbiguousIDsWithoutTrapping() throws {
        let invalidRequests = [
            #"{"jsonrpc":"2.0","id":1e100,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":-1e100,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#,
        ]
        for request in invalidRequests {
            XCTAssertThrowsError(try JSONRPCMessage(data: Data(request.utf8))) { error in
                guard case JSONRPCParseError.invalidID = error else {
                    return XCTFail("expected invalidID for \(request), got \(error)")
                }
            }
        }

        XCTAssertEqual(
            try JSONRPCMessage(data: Data(
                #"{"jsonrpc":"2.0","id":42.0,"method":"ping"}"#.utf8
            )).id,
            .int(42)
        )
        XCTAssertEqual(
            try JSONRPCMessage(data: Data(
                #"{"jsonrpc":"2.0","id":"request-42","method":"ping"}"#.utf8
            )).id,
            .string("request-42")
        )
    }

    func testOversizedFrameDrainsAndResynchronizesAtNextPing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-frames-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var input = Data(repeating: 0x61, count: JSONRPCFrameReader.defaultMaximumFrameBytes + 1)
        input.append(0x0A)
        input.append(Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8))
        input.append(0x0A)
        try input.write(to: url, options: .atomic)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = JSONRPCFrameReader(input: handle, readChunkBytes: 4_096)

        XCTAssertEqual(try reader.nextFrame(), .oversized)
        guard case let .frame(pingData)? = try reader.nextFrame() else {
            return XCTFail("reader did not resynchronize at the next frame")
        }
        let ping = try JSONRPCMessage(data: pingData)
        XCTAssertEqual(ping.id, .int(9))
        XCTAssertEqual(ping.method, "ping")
        XCTAssertNil(try reader.nextFrame())
    }
}
