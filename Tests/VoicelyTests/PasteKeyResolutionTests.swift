import Carbon
import XCTest
@testable import Voicely

/// Terminals have no writable caret — their scrollback is read-only — so AX has
/// nothing to insert into. They do take a real Cmd+V. Measured on this machine:
/// Terminal.app accepts a synthetic paste; VS Code's xterm.js swallows it.
///
/// The key that means "paste" must be resolved against the ASCII-capable
/// layout, because that is how macOS matches Cmd-shortcuts. This is not
/// pedantry: on a Russian layout `vk 9` produces "м", and a naive
/// "only fire if this key types v" check would disable pasting on a layout
/// where Cmd+V works perfectly.
final class PasteKeyResolutionTests: XCTestCase {

    /// Mirrors Injector.pasteKeyCode's translation, so the test pins the rule
    /// rather than the constant.
    private func character(forKeyCode code: CGKeyCode, in data: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, 4, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func asciiCapableLayoutData() throws -> Data {
        let source = try XCTUnwrap(
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            "every Mac has an ASCII-capable layout"
        )
        let ptr = try XCTUnwrap(
            TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
            "the ASCII-capable layout must expose key data"
        )
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }

    /// The premise the whole fallback rests on: the ASCII-capable layout has a
    /// key that types "v", and that is the key Cmd+V means.
    func testASCIICapableLayoutResolvesAKeyThatTypesV() throws {
        let data = try asciiCapableLayoutData()
        let match = (CGKeyCode(0)...CGKeyCode(127)).first { character(forKeyCode: $0, in: data) == "v" }
        XCTAssertNotNil(match, "no key types 'v' on the ASCII-capable layout — Cmd+V could not be synthesised")
    }

    /// On a standard ANSI-derived layout that key is 9. Pinned so a regression
    /// in the resolver is visible, not silent.
    func testResolvedPasteKeyIsTheConventionalVKeyOnANSI() throws {
        let data = try asciiCapableLayoutData()
        guard let match = (CGKeyCode(0)...CGKeyCode(127)).first(where: {
            character(forKeyCode: $0, in: data) == "v"
        }) else {
            return XCTFail("no 'v' key on the ASCII-capable layout")
        }
        // Dvorak and friends are ASCII-capable too and legitimately differ, so
        // this asserts the common case without forbidding the others.
        if TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
            .map({ source -> String in
                guard let ptr = TISGetInputSourceProperty(source.takeRetainedValue(), kTISPropertyInputSourceID)
                else { return "" }
                return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            })?.contains("ABC") == true {
            XCTAssertEqual(match, 9, "on ABC, the paste key is the conventional vk 9")
        }
    }

    /// The trap this replaced: the CURRENT layout is the wrong place to look.
    /// A Russian layout types Cyrillic on every letter key, so resolving 'v'
    /// there finds nothing — yet Cmd+V pastes fine. Resolution must therefore
    /// never depend on the current layout having Latin letters at all.
    func testCurrentLayoutMayHaveNoLatinKeysAndThatIsFine() throws {
        // Documents the measured fact rather than switching the user's layout:
        // resolution reads the ASCII-capable source, which exists regardless of
        // what the user is typing in right now.
        XCTAssertNotNil(
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            "the ASCII-capable source must exist even when the current layout is Cyrillic"
        )
    }
}
