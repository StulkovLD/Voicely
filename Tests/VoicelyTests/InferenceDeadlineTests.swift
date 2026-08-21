import XCTest
@testable import VoicelyCore

/// The GigaAM decode runs inside a coordinator lease, and the lease is only
/// released when the decode returns. An ANE call that never returns therefore
/// wedged not just its own dictation but every later one, with no way out but a
/// restart. `withDeadline` is what frees the caller.
final class InferenceDeadlineTests: XCTestCase {

    func testOperationFinishingInTimeReturnsItsValue() async throws {
        let value = try await withDeadline(seconds: 60) { "decoded" }
        XCTAssertEqual(value, "decoded")
    }

    func testOperationErrorPropagatesUnchanged() async {
        struct DecodeFailure: Error {}
        do {
            _ = try await withDeadline(seconds: 60) { throw DecodeFailure() }
            XCTFail("expected the operation's own error")
        } catch is DecodeFailure {
            // expected — a deadline must not mask a real failure
        } catch {
            XCTFail("expected DecodeFailure, got \(error)")
        }
    }

    /// The property that matters: the caller is freed on time, and — crucially —
    /// is NOT made to wait for the wedged operation. A deadline that awaited the
    /// stuck call would hold the lease exactly as long as no deadline at all.
    func testWedgedOperationFreesTheCallerAtTheDeadline() async {
        let started = Date()
        do {
            _ = try await withDeadline(seconds: 1) {
                // Stands in for a wedged CoreML/ANE call: uncancellable and far
                // longer than any caller is willing to wait.
                try? await Task.sleep(for: .seconds(600))
                return "never"
            }
            XCTFail("expected DeadlineExceeded")
        } catch is DeadlineExceeded {
            let waited = Date().timeIntervalSince(started)
            XCTAssertLessThan(waited, 30, "caller must be released at the deadline, not held by the wedged call")
        } catch {
            XCTFail("expected DeadlineExceeded, got \(error)")
        }
    }
}
