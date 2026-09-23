import Foundation

// MARK: - Signals

/// What Accessibility said about the focused element at commit time.
enum FocusKind: String, Equatable, Sendable {
    /// No answer: an Electron app with its accessibility tree off (VS Code
    /// answers kAXErrorCannotComplete), or an app too busy to reply.
    case silent
    case secure
    /// A text field or area whose selected text Accessibility can replace.
    case editableText = "editable_text"
    /// A text surface Accessibility cannot write: Terminal.app's scrollback,
    /// iTerm2, Qt fields.
    case readOnlyText = "read_only_text"
    /// xterm.js's input textarea inside a Chromium app (VS Code's terminal).
    case terminalInput = "terminal_input"
    /// Focus is somewhere that is not text: a list, a canvas, a page body.
    case other
}

enum FrontApp: String, Equatable, Sendable {
    case none
    case voicely
    /// The desktop and file windows: typing there type-selects files.
    case finder
    case app
}

struct InsertionSignals: Equatable, Sendable {
    var destination: DictationDestination = .atCursor
    var startedSecure = false
    var secureEventInput = false
    var front: FrontApp = .app
    var focus: FocusKind = .editableText
    var engine: AppEngine = .native
    /// The editable element lives inside web content (Safari, Firefox).
    var inWebArea = false
}

// MARK: - Plan

/// How text can reach the caret.
enum InsertionChannel: String, Equatable, Sendable {
    /// Accessibility write of the selected text; kept only where the result is
    /// read back honestly — native Cocoa text outside web content.
    case ax
    /// The transcript promised on the pasteboard, Cmd+V, the user's pasteboard
    /// restored after the target app reads it.
    case paste
    /// Unicode key events: terminals, and the last resort after a Cmd+V that
    /// no app read.
    case typing
}

enum InsertionPlan: Equatable, Sendable {
    /// Secure field or Secure Event Input: the text stays on disk only.
    case saveOnly
    /// No caret to aim at, or the user chose the clipboard: copy, with a toast.
    case copyOnly(reason: String)
    /// Channels in order; the next one runs only after "certainly not delivered".
    case deliver([InsertionChannel])
}

/// The decision "where and by which channels", as one pure function.
///
/// Text goes wherever the caret is at commit time — dictation is a stand-in
/// for typing. Secure beats everything. Accessibility decides nothing about
/// Chromium apps beyond "is this xterm's input": there it lies (writes are
/// accepted and dropped) or stays silent depending on whether some assistive
/// tool switched its tree on.
enum InsertionPlanner {
    static func plan(_ signals: InsertionSignals) -> InsertionPlan {
        if signals.startedSecure || signals.secureEventInput || signals.focus == .secure {
            return .saveOnly
        }
        if signals.destination == .clipboardOnly {
            return .copyOnly(reason: "destination")
        }
        switch signals.front {
        case .none:
            return .copyOnly(reason: "no_front_app")
        case .voicely:
            return .copyOnly(reason: "voicely_front")
        case .finder where signals.focus != .editableText:
            return .copyOnly(reason: "desktop")
        case .finder, .app:
            break
        }
        switch signals.focus {
        case .secure:
            return .saveOnly
        case .terminalInput:
            return .deliver([.typing])
        case .editableText:
            if signals.engine == .native, !signals.inWebArea {
                return .deliver([.ax, .paste, .typing])
            }
            return .deliver([.paste, .typing])
        case .readOnlyText:
            return signals.engine == .native ? .deliver([.typing]) : .deliver([.paste, .typing])
        case .silent:
            return .deliver([.paste, .typing])
        case .other:
            // Not text: typing would fire the app's single-key shortcuts.
            return .deliver([.paste])
        }
    }
}

// MARK: - Outcome law

enum Confirmation: String, Equatable, Sendable {
    /// Read back through Accessibility: the caret moved by exactly the text.
    case verified
    /// The target app read the promised transcript after Cmd+V.
    case receipt
    /// Sent, with no way to read it back (typed text, a moved caret).
    case unverified
}

/// Every channel answers with exactly one of these. "Don't know" is not
/// "not delivered": the chain moves on only from `notDelivered`, so a slow
/// app can never receive the text twice.
enum ChannelResult: Equatable, Sendable {
    case delivered(Confirmation)
    /// Certainly not delivered, and nothing was left behind.
    case notDelivered(reason: String)
    /// May have landed; counts as delivered for the chain.
    case unknown(reason: String)
    case blockedSecure
}

@MainActor
protocol InsertionChannelRunner: AnyObject {
    func attempt(_ channel: InsertionChannel) async -> ChannelResult
}

enum DeliveryChain {
    struct Outcome: Equatable, Sendable {
        /// Nil when every channel certainly did not deliver.
        var result: ChannelResult?
        var channel: InsertionChannel?
        /// `channel:reason` for each channel that handed over.
        var fallbackFrom: [String]
    }

    @MainActor
    static func run(_ channels: [InsertionChannel], with runner: InsertionChannelRunner) async -> Outcome {
        var fallbackFrom: [String] = []
        for channel in channels {
            let result = await runner.attempt(channel)
            if case .notDelivered(let reason) = result {
                fallbackFrom.append("\(channel.rawValue):\(reason)")
                continue
            }
            return Outcome(result: result, channel: channel, fallbackFrom: fallbackFrom)
        }
        return Outcome(result: nil, channel: nil, fallbackFrom: fallbackFrom)
    }
}

// MARK: - Accessibility read-back

struct TextRange: Equatable, Sendable {
    var location: Int
    var length: Int
}

/// Did an Accessibility write land? Compares caret and length before and after.
enum AXWriteCheck {
    enum Verdict: Equatable, Sendable {
        /// The caret sits right after the text and the length grew by it.
        case verified
        /// Something moved, not exactly as expected (autocorrect, length caps).
        case changed
        /// Nothing moved at all: the write was dropped.
        case unchanged
        /// Nothing could be read back.
        case unreadable
    }

    static func classify(
        before: TextRange,
        after: TextRange?,
        countBefore: Int?,
        countAfter: Int?,
        insertedLength: Int
    ) -> Verdict {
        let countKnown = countBefore != nil && countAfter != nil
        let countChanged = countKnown && countBefore != countAfter
        guard let after else {
            if countChanged { return .changed }
            return countKnown ? .unchanged : .unreadable
        }
        let expectedCaret = TextRange(location: before.location + insertedLength, length: 0)
        let expectedCount = countBefore.map { $0 - before.length + insertedLength }
        if after == expectedCaret, !countKnown || countAfter == expectedCount {
            return .verified
        }
        if after != before || countChanged {
            return .changed
        }
        return .unchanged
    }
}
