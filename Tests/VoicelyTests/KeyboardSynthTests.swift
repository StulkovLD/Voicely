import Carbon
import XCTest
@testable import Voicely

/// What reaches the target app from the two key-based channels.
final class KeyboardSynthTests: XCTestCase {

    // MARK: - Cmd+V

    /// Four events, the way hands press it, with explicit flags on each: a
    /// modifier the user still holds cannot leak into the paste.
    func testPasteIsCommandDownVDownVUpCommandUp() throws {
        let source = CGEventSource(stateID: .privateState)
        let events = try XCTUnwrap(KeyboardSynth.pasteEvents(keyCode: 9, source: source))
        XCTAssertEqual(events.count, 4)
        let codes = events.map { $0.getIntegerValueField(.keyboardEventKeycode) }
        XCTAssertEqual(codes, [55, 9, 9, 55])
        XCTAssertEqual(events.map { $0.type.rawValue }, [CGEventType.flagsChanged, .keyDown, .keyUp, .flagsChanged].map(\.rawValue))
        XCTAssertEqual(events[0].flags.intersection(KeyboardSynth.blockingModifiers), .maskCommand)
        XCTAssertEqual(events[1].flags.intersection(KeyboardSynth.blockingModifiers), .maskCommand)
        XCTAssertEqual(events[2].flags.intersection(KeyboardSynth.blockingModifiers), .maskCommand)
        XCTAssertEqual(events[3].flags.intersection(KeyboardSynth.blockingModifiers), [])
    }

    private func layoutData(id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The rule behind the resolver, on the real function: on the ASCII-capable
    /// ABC layout the paste key is vk 9.
    func testPasteKeyOnABCIsTheVKey() throws {
        let abc = try XCTUnwrap(layoutData(id: "com.apple.keylayout.ABC"), "ABC ships with every Mac")
        XCTAssertEqual(KeyboardSynth.keyCode(typing: "v", layoutData: abc, keyboardType: UInt32(LMGetKbdType())), 9)
    }

    /// The trap: on Russian, vk 9 types "м" and no key types "v" — yet Cmd+V
    /// pastes there. Resolving against the current layout would find nothing.
    func testRussianLayoutHasNoVKeySoResolutionUsesTheASCIICapableOne() throws {
        let russian = try XCTUnwrap(layoutData(id: "com.apple.keylayout.Russian"), "Russian ships with every Mac")
        let kbd = UInt32(LMGetKbdType())
        XCTAssertEqual(KeyboardSynth.translate(keyCode: 9, layoutData: russian, keyboardType: kbd), "м")
        XCTAssertNil(KeyboardSynth.keyCode(typing: "v", layoutData: russian, keyboardType: kbd))
        XCTAssertNotNil(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        let resolved = KeyboardSynth.pasteKeyCode()
        let ascii = try XCTUnwrap(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        let pointer = try XCTUnwrap(TISGetInputSourceProperty(ascii, kTISPropertyUnicodeKeyLayoutData))
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        XCTAssertEqual(KeyboardSynth.translate(keyCode: resolved, layoutData: data, keyboardType: kbd), "v")
    }

    func testHeldModifiersAreCommandOptionControlShiftOnly() {
        XCTAssertTrue(KeyboardSynth.modifiersHeld(.maskAlternate))
        XCTAssertTrue(KeyboardSynth.modifiersHeld([.maskCommand, .maskNumericPad]))
        XCTAssertFalse(KeyboardSynth.modifiersHeld([]))
        XCTAssertFalse(KeyboardSynth.modifiersHeld(.maskAlphaShift), "Caps Lock is not a held key")
        XCTAssertFalse(KeyboardSynth.modifiersHeld(.maskSecondaryFn))
    }

    // MARK: - Typed text

    func testTypedEventsCarryTheChunkAndNoModifiers() throws {
        let chunk = Array("привет".utf16)
        let pair = try XCTUnwrap(KeyboardSynth.typingEvents(chunk: chunk, source: CGEventSource(stateID: .privateState)))
        for event in [pair.down, pair.up] {
            XCTAssertEqual(event.flags.intersection(KeyboardSynth.blockingModifiers), [])
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 32)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertEqual(String(utf16CodeUnits: buffer, count: length), "привет")
        }
        XCTAssertNil(KeyboardSynth.typingEvents(chunk: [], source: nil))
    }

    /// A line break typed into a terminal is Enter: it would run the command.
    func testTypingNormalizesEveryControlCharacterToASpace() {
        XCTAssertEqual(KeyboardSynth.typingNormalized("раз\nдва\r\nтри\tчетыре\u{7}"), "раз два три четыре ")
        XCTAssertEqual(KeyboardSynth.typingNormalized("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(KeyboardSynth.typingNormalized("обычный текст, ёж — §"), "обычный текст, ёж — §")
    }

    func testChunksStayWithinTheEventLimitAndRoundTrip() {
        let text = "проверка вставки один два три, and some English words too — ёжик 😀 👨‍👩‍👧 конец"
        let chunks = KeyboardSynth.typingChunks(of: text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= KeyboardSynth.typingChunkLimit })
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), text)
    }

    func testChunksNeverSplitACharacter() {
        let text = "a😀b👨‍👩‍👧c"
        for limit in 2...12 {
            let chunks = KeyboardSynth.typingChunks(of: text, maxLength: limit)
            for chunk in chunks {
                XCTAssertNotNil(String(utf16CodeUnits: chunk, count: chunk.count).unicodeScalars.first)
                XCTAssertFalse((0xD800...0xDBFF).contains(chunk.last!), "chunk ends inside a surrogate pair at limit \(limit)")
            }
            XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), text)
        }
    }

    /// Chromium sends a one-character insert as a real keypress, which a page
    /// can read as a shortcut; the last chunk borrows a character instead.
    func testNoTrailingOneCharacterChunk() {
        let text = String(repeating: "я", count: 21)
        let chunks = KeyboardSynth.typingChunks(of: text)
        XCTAssertEqual(chunks.map(\.count), [19, 2])
        XCTAssertEqual(KeyboardSynth.typingChunks(of: "я").map(\.count), [1], "a one-letter dictation is one letter")
    }

    func testEmptyTextHasNoChunks() {
        XCTAssertTrue(KeyboardSynth.typingChunks(of: "").isEmpty)
    }
}
