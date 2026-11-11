import Foundation

/// Whether a bare Return is held until the words dictated before it have landed, so a Return
/// typed while dictating sends the message with the dictation in it. Off by default: with it off, a
/// Return is never held and passes as it does with no input method in it.
///
/// [LAW:one-source-of-truth] The app's preferences are the record. The input method asks the app
/// about it at each Return and keeps no copy of its own.
public enum ReturnHoldSetting {
    private static let key = "holdReturnForDictation"

    /// Off until a person turns it on, and off when nothing was ever written.
    public static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    public static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }
}
