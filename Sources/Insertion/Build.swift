import Foundation
import Identity

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

/// The app and the input method answering it are not from one build.
///
/// [LAW:single-enforcer] The one place the rule is written: the inserter refuses to send
/// words across a mismatch, and the app's status line says one stands, both by asking here.
public struct BuildMismatch: Error, Equatable, Sendable, CustomStringConvertible {
    public let app: Build
    /// The build the input method said, or nothing when it said none, which is what every
    /// input method from before builds were compared says.
    public let inputMethod: Build?

    /// A mismatch between `app` and what the input method said, or nil when it said `app`.
    public init?(app: Build, inputMethod: Build?) {
        guard inputMethod != app else { return nil }
        self.app = app
        self.inputMethod = inputMethod
    }

    /// The two builds, as a status line and the log say them.
    public var facts: String {
        "the input method is \(inputMethod.map(\.description) ?? "from before builds were compared, saying no build"), and the app is \(app)"
    }

    /// What makes the two one build again: an install puts both bundles down from one build
    /// and starts both processes again.
    public static let fix = "reinstall \(AppIdentity.displayName) so the two match"

    public var description: String {
        "WARNING: Words go only to the input method of the app's own build: \(facts). Your dictation was not sent; it is held until the two match. To fix it, \(Self.fix)."
    }
}
