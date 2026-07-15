import XCTest
@testable import VoicelyCore

private actor NonCancellableGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalCount = 0

    func wait() async {
        arrivalCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    @discardableResult
    func releaseNext() -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().resume()
        return true
    }

    func arrivals() -> Int {
        arrivalCount
    }
}

private actor ConcurrencyProbe {
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var startOrder: [TranscriptionCoordinator.SessionID] = []

    func enter(_ sessionID: TranscriptionCoordinator.SessionID) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startOrder.append(sessionID)
    }

    func leave() {
        activeCount -= 1
    }

    func result() -> (maximum: Int, order: [TranscriptionCoordinator.SessionID]) {
        (maximumActiveCount, startOrder)
    }
}

private actor SessionRecorder {
    private var sessions: [TranscriptionCoordinator.SessionID] = []

    func append(_ sessionID: TranscriptionCoordinator.SessionID) {
        sessions.append(sessionID)
    }

    func values() -> [TranscriptionCoordinator.SessionID] {
        sessions
    }
}

private actor InvocationFlag {
    private var value = false

    func set() {
        value = true
    }

    func isSet() -> Bool {
        value
    }
}

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {
    private enum ExpectedError: Error {
        case failure
    }

    private func waitUntil(
        _ message: String,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTFail(message)
        return false
    }

    func testSlowNonCancellableOperationNeverOverlapsAfterCancellation() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = NonCancellableGate()
        let probe = ConcurrencyProbe()
        let firstSession = TranscriptionCoordinator.SessionID()
        let secondSession = TranscriptionCoordinator.SessionID()

        let first = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: firstSession,
                priority: .file
            ) {
                await probe.enter(firstSession)
                await gate.wait()
                await probe.leave()
            }
        }

        guard await waitUntil("first operation did not start", condition: {
            await gate.arrivals() == 1
        }) else { return }

        let second = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: secondSession,
                priority: .live
            ) {
                await probe.enter(secondSession)
                await gate.wait()
                await probe.leave()
            }
        }

        guard await waitUntil("second operation was not queued", condition: {
            let snapshot = await coordinator.snapshot()
            return snapshot.activeSessionID == firstSession
                && snapshot.queuedSessionIDs == [secondSession]
        }) else {
            first.cancel()
            second.cancel()
            _ = await gate.releaseNext()
            return
        }

        first.cancel()
        try? await Task.sleep(for: .milliseconds(20))

        let cancelledSnapshot = await coordinator.snapshot()
        XCTAssertEqual(cancelledSnapshot.activeSessionID, firstSession)
        XCTAssertEqual(cancelledSnapshot.queuedSessionIDs, [secondSession])
        let arrivalsAfterCancellation = await gate.arrivals()
        XCTAssertEqual(arrivalsAfterCancellation, 1)

        let releasedFirst = await gate.releaseNext()
        XCTAssertTrue(releasedFirst)

        guard await waitUntil("second operation did not start after release", condition: {
            await gate.arrivals() == 2
        }) else {
            second.cancel()
            _ = await gate.releaseNext()
            return
        }

        let releasedSecond = await gate.releaseNext()
        XCTAssertTrue(releasedSecond)
        try await second.value

        do {
            try await first.value
            XCTFail("cancelled operation should throw CancellationError")
        } catch is CancellationError {
            // Expected after the non-cancellable operation actually exits.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let result = await probe.result()
        XCTAssertEqual(result.maximum, 1)
        XCTAssertEqual(result.order, [firstSession, secondSession])
        await coordinator.waitUntilIdle()
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testLiveQueuedBehindActiveRunsBeforeFIFOFileRequests() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = NonCancellableGate()
        let recorder = SessionRecorder()
        let holderSession = TranscriptionCoordinator.SessionID()
        let firstFileSession = TranscriptionCoordinator.SessionID()
        let secondFileSession = TranscriptionCoordinator.SessionID()
        let liveSession = TranscriptionCoordinator.SessionID()

        let holder = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: holderSession,
                priority: .background
            ) {
                await recorder.append(holderSession)
                await gate.wait()
            }
        }

        guard await waitUntil("holder did not acquire the lease", condition: {
            let snapshot = await coordinator.snapshot()
            let arrivals = await gate.arrivals()
            return snapshot.activeSessionID == holderSession && arrivals == 1
        }) else { return }

        let firstFile = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: firstFileSession,
                priority: .file
            ) {
                await recorder.append(firstFileSession)
            }
        }

        guard await waitUntil("first file was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [firstFileSession]
        }) else { return }

        let secondFile = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: secondFileSession,
                priority: .file
            ) {
                await recorder.append(secondFileSession)
            }
        }

        guard await waitUntil("second file was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs
                == [firstFileSession, secondFileSession]
        }) else { return }

        let live = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: liveSession,
                priority: .live
            ) {
                await recorder.append(liveSession)
            }
        }

        guard await waitUntil("live request was not prioritized", condition: {
            await coordinator.snapshot().queuedSessionIDs
                == [liveSession, firstFileSession, secondFileSession]
        }) else { return }

        let releasedHolder = await gate.releaseNext()
        XCTAssertTrue(releasedHolder)
        try await holder.value
        try await live.value
        try await firstFile.value
        try await secondFile.value

        let recordedSessions = await recorder.values()
        XCTAssertEqual(
            recordedSessions,
            [holderSession, liveSession, firstFileSession, secondFileSession]
        )
        await coordinator.waitUntilIdle()
    }

    func testCancellingQueuedRequestRemovesItWithoutInvokingOperation() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = NonCancellableGate()
        let invoked = InvocationFlag()
        let holderSession = TranscriptionCoordinator.SessionID()
        let cancelledSession = TranscriptionCoordinator.SessionID()

        let holder = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: holderSession,
                priority: .file
            ) {
                await gate.wait()
            }
        }

        guard await waitUntil("holder did not acquire the lease", condition: {
            let snapshot = await coordinator.snapshot()
            let arrivals = await gate.arrivals()
            return snapshot.activeSessionID == holderSession && arrivals == 1
        }) else { return }

        let cancelled = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: cancelledSession,
                priority: .live
            ) {
                await invoked.set()
            }
        }

        guard await waitUntil("cancellable request was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [cancelledSession]
        }) else { return }

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("queued cancellation should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let snapshotAfterCancellation = await coordinator.snapshot()
        XCTAssertEqual(snapshotAfterCancellation.activeSessionID, holderSession)
        XCTAssertTrue(snapshotAfterCancellation.queuedSessionIDs.isEmpty)
        let operationWasInvoked = await invoked.isSet()
        XCTAssertFalse(operationWasInvoked)

        let releasedHolder = await gate.releaseNext()
        XCTAssertTrue(releasedHolder)
        try await holder.value
        await coordinator.waitUntilIdle()
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testThrownOperationReleasesLease() async throws {
        let coordinator = TranscriptionCoordinator()
        let failedSession = TranscriptionCoordinator.SessionID()
        let succeedingSession = TranscriptionCoordinator.SessionID()

        do {
            try await coordinator.withLease(
                sessionID: failedSession,
                priority: .live
            ) { () async throws -> Void in
                throw ExpectedError.failure
            }
            XCTFail("operation should throw")
        } catch ExpectedError.failure {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let result = try await coordinator.withLease(
            sessionID: succeedingSession,
            priority: .file
        ) {
            "completed"
        }

        XCTAssertEqual(result, "completed")
        await coordinator.waitUntilIdle()
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertTrue(finalSnapshot.isIdle)
    }

    func testWaitUntilIdleReturnsOnlyAfterActiveAndQueuedWorkFinish() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = NonCancellableGate()
        let idleReturned = InvocationFlag()
        let firstSession = TranscriptionCoordinator.SessionID()
        let secondSession = TranscriptionCoordinator.SessionID()

        let first = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: firstSession,
                priority: .file
            ) {
                await gate.wait()
            }
        }

        guard await waitUntil("first operation did not start", condition: {
            await gate.arrivals() == 1
        }) else { return }

        let second = Task<Void, Error> {
            try await coordinator.withLease(
                sessionID: secondSession,
                priority: .file
            ) {
                await gate.wait()
            }
        }

        guard await waitUntil("second operation was not queued", condition: {
            await coordinator.snapshot().queuedSessionIDs == [secondSession]
        }) else { return }

        let idleWaiter = Task {
            await coordinator.waitUntilIdle()
            await idleReturned.set()
        }

        let releasedFirst = await gate.releaseNext()
        XCTAssertTrue(releasedFirst)
        guard await waitUntil("second operation did not become active", condition: {
            let snapshot = await coordinator.snapshot()
            let arrivals = await gate.arrivals()
            return snapshot.activeSessionID == secondSession
                && snapshot.queuedSessionIDs.isEmpty
                && arrivals == 2
        }) else { return }

        try? await Task.sleep(for: .milliseconds(20))
        let returnedWhileSecondWasActive = await idleReturned.isSet()
        XCTAssertFalse(returnedWhileSecondWasActive)

        let releasedSecond = await gate.releaseNext()
        XCTAssertTrue(releasedSecond)
        try await first.value
        try await second.value
        await idleWaiter.value

        let didReturn = await idleReturned.isSet()
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertTrue(didReturn)
        XCTAssertTrue(finalSnapshot.isIdle)
    }
}
