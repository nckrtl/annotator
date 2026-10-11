/// A global shortcut: a virtual key code plus modifiers.
public struct Hotkey: Codable, Sendable, Equatable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// The key as typed, for display ("A").
    public var key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌃⌥A. Key code 0 is kVK_ANSI_A.
    public static let standard = Hotkey(keyCode: 0, modifiers: [.control, .option], key: "A")

    /// A shortcut needs at least one of ⌃, ⌥ or ⌘, or it would swallow normal typing.
    public var isValid: Bool { !modifiers.intersection([.control, .option, .command]).isEmpty }

    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    /// Carbon modifier flags for `RegisterEventHotKey`.
    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= 1 << 8 }  // cmdKey
        if modifiers.contains(.shift) { flags |= 1 << 9 }  // shiftKey
        if modifiers.contains(.option) { flags |= 1 << 11 }  // optionKey
        if modifiers.contains(.control) { flags |= 1 << 12 }  // controlKey
        return flags
    }
}
