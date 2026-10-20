/// A macOS application identity, e.g. `com.apple.Safari`: the app an insert reached.
public struct BundleID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
