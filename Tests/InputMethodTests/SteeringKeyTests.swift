import AppKit
import Carbon.HIToolbox
@testable import InputMethod
import Insertion
import Testing

/// Which steering key a key is, by the modifiers it is held with: a Return held with a modifier is
/// another key that passes as typed, an Escape is an Escape whatever is held, and every other key is none.
/// [LAW:behavior-not-structure] Asked of the key and modifiers a key-down carries, not of how the rule is written.
@Suite struct SteeringKeyTests {
    struct Held: Sendable, CustomStringConvertible {
        let description: String
        let flags: NSEvent.ModifierFlags
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
        .init(description: "Option", flags: [.option], anotherKey: true),
        .init(description: "Right Option, device bits included", flags: NSEvent.ModifierFlags(rawValue: 0x80140), anotherKey: true),
        .init(description: "Command", flags: [.command], anotherKey: true),
        .init(description: "Fn", flags: [.function], anotherKey: true),
        .init(description: "Command and Shift", flags: [.command, .shift], anotherKey: true),
        .init(description: "the numeric pad and Option", flags: [.numericPad, .option], anotherKey: true),
    ]

    /// Return and the keypad's Enter, which both send a Return.
    static let returns: [UInt16] = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
    /// Keys that are no steering key under anything held: a letter, Tab, Delete, and F5, which AppKit
    /// binds to `complete:` as it binds Option+Escape.
    static let others: [UInt16] = [UInt16(kVK_ANSI_A), UInt16(kVK_Tab), UInt16(kVK_Delete), UInt16(kVK_F5)]

    @Test(arguments: returns, held)
    func aReturnHeldWithAModifierIsAnotherKey(keyCode: UInt16, held: Held) {
        #expect(SteeringKey(keyCode: keyCode, holding: held.flags) == (held.anotherKey ? nil : .return), "\(held)")
    }

    /// Option+Escape included, which AppKit binds to `complete:` rather than `cancelOperation:`.
    @Test(arguments: held)
    func anEscapeIsAnEscapeWhateverIsHeld(held: Held) {
        #expect(SteeringKey(keyCode: UInt16(kVK_Escape), holding: held.flags) == .escape, "\(held)")
    }

    @Test(arguments: others, held)
    func anyOtherKeyIsNoSteeringKey(keyCode: UInt16, held: Held) {
        #expect(SteeringKey(keyCode: keyCode, holding: held.flags) == nil, "\(keyCode) with \(held)")
    }
}
