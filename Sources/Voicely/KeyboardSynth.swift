import AppKit
import Carbon

/// Synthetic keyboard for the two key-based insertion channels: Cmd+V and
/// typed text. Builders are pure (events are created, not posted) so the exact
/// shape of what reaches the target app is pinned by tests.
enum KeyboardSynth {
    static let commandKeyCode: CGKeyCode = 55  // kVK_Command
    static let ansiV: CGKeyCode = 9            // kVK_ANSI_V
    /// Typed events carry the text in their unicode string; the key code is
    /// only a carrier. macOS truncates the string at 20 UTF-16 units.
    static let typingCarrierKeyCode: CGKeyCode = 0
    static let typingChunkLimit = 20
    /// NX_DEVICELCMDKEYMASK.
    static let leftCommandDeviceBit: UInt64 = 0x08

    /// Modifiers a user may still be holding from the hotkey. Caps Lock and fn
    /// are not "held" in that sense and never block insertion.
    static let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    static func modifiersHeld(_ flags: CGEventFlags) -> Bool {
        !flags.intersection(blockingModifiers).isEmpty
    }

    static func physicalModifiersHeld() -> Bool {
        modifiersHeld(CGEventSource.flagsState(.hidSystemState))
    }

    // MARK: - Cmd+V

    /// The key that means "paste", resolved against the ASCII-capable layout.
    ///
    /// macOS matches Cmd-shortcuts against the ASCII-capable layout, not the
    /// current one: on a Russian layout `vk 9` types "м", yet Cmd+V pastes.
    /// Resolving against the current layout would find no "v" at all there.
    static func pasteKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiV }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return keyCode(typing: "v", layoutData: data, keyboardType: UInt32(LMGetKbdType())) ?? ansiV
    }

    /// The key that types `character` (unshifted, no dead keys) on a layout.
    /// Checks the ANSI position first, then every key code.
    static func keyCode(typing character: Character, layoutData: Data, keyboardType: UInt32) -> CGKeyCode? {
        let candidates = [ansiV] + (CGKeyCode(0)...CGKeyCode(127)).filter { $0 != ansiV }
        return candidates.first { code in
            translate(keyCode: code, layoutData: layoutData, keyboardType: keyboardType) == String(character)
        }
    }

    static func translate(keyCode: CGKeyCode, layoutData: Data, keyboardType: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Cmd down, V down, V up, Cmd up — the sequence a person's hands make.
    /// Flags are explicit on every event, so a modifier the user still holds
    /// cannot leak into them.
    static func pasteEvents(keyCode: CGKeyCode, source: CGEventSource?) -> [CGEvent]? {
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else { return nil }
        // The Command key becomes a flags-changed event; its device bit says
        // "left Command", as a real keyboard's would.
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | leftCommandDeviceBit)
        commandDown.flags = command
        keyDown.flags = command
        keyUp.flags = command
        commandUp.flags = []
        return [commandDown, keyDown, keyUp, commandUp]
    }

    // MARK: - Typed text

    /// A key-down/key-up pair carrying one chunk of text, with no modifiers.
    static func typingEvents(chunk: [UniChar], source: CGEventSource?) -> (down: CGEvent, up: CGEvent)? {
        guard !chunk.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: typingCarrierKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: typingCarrierKeyCode, keyDown: false)
        else { return nil }
        down.flags = []
        up.flags = []
        chunk.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        return (down, up)
    }

    /// Text safe to type into a terminal: a line break typed there is Enter,
    /// which runs the command. Every control character becomes a space.
    static func typingNormalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || scalar.value == 0x2028 || scalar.value == 0x2029
            scalars.append(isControl ? " " : scalar)
        }
        return String(scalars)
    }

    /// UTF-16 chunks of at most `maxLength` units that never split a
    /// character. A trailing chunk of one character is avoided: Chromium sends
    /// a one-character insert as a real keypress, which a page can take as a
    /// shortcut. A single character longer than the limit (a long emoji
    /// sequence) is split on scalar boundaries.
    static func typingChunks(of text: String, maxLength: Int = typingChunkLimit) -> [[UInt16]] {
        guard maxLength > 1 else { return text.isEmpty ? [] : [Array(text.utf16)] }
        var chunks: [[Character]] = []
        var current: [Character] = []
        var currentLength = 0
        for character in text {
            let length = character.utf16.count
            if currentLength + length > maxLength, !current.isEmpty {
                chunks.append(current)
                current = []
                currentLength = 0
            }
            current.append(character)
            currentLength += length
        }
        if !current.isEmpty { chunks.append(current) }

        if chunks.count >= 2, chunks[chunks.count - 1].count == 1, chunks[chunks.count - 2].count >= 2 {
            let moved = chunks[chunks.count - 2].removeLast()
            chunks[chunks.count - 1].insert(moved, at: 0)
            if chunks[chunks.count - 1].reduce(0, { $0 + $1.utf16.count }) > maxLength {
                // Undo: two wide characters do not fit together; keep the
                // original split rather than exceed the event limit.
                let back = chunks[chunks.count - 1].removeFirst()
                chunks[chunks.count - 2].append(back)
            }
        }

        return chunks.flatMap { characters -> [[UInt16]] in
            let units = Array(String(characters).utf16)
            guard units.count > maxLength else { return [units] }
            return scalarSafeSplit(units, maxLength: maxLength)
        }
    }

    private static func scalarSafeSplit(_ units: [UInt16], maxLength: Int) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxLength, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end -= 1
            }
            if end == start { end = min(start + 2, units.count) }
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }
}
