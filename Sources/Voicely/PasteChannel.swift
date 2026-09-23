import AppKit

/// Everything the paste channel touches outside itself, so tests can run it
/// against a private pasteboard and a pretend app.
@MainActor
struct PasteEnvironment {
    var pasteboard: NSPasteboard
    var sourceBundleID: String?
    var secureInputEnabled: () -> Bool
    var canPostEvents: () -> Bool
    /// Press Cmd+V at the focused app. False when the events could not be made.
    var postPaste: () async -> Bool
    /// How long an app gets to read the transcript after Cmd+V.
    var receiptCeiling: Duration = .milliseconds(1000)
    var poll: Duration = .milliseconds(5)
}

/// Channel "promised transcript + Cmd+V" {design 4.1, K2}.
///
///     snapshot user's pasteboard ─▶ promise transcript {+ manager markers}
///        ─▶ Cmd+V ─▶ wait for the read (receipt)
///             receipt       ─▶ delivered; caller restores the user's pasteboard shortly
///             no read at all ─▶ user's pasteboard back now ─▶ certainly not delivered
///             read before Cmd+V, or pasteboard replaced ─▶ unknown {counts as delivered}
@MainActor
enum PasteChannel {
    struct Attempt {
        var result: ChannelResult
        /// Still holding the transcript: the caller restores after a grace period.
        var openTransaction: PasteboardTransaction?
        /// How the pasteboard was closed, when the channel closed it itself.
        var close: PasteboardTransaction.Close?
        var receiptMilliseconds: Int?
    }

    static func run(text: String, environment env: PasteEnvironment) async -> Attempt {
        guard env.canPostEvents() else {
            return Attempt(result: .notDelivered(reason: "no_post_access"))
        }
        guard !env.secureInputEnabled() else {
            return Attempt(result: .blockedSecure)
        }
        guard let transaction = PasteboardTransaction.begin(
            text: text,
            on: env.pasteboard,
            sourceBundleID: env.sourceBundleID
        ) else {
            return Attempt(result: .notDelivered(reason: "pasteboard_write_failed"))
        }
        // Secure Event Input can switch on while the pasteboard was written.
        guard !env.secureInputEnabled() else {
            return Attempt(result: .blockedSecure, close: transaction.restore())
        }

        transaction.promise.arm()
        guard await env.postPaste() else {
            return Attempt(result: .notDelivered(reason: "post_failed"), close: transaction.restore())
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: env.receiptCeiling)
        while clock.now < deadline {
            if transaction.promise.reads.afterArm > 0 || !transaction.stillOwned { break }
            try? await Task.sleep(for: env.poll)
        }

        let reads = transaction.promise.reads
        if reads.afterArm > 0 {
            let milliseconds = reads.firstReceiptDelay.map { Int($0 / 1_000_000) }
            return Attempt(
                result: .delivered(.receipt),
                openTransaction: transaction,
                receiptMilliseconds: milliseconds
            )
        }
        if !transaction.stillOwned {
            // Someone replaced the pasteboard before any app read ours; what
            // was pasted, if anything, cannot be known. Their content stays.
            return Attempt(result: .unknown(reason: "pasteboard_replaced"), close: transaction.restore())
        }
        if reads.beforeArm > 0 {
            // A clipboard reader took the promise before Cmd+V; the target's
            // read would then not reach us. It may well have pasted.
            return Attempt(result: .unknown(reason: "read_before_paste"), close: transaction.restore())
        }
        // Nobody read the transcript: nothing was pasted. Take it back before
        // anything else runs, so a late read finds the user's own content.
        return Attempt(result: .notDelivered(reason: "no_receipt"), close: transaction.restore())
    }
}
