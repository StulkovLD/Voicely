import XCTest
@testable import VoicelyCLI

final class MCPCoordinatorTests: XCTestCase {
    /// A fast request whose response is already computed must publish even when
    /// shutdown lands right after submit — the old token-strip threw the ready
    /// initialize answer away on stdin-EOF (measured live, 2026-08-19).
    func testResponseComputedBeforeShutdownStillPublishes() async throws {
        let published = expectation(description: "response published")
        let coordinator = MCPRequestCoordinator { response in
            XCTAssertEqual(response.id, .int(1))
            published.fulfill()
        }

        let result = await coordinator.submit(id: .int(1)) {
            .result(id: .int(1), result: .object([:]))
        }
        XCTAssertEqual(result, .accepted)
        await coordinator.shutdown()

        await fulfillment(of: [published], timeout: 5)
    }

    /// An explicitly cancelled request must NOT publish: the client withdrew it.
    func testExplicitCancelSuppressesPublication() async throws {
        let gate = expectation(description: "operation started")
        let coordinator = MCPRequestCoordinator { _ in
            XCTFail("cancelled request must not publish")
        }

        _ = await coordinator.submit(id: .int(7)) {
            gate.fulfill()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .result(id: .int(7), result: .object([:]))
        }
        await fulfillment(of: [gate], timeout: 5)
        _ = await coordinator.cancel(id: .int(7))
        // Give the detached task time to unwind through complete().
        try await Task.sleep(nanoseconds: 600_000_000)
    }
}
