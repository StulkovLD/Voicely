import XCTest
@testable import Voicely

/// The outcome law: a channel either delivered, certainly did not, or does
/// not know — and only "certainly not" moves the chain on. That is what makes
/// a double insert impossible by construction.
@MainActor
final class DeliveryChainTests: XCTestCase {
    private final class ScriptedRunner: InsertionChannelRunner {
        var script: [InsertionChannel: ChannelResult]
        var called: [InsertionChannel] = []
        init(_ script: [InsertionChannel: ChannelResult]) { self.script = script }
        func attempt(_ channel: InsertionChannel) async -> ChannelResult {
            called.append(channel)
            return script[channel] ?? .notDelivered(reason: "unscripted")
        }
    }

    func testFirstDeliveryStopsTheChain() async {
        let runner = ScriptedRunner([.ax: .delivered(.verified)])
        let outcome = await DeliveryChain.run([.ax, .paste, .typing], with: runner)
        XCTAssertEqual(outcome.result, .delivered(.verified))
        XCTAssertEqual(outcome.channel, .ax)
        XCTAssertEqual(runner.called, [.ax])
    }

    func testCertainlyNotDeliveredHandsOverAndIsRecorded() async {
        let runner = ScriptedRunner([
            .ax: .notDelivered(reason: "ax_unchanged"),
            .paste: .delivered(.receipt),
        ])
        let outcome = await DeliveryChain.run([.ax, .paste, .typing], with: runner)
        XCTAssertEqual(outcome.channel, .paste)
        XCTAssertEqual(outcome.fallbackFrom, ["ax:ax_unchanged"])
        XCTAssertEqual(runner.called, [.ax, .paste])
    }

    /// "Don't know" is delivered: a slow app must never get the text twice.
    func testUnknownNeverTriggersTheNextChannel() async {
        let runner = ScriptedRunner([.paste: .unknown(reason: "read_before_paste"), .typing: .delivered(.unverified)])
        let outcome = await DeliveryChain.run([.paste, .typing], with: runner)
        XCTAssertEqual(outcome.result, .unknown(reason: "read_before_paste"))
        XCTAssertEqual(runner.called, [.paste])
    }

    func testSecureRefusalStopsEverything() async {
        let runner = ScriptedRunner([.paste: .blockedSecure])
        let outcome = await DeliveryChain.run([.paste, .typing], with: runner)
        XCTAssertEqual(outcome.result, .blockedSecure)
        XCTAssertEqual(runner.called, [.paste])
    }

    /// The Cmd+V nobody read (xterm.js swallowing it) falls through to typing.
    func testSwallowedPasteFallsThroughToTyping() async {
        let runner = ScriptedRunner([.paste: .notDelivered(reason: "no_receipt"), .typing: .delivered(.unverified)])
        let outcome = await DeliveryChain.run([.paste, .typing], with: runner)
        XCTAssertEqual(outcome.channel, .typing)
        XCTAssertEqual(outcome.fallbackFrom, ["paste:no_receipt"])
    }

    func testAllCertainlyFailedLeavesNoResult() async {
        let runner = ScriptedRunner([:])
        let outcome = await DeliveryChain.run([.paste], with: runner)
        XCTAssertNil(outcome.result)
        XCTAssertNil(outcome.channel)
        XCTAssertEqual(outcome.fallbackFrom, ["paste:unscripted"])
    }

    // MARK: - Accessibility read-back

    private func verdict(_ before: (Int, Int), _ after: (Int, Int)?, count: (Int?, Int?) = (nil, nil), inserted: Int) -> AXWriteCheck.Verdict {
        AXWriteCheck.classify(
            before: TextRange(location: before.0, length: before.1),
            after: after.map { TextRange(location: $0.0, length: $0.1) },
            countBefore: count.0,
            countAfter: count.1,
            insertedLength: inserted
        )
    }

    func testCaretRightAfterTheTextIsVerified() {
        XCTAssertEqual(verdict((5, 0), (12, 0), count: (20, 27), inserted: 7), .verified)
        XCTAssertEqual(verdict((5, 3), (12, 0), count: (20, 24), inserted: 7), .verified, "a selection is replaced")
        XCTAssertEqual(verdict((5, 0), (12, 0), inserted: 7), .verified, "length unknown: the caret decides")
    }

    /// Chrome's lie, measured 6/6: success, and nothing moved.
    func testNothingMovedIsUnchanged() {
        XCTAssertEqual(verdict((5, 0), (5, 0), count: (20, 20), inserted: 7), .unchanged)
        XCTAssertEqual(verdict((5, 2), (5, 2), inserted: 7), .unchanged)
    }

    /// Autocorrect or a length cap moved things its own way: it did land.
    func testSomethingElseMovedIsChanged() {
        XCTAssertEqual(verdict((5, 0), (11, 0), count: (20, 26), inserted: 7), .changed)
        XCTAssertEqual(verdict((5, 0), (5, 0), count: (20, 27), inserted: 7), .changed, "text in, caret left before it")
    }

    func testNothingReadableIsUnreadable() {
        XCTAssertEqual(verdict((5, 0), nil, inserted: 7), .unreadable)
        XCTAssertEqual(verdict((5, 0), nil, count: (20, 20), inserted: 7), .unchanged)
        XCTAssertEqual(verdict((5, 0), nil, count: (20, 27), inserted: 7), .changed)
    }
}
