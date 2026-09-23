import AppKit
import XCTest
@testable import Voicely

/// The paste channel against a private pasteboard and a pretend target app:
/// the receipt is the real promise mechanism of AppKit — a read of the
/// promised string calls the provider, exactly as a target app's paste does.
@MainActor
final class PasteChannelTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("art.voicely.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("probe", forType: .string), pasteboard.string(forType: .string) == "probe" else {
            throw XCTSkip("no pasteboard server in this environment")
        }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private let userHTML = NSPasteboard.PasteboardType("public.html")
    private let custom = NSPasteboard.PasteboardType("com.example.private-type")

    /// Two items, three types, one of them binary — the shape of a rich copy.
    private func seedUserContent() {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("МЕТКА", forType: .string)
        first.setString("<b>МЕТКА</b>", forType: userHTML)
        first.setData(Data([0, 1, 2, 255]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
    }

    private func assertUserContentIntact(file: StaticString = #filePath, line: UInt = #line) {
        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2, file: file, line: line)
        XCTAssertEqual(items.first?.string(forType: .string), "МЕТКА", file: file, line: line)
        XCTAssertEqual(items.first?.string(forType: userHTML), "<b>МЕТКА</b>", file: file, line: line)
        XCTAssertEqual(items.first?.data(forType: custom), Data([0, 1, 2, 255]), file: file, line: line)
        XCTAssertEqual(items.last?.string(forType: .string), "second item", file: file, line: line)
        XCTAssertFalse(pasteboard.types?.contains(PasteboardMarkers.transient) ?? false, file: file, line: line)
    }

    private func environment(
        secure: @escaping () -> Bool = { false },
        canPost: Bool = true,
        onPaste: @escaping (NSPasteboard) -> Void
    ) -> PasteEnvironment {
        let pasteboard = self.pasteboard!
        return PasteEnvironment(
            pasteboard: pasteboard,
            sourceBundleID: "art.voicely.app",
            secureInputEnabled: secure,
            canPostEvents: { canPost },
            postPaste: {
                onPaste(pasteboard)
                return true
            },
            receiptCeiling: .milliseconds(200),
            poll: .milliseconds(2)
        )
    }

    // MARK: - Snapshot and restore

    func testSnapshotRestoresEveryItemAndTypeByteForByte() {
        seedUserContent()
        let snapshot = PasteboardSnapshot.take(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        XCTAssertTrue(snapshot.write(to: pasteboard))
        assertUserContentIntact()
    }

    func testEmptyPasteboardComesBackEmpty() {
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.take(of: pasteboard)
        XCTAssertTrue(snapshot.items.isEmpty)
        pasteboard.setString("transcript", forType: .string)
        snapshot.write(to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
    }

    /// The promise carries the markers clipboard managers honour, and the
    /// transcript is not on the pasteboard until someone asks for it.
    func testPromiseCarriesManagerMarkersAndCountsReads() throws {
        seedUserContent()
        let transaction = try XCTUnwrap(PasteboardTransaction.begin(text: "проверка", on: pasteboard, sourceBundleID: "art.voicely.app"))
        let types = pasteboard.types ?? []
        for marker in PasteboardMarkers.all { XCTAssertTrue(types.contains(marker), "\(marker.rawValue)") }
        XCTAssertEqual(pasteboard.string(forType: PasteboardMarkers.source), "art.voicely.app")
        XCTAssertEqual(transaction.promise.reads.beforeArm, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "проверка")
        XCTAssertEqual(transaction.promise.reads.beforeArm, 1, "a read before Cmd+V is not a receipt")
        XCTAssertEqual(transaction.promise.reads.afterArm, 0)
        XCTAssertEqual(transaction.restore(), .restored)
        assertUserContentIntact()
    }

    /// A copy the user makes while the paste is in flight is theirs to keep.
    func testRestoreNeverOverwritesAForeignWrite() throws {
        seedUserContent()
        let transaction = try XCTUnwrap(PasteboardTransaction.begin(text: "проверка", on: pasteboard, sourceBundleID: nil))
        pasteboard.clearContents()
        pasteboard.setString("user copied this meanwhile", forType: .string)
        XCTAssertEqual(transaction.restore(), .keptForeignWrite)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this meanwhile")
    }

    // MARK: - The channel

    /// The target reads the transcript after Cmd+V: delivered with a receipt;
    /// the transaction stays open for the caller's delayed restore.
    func testReceiptMeansDeliveredAndTheUsersPasteboardComesBack() async throws {
        seedUserContent()
        var pasted: String?
        let attempt = await PasteChannel.run(
            text: "проверка вставки один два три",
            environment: environment { pasteboard in pasted = pasteboard.string(forType: .string) }
        )
        XCTAssertEqual(attempt.result, .delivered(.receipt))
        XCTAssertEqual(pasted, "проверка вставки один два три")
        XCTAssertNotNil(attempt.receiptMilliseconds)
        let open = try XCTUnwrap(attempt.openTransaction)
        XCTAssertNil(attempt.close)
        XCTAssertEqual(open.restore(), .restored)
        assertUserContentIntact()
    }

    /// Nobody read the transcript (the Cmd+V was swallowed): certainly not
    /// delivered, and the user's pasteboard is back before the next channel.
    func testNoReceiptIsNotDeliveredAndTakesThePromiseBack() async {
        seedUserContent()
        let attempt = await PasteChannel.run(text: "проверка", environment: environment { _ in })
        XCTAssertEqual(attempt.result, .notDelivered(reason: "no_receipt"))
        XCTAssertNil(attempt.openTransaction)
        XCTAssertEqual(attempt.close, .restored)
        assertUserContentIntact()
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(forType: .string), "МЕТКА",
            "a late read finds the user's content, never the transcript"
        )
    }

    /// A reader took the promise before Cmd+V; the target's own read would not
    /// reach us. That is "don't know", which never triggers a second channel.
    func testReadBeforePasteIsUnknownNotAFallback() async {
        seedUserContent()
        let pasteboard = self.pasteboard!
        var env = environment { _ in }
        env.secureInputEnabled = {
            // The second secure check runs after the promise is written: a
            // clipboard manager reading at that moment is simulated here.
            if pasteboard.types?.contains(PasteboardMarkers.transient) == true {
                _ = pasteboard.string(forType: .string)
            }
            return false
        }
        let attempt = await PasteChannel.run(text: "проверка", environment: env)
        XCTAssertEqual(attempt.result, .unknown(reason: "read_before_paste"))
        XCTAssertEqual(attempt.close, .restored)
    }

    func testForeignWriteDuringTheWaitIsUnknownAndKept() async {
        seedUserContent()
        let attempt = await PasteChannel.run(text: "проверка", environment: environment { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("another app wrote this", forType: .string)
        })
        XCTAssertEqual(attempt.result, .unknown(reason: "pasteboard_replaced"))
        XCTAssertEqual(attempt.close, .keptForeignWrite)
        XCTAssertEqual(pasteboard.string(forType: .string), "another app wrote this")
    }

    /// Secure Event Input switching on after the promise is written: nothing
    /// is pressed, the transcript is taken back.
    func testSecureInputBeforeCmdVBlocksAndRestores() async {
        seedUserContent()
        var checks = 0
        var pressed = false
        let env = environment(secure: {
            checks += 1
            return checks >= 2
        }, onPaste: { _ in pressed = true })
        let attempt = await PasteChannel.run(text: "пароль", environment: env)
        XCTAssertEqual(attempt.result, .blockedSecure)
        XCTAssertFalse(pressed)
        assertUserContentIntact()
    }

    /// The receipt across processes, as a real target app gives it: another
    /// process reads the promised string while the channel waits, and the
    /// provider answers from this process's run loop.
    func testReceiptFromAnotherProcess() async throws {
        seedUserContent()
        let name = pasteboard.name.rawValue
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        reader.arguments = [
            "-l", "JavaScript", "-e",
            "ObjC.import('AppKit'); ObjC.unwrap($.NSPasteboard.pasteboardWithName('\(name)').stringForType('public.utf8-plain-text'))",
        ]
        let output = Pipe()
        reader.standardOutput = output
        reader.standardError = Pipe()
        var env = environment { _ in }
        env.postPaste = {
            do { try reader.run() } catch { return false }
            return true
        }
        env.receiptCeiling = .seconds(8)
        let attempt = await PasteChannel.run(text: "через процесс ✓", environment: env)
        reader.waitUntilExit()
        guard reader.terminationStatus == 0 else { throw XCTSkip("osascript cannot read pasteboards here") }
        XCTAssertEqual(attempt.result, .delivered(.receipt))
        let read = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(read?.trimmingCharacters(in: .whitespacesAndNewlines), "через процесс ✓")
        XCTAssertEqual(attempt.openTransaction?.restore(), .restored)
        assertUserContentIntact()
    }

    func testNoPostAccessTouchesNothing() async {
        seedUserContent()
        let before = pasteboard.changeCount
        let attempt = await PasteChannel.run(text: "x", environment: environment(canPost: false) { _ in })
        XCTAssertEqual(attempt.result, .notDelivered(reason: "no_post_access"))
        XCTAssertEqual(pasteboard.changeCount, before)
    }
}
