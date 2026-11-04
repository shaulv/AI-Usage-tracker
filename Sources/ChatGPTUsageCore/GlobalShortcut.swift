import Foundation

/// A user-chosen global keyboard shortcut: one key plus modifier keys.
///
/// Pure value type so the rules (what counts as a usable shortcut, how it is
/// stored, how it is shown) are unit-testable without AppKit. Modifier bits use
/// the Carbon masks, because the app registers the shortcut system-wide through
/// `RegisterEventHotKey`, which needs no Accessibility permission.
public struct GlobalShortcut: Equatable, Sendable {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// Every modifier bit this type understands; anything else is dropped.
    public static let allModifiers: UInt32 = command | shift | option | control

    /// The virtual key code (`kVK_*`), not a character, so it survives a
    /// keyboard-layout change.
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    /// A global shortcut needs Command, Control or Option. Shift alone (or no
    /// modifier) would hijack ordinary typing in every app.
    public var isValid: Bool {
        modifiers & (Self.command | Self.control | Self.option) != 0
            && Self.keyNames[keyCode] != nil
    }

    /// `⌃⌥⇧⌘` in the order macOS menus use, then the key.
    public var displayString: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        text += Self.keyNames[keyCode] ?? "?"
        return text
    }

    // MARK: - Storage

    /// `"<keyCode>:<modifiers>"`, the one value kept in UserDefaults.
    public var storageValue: String { "\(keyCode):\(modifiers)" }

    /// Returns nil for anything that is not a valid stored shortcut, so a
    /// corrupted preference falls back to "no shortcut" instead of crashing.
    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2,
              let code = UInt32(parts[0]),
              let mods = UInt32(parts[1])
        else { return nil }
        let candidate = GlobalShortcut(keyCode: code, modifiers: mods)
        guard candidate.isValid else { return nil }
        self = candidate
    }

    // MARK: - Key names (US layout virtual key codes)

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
