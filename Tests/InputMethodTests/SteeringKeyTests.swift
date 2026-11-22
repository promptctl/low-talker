import AppKit
import Carbon.HIToolbox
@testable import InputMethod
import Insertion
import Testing

/// Which steering key a key is, by the modifiers it is held with: a Return held with a modifier is
/// another key that passes as typed, an Escape is an Escape whatever is held, and every other key is none.
/// [LAW:behavior-not-structure] Asked of the key and modifiers a key-down carries, not of how the rule is written.
@Suite struct SteeringKeyTests {
    @Test(arguments: Keys.returns, Keys.held)
    func aReturnHeldWithAModifierIsAnotherKey(keyCode: Int, held: Keys.Held) {
        #expect(SteeringKey(keyCode: UInt16(keyCode), holding: held.flags) == (held.anotherKey ? nil : .return), "\(held)")
    }

    /// Option+Escape included, which AppKit binds to `complete:` rather than `cancelOperation:`.
    @Test(arguments: Keys.held)
    func anEscapeIsAnEscapeWhateverIsHeld(held: Keys.Held) {
        #expect(SteeringKey(keyCode: UInt16(kVK_Escape), holding: held.flags) == .escape, "\(held)")
    }

    /// Command+Period and Control+[ included, which AppKit binds to `cancelOperation:` as it binds Escape.
    @Test(arguments: Keys.others, Keys.held)
    func anyOtherKeyIsNoSteeringKey(keyCode: Int, held: Keys.Held) {
        #expect(SteeringKey(keyCode: UInt16(keyCode), holding: held.flags) == nil, "\(keyCode) with \(held)")
    }
}
