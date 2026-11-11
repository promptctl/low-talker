import AppKit
@testable import InputMethod
import Insertion
import Testing

/// Which steering key a command is, by the modifiers it is held with: a Return held with a modifier is
/// another key that passes as typed, and an Escape is an Escape whatever is held.
/// [LAW:behavior-not-structure] Asked of the command and modifiers a key arrives with, not of how the rule is written.
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

    @Test(arguments: held)
    func aReturnHeldWithAModifierIsAnotherKey(held: Held) {
        let key = SteeringKey(command: NSSelectorFromString("insertNewline:"), holding: held.flags)
        #expect(key == (held.anotherKey ? nil : .return), "\(held)")
    }

    @Test(arguments: held)
    func anEscapeIsAnEscapeWhateverIsHeld(held: Held) {
        #expect(SteeringKey(command: NSSelectorFromString("cancelOperation:"), holding: held.flags) == .escape, "\(held)")
    }
}
