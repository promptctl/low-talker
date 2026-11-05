import AppKit
@testable import InputMethod
import Testing

/// Which keys steer dictation, held by the keys a person types and the modifiers that make a
/// Return another key. [LAW:behavior-not-structure] Asked of values, not of how the enum is built.
@Suite struct SteeringKeyTests {
    struct Typed: Sendable, CustomStringConvertible {
        let description: String
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
        let steers: Bool
    }

    static let keys: [Typed] = [
        // What steers: Return, and the keypad's Enter, whose flags carry the numeric pad.
        .init(description: "Return", keyCode: 36, flags: [], steers: true),
        .init(description: "keypad Enter", keyCode: 76, flags: [.numericPad], steers: true),
        .init(description: "Return with caps lock on", keyCode: 36, flags: [.capsLock], steers: true),
        // The device-dependent bits ride along on every real event and are not modifiers.
        .init(description: "Return with a device bit and nothing else", keyCode: 36, flags: NSEvent.ModifierFlags(rawValue: 0x20), steers: true),
        // What is another key: Option+Return is a newline in a terminal, Shift+Return one in a
        // chat box, and a Return under the Fn chord is the chord's.
        .init(description: "Shift+Return", keyCode: 36, flags: [.shift], steers: false),
        .init(description: "Control+Return", keyCode: 36, flags: [.control], steers: false),
        .init(description: "Option+Return", keyCode: 36, flags: [.option], steers: false),
        .init(description: "Right Option+Return, device bits included", keyCode: 36, flags: NSEvent.ModifierFlags(rawValue: 0x80140), steers: false),
        .init(description: "Command+Return", keyCode: 36, flags: [.command], steers: false),
        .init(description: "Fn+Return", keyCode: 36, flags: [.function], steers: false),
        .init(description: "Command+Shift+Return", keyCode: 36, flags: [.command, .shift], steers: false),
        .init(description: "keypad Enter with Option", keyCode: 76, flags: [.numericPad, .option], steers: false),
        // What is not Return at all.
        .init(description: "the letter e", keyCode: 14, flags: [], steers: false),
        .init(description: "Tab", keyCode: 48, flags: [], steers: false),
        .init(description: "Delete", keyCode: 51, flags: [], steers: false),
        .init(description: "the space bar", keyCode: 49, flags: [], steers: false),
    ]

    @Test(arguments: keys)
    func aKeyOtherThanEscapeIsASteeringKeyOnlyIfItIsABareReturn(typed: Typed) {
        #expect((SteeringKey(keyCode: typed.keyCode, flags: typed.flags) != nil) == typed.steers, "\(typed)")
    }

    /// Escape steers whatever is held with it: a held chord is a modifier on it, this process cannot
    /// tell the chord from another modifier, and the app answers whether a dictation is open to cancel.
    @Test(arguments: [
        NSEvent.ModifierFlags([]),
        [.option],
        NSEvent.ModifierFlags(rawValue: 0x80140),
        [.function],
        [.shift],
        [.command],
        [.control, .option, .command, .shift],
        [.capsLock],
    ])
    func escapeSteersWhateverIsHeldWithIt(flags: NSEvent.ModifierFlags) {
        #expect(SteeringKey(keyCode: 53, flags: flags) == .escape)
    }

    @Test func returnIsReturn() {
        #expect(SteeringKey(keyCode: 36, flags: []) == .return)
        #expect(SteeringKey(keyCode: 76, flags: [.numericPad]) == .return)
    }
}
