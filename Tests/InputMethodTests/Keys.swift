import AppKit
import Carbon.HIToolbox

/// The keys and the modifiers held with them that the input method's tests type, and the key-down
/// each makes, as IMK hands it to `handle`. [LAW:one-source-of-truth] One set for every suite, so a
/// key or modifier added here is typed everywhere.
enum Keys {
    struct Held: Sendable, CustomStringConvertible {
        let description: String
        let flags: NSEvent.ModifierFlags
        /// Whether a Return held so is another key.
        let anotherKey: Bool
    }

    static let held: [Held] = [
        // A bare Return, and the keypad's Enter, whose flags carry the numeric pad.
        .init(description: "nothing held", flags: [], anotherKey: false),
        .init(description: "the numeric pad", flags: [.numericPad], anotherKey: false),
        .init(description: "caps lock on", flags: [.capsLock], anotherKey: false),
        // The device-dependent bits ride along on every real event and are not modifiers.
        .init(description: "a device bit and nothing else", flags: NSEvent.ModifierFlags(rawValue: 0x20), anotherKey: false),
        // What is another key: Option+Return is a newline in a terminal, Shift+Return one in a chat box,
        // and a Return under the Fn chord is the chord's.
        .init(description: "Shift", flags: [.shift], anotherKey: true),
        .init(description: "Control", flags: [.control], anotherKey: true),
        // Option is the chord's modifier, and AppKit binds Option+Escape to `complete:`.
        .init(description: "Option", flags: [.option], anotherKey: true),
        .init(description: "Right Option, the default chord, device bits included", flags: NSEvent.ModifierFlags(rawValue: 0x80140), anotherKey: true),
        .init(description: "Command", flags: [.command], anotherKey: true),
        .init(description: "Fn", flags: [.function], anotherKey: true),
        .init(description: "Command and Shift", flags: [.command, .shift], anotherKey: true),
        .init(description: "the numeric pad and Option", flags: [.numericPad, .option], anotherKey: true),
    ]

    /// Return and the keypad's Enter, which both send a Return.
    static let returns = [kVK_Return, kVK_ANSI_KeypadEnter]
    /// Keys that are no steering key under anything held: a letter, Tab, Delete; F5, which AppKit binds
    /// to `complete:` as it binds Option+Escape; and Period and [, which under Command and Control AppKit
    /// binds to `cancelOperation:` as it binds Escape.
    static let others = [kVK_ANSI_A, kVK_Tab, kVK_Delete, kVK_F5, kVK_ANSI_Period, kVK_ANSI_LeftBracket]

    /// The key-down `keyCode` makes with `modifiers` held, at `timestamp`, typing `characters`.
    static func down(_ keyCode: Int, holding modifiers: NSEvent.ModifierFlags = [], at timestamp: TimeInterval = 1,
                     typing characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: UInt16(keyCode))!
    }
}
