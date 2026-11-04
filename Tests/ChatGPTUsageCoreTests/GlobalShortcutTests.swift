import XCTest
@testable import ChatGPTUsageCore

final class GlobalShortcutTests: XCTestCase {
    func test_commandOptionKey_isValidAndDisplaysInMenuOrder() {
        let s = GlobalShortcut(keyCode: 0, modifiers: GlobalShortcut.command | GlobalShortcut.option)
        XCTAssertTrue(s.isValid)
        XCTAssertEqual(s.displayString, "⌥⌘A")
    }

    func test_shiftOnlyOrNoModifier_isInvalid() {
        XCTAssertFalse(GlobalShortcut(keyCode: 0, modifiers: GlobalShortcut.shift).isValid)
        XCTAssertFalse(GlobalShortcut(keyCode: 0, modifiers: 0).isValid)
    }

    func test_unknownKeyCode_isInvalid() {
        XCTAssertFalse(GlobalShortcut(keyCode: 999, modifiers: GlobalShortcut.command).isValid)
    }

    func test_storageRoundTrip() throws {
        let s = GlobalShortcut(keyCode: 49, modifiers: GlobalShortcut.control | GlobalShortcut.shift)
        let back = try XCTUnwrap(GlobalShortcut(storageValue: s.storageValue))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.displayString, "⌃⇧Space")
    }

    func test_corruptedStorage_isNil() {
        XCTAssertNil(GlobalShortcut(storageValue: ""))
        XCTAssertNil(GlobalShortcut(storageValue: "abc:def"))
        XCTAssertNil(GlobalShortcut(storageValue: "0:0"))
    }
}
