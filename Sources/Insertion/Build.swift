import Foundation

/// One build of LowTalker: the build number its bundle carries, and the source revision it
/// was built from.
///
/// Both, because the number counts releases (project.yml's CURRENT_PROJECT_VERSION), so
/// every build between two releases carries the same one, and a branch package would pass
/// as the release it replaced. The revision is what tells them apart. The number is kept
/// for the person reading, who knows a release by it.
///
/// The app and its input method come from one `xcodebuild` call, which hands both bundles
/// the same two values, so two processes of one build carry equal `Build`s and a process of
/// any other build does not. [FRAMING:representation]
///
/// Its JSON is what an input method says and every later app reads, so its fields keep their
/// names; `WireTests` pins the bytes.
public struct Build: Codable, Hashable, Sendable, CustomStringConvertible {
    public let number: String
    public let revision: String

    /// The Info.plist key the revision is under, which project.yml fills from `SOURCE_REVISION`.
    public static let revisionKey = "LTSourceRevision"

    public init(number: String, revision: String) {
        self.number = number
        self.revision = revision
    }

    /// [LAW:parse-dont-validate] The build `bundle` carries, or nothing when it carries no
    /// build number or no revision. The post-build step "The bundle carries the version
    /// project.yml sets" refuses to make such a bundle, so nothing here guesses one.
    public init?(of bundle: Bundle) {
        guard let number = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !number.isEmpty,
              let revision = bundle.object(forInfoDictionaryKey: Self.revisionKey) as? String, !revision.isEmpty
        else { return nil }
        self.init(number: number, revision: revision)
    }

    public var description: String { "build \(number) (\(revision))" }
}
