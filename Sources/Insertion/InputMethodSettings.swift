/// What the app tells the input method, on each greeting: whether to hold a bare Return for the
/// words it owes, and which keys to report to the app as they are pressed, without waiting.
///
/// [LAW:one-source-of-truth] The app's settings and its key table are the record; the input method
/// keeps a copy and nothing of its own. A key the app does not list is not reported, so the input
/// method sends nothing about any other key.
public struct InputMethodSettings: Codable, Equatable, Sendable {
    /// Whether a bare Return is held until the words the app owes have landed.
    public var holdsReturn: Bool
    /// The virtual key codes the input method reports to the app when each is pressed.
    public var reportedKeys: [UInt16]

    public init(holdsReturn: Bool, reportedKeys: [UInt16]) {
        self.holdsReturn = holdsReturn
        self.reportedKeys = reportedKeys
    }

    /// Off, and reporting nothing: what a fresh input method has until the app says otherwise.
    public static let none = InputMethodSettings(holdsReturn: false, reportedKeys: [])
}
