import Foundation

/// Whether a bare Return is held until the words dictated before it have landed, so a Return
/// typed while dictating sends the message with the dictation in it. Off by default: with it off, a
/// Return is never held and passes as it does with no input method in it.
///
/// [LAW:one-source-of-truth] The app's preferences are the record. The input method asks the app
/// about it at each Return and keeps no copy of its own.
public struct ReturnHoldSetting {
    private static let key = "holdReturnForDictation"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off until a person turns it on, and off when nothing was ever written.
    public var isOn: Bool { defaults.bool(forKey: Self.key) }

    public func set(_ on: Bool) {
        defaults.set(on, forKey: Self.key)
    }
}
