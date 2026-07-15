import Foundation

/// Serializes access to the transcription engine across live and queued work.
///
/// An active lease is never preempted. Priority is applied only when choosing
/// the next request from the waiting queue.
public actor TranscriptionCoordinator {
    public struct SessionID: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UUID

        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        public var description: String {
            rawValue.uuidString
        }
    }

    public enum Priority: Int, CaseIterable, Sendable {
        case live = 0
        case file = 1
        case background = 2
    }

    public struct Lease: Hashable, Sendable {
        public let sessionID: SessionID
        public let priority: Priority

        fileprivate let token: UUID
    }

    public struct Snapshot: Equatable, Sendable {
        public let activeSessionID: SessionID?

        /// Waiting sessions in the order in which they would be selected.
        public let queuedSessionIDs: [SessionID]

        public var isIdle: Bool {
            activeSessionID == nil && queuedSessionIDs.isEmpty
        }
    }

    private struct Waiter {
        let requestID: UUID
        let sessionID: SessionID
        let priority: Priority
        let sequence: UInt64
        let continuation: CheckedContinuation<Lease, Error>
    }

    private var activeLease: Lease?
    private var waiters: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextSequence: UInt64 = 0

    public init() {}

    /// Waits for exclusive access to the transcription engine.
    ///
    /// Cancelling a queued task removes its request. Cancelling a task after it
    /// acquired a lease leaves release responsibility with that task.
    public func acquire(
        sessionID: SessionID,
        priority: Priority
    ) async throws -> Lease {
        try Task.checkCancellation()
        let requestID = UUID()

        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Lease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                enqueue(
                    requestID: requestID,
                    sessionID: sessionID,
                    priority: priority,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelQueuedRequest(requestID)
            }
        }

        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }

        return lease
    }

    /// Releases a lease if it is still the active lease.
    ///
    /// The token check makes duplicate and stale releases harmless.
    @discardableResult
    public func release(_ lease: Lease) -> Bool {
        guard activeLease?.token == lease.token else {
            return false
        }

        activeLease = nil
        startNextIfPossible()
        resumeIdleWaitersIfNeeded()
        return true
    }

    /// Runs one operation while holding the exclusive transcription lease.
    ///
    /// The lease is released only after `operation` exits, including when the
    /// caller is cancelled while a non-cancellable operation is still running.
    public func withLease<T: Sendable>(
        sessionID: SessionID,
        priority: Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquire(sessionID: sessionID, priority: priority)
        defer { release(lease) }

        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    /// Suspends until no lease is active and no request remains queued.
    public func waitUntilIdle() async {
        guard !isIdle else { return }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            activeSessionID: activeLease?.sessionID,
            queuedSessionIDs: sortedWaiters.map(\.sessionID)
        )
    }

    private var isIdle: Bool {
        activeLease == nil && waiters.isEmpty
    }

    private var sortedWaiters: [Waiter] {
        waiters.sorted { lhs, rhs in
            if lhs.priority.rawValue != rhs.priority.rawValue {
                return lhs.priority.rawValue < rhs.priority.rawValue
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func enqueue(
        requestID: UUID,
        sessionID: SessionID,
        priority: Priority,
        continuation: CheckedContinuation<Lease, Error>
    ) {
        let waiter = Waiter(
            requestID: requestID,
            sessionID: sessionID,
            priority: priority,
            sequence: nextSequence,
            continuation: continuation
        )
        nextSequence &+= 1
        waiters.append(waiter)
        startNextIfPossible()
    }

    private func cancelQueuedRequest(_ requestID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        resumeIdleWaitersIfNeeded()
    }

    private func startNextIfPossible() {
        guard activeLease == nil, !waiters.isEmpty else {
            return
        }

        let nextIndex = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority.rawValue != right.priority.rawValue {
                return left.priority.rawValue < right.priority.rawValue
            }
            return left.sequence < right.sequence
        }!

        let waiter = waiters.remove(at: nextIndex)
        let lease = Lease(
            sessionID: waiter.sessionID,
            priority: waiter.priority,
            token: UUID()
        )
        activeLease = lease
        waiter.continuation.resume(returning: lease)
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else {
            return
        }

        let continuations = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        continuations.forEach { $0.resume() }
    }
}
