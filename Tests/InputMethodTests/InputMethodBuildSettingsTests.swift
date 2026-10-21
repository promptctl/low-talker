import Identity
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The settings the input method is built under carry `AppIdentity`'s names.
///
/// A bundle under a name with no `…inputmethod.dictation` in it registers nothing while
/// `TISRegisterInputSource` answers noErr. [LAW:no-silent-failure] What is read here is the
/// project xcodegen generates, the same reason `InputMethodPlistTests` reads the plist
/// xcodegen writes.
///
/// The identifier is read here and not off the Info.plist beside it, which carries the
/// literal `$(PRODUCT_BUNDLE_IDENTIFIER)`: `GENERATE_INFOPLIST_FILE` has Xcode synthesise
/// `CFBundleIdentifier` from the build setting, so the setting holds the value and the plist
/// holds only its name. [LAW:one-source-of-truth]
@Suite struct InputMethodBuildSettingsTests {
    /// Every build configuration that builds an input method, as the settings it resolves to.
    ///
    /// Recognised by a setting only an input method sets, never by the target's name.
    /// [LAW:behavior-not-structure]
    private static func inputMethodConfigurations() throws -> [[String: String]] {
        let url = repository.appending(path: "LowTalker.xcodeproj/project.pbxproj")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "LowTalker.xcodeproj has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let data = try Data(contentsOf: url)
        let project = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: Any])
        return objects.values
            .compactMap { $0 as? [String: Any] }
            .filter { $0["isa"] as? String == "XCBuildConfiguration" }
            .compactMap { $0["buildSettings"] as? [String: Any] }
            // Every setting that is a name, which is every setting asked for below; a
            // configuration also carries list-valued settings like the runpaths, and
            // reading the whole block as names would quietly match nothing at all.
            .map { $0.compactMapValues { $0 as? String } }
            .filter { $0["INPUT_SOURCE_ID"] != nil }
    }

    /// The names macOS files the bundle under, as the project resolves them: the identifier
    /// LaunchServices registers, and the name the post-build script writes into the one
    /// localized string the Input Sources list reads.
    @Test func theBundleIsBuiltUnderItsNames() throws {
        let configurations = try Self.inputMethodConfigurations()
        let mine = configurations.filter { $0["INPUT_SOURCE_ID"] == AppIdentity.inputSourceIdentifier }
        // Every configuration of the target, not the first, so a second configuration added
        // to project.yml is held to the names the same way the one it has today is.
        try #require(!mine.isEmpty,
                     "the project builds no input method under \(AppIdentity.inputSourceIdentifier); it builds \(configurations.compactMap { $0["INPUT_SOURCE_ID"] })")
        for settings in mine {
            #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == AppIdentity.inputMethodBundleIdentifier)
            #expect(settings["INPUT_METHOD_NAME"] == AppIdentity.displayName)
        }
    }

    /// IMK rule 3: the process the bundle launches is compiled on the main actor unless it says
    /// otherwise, as `swift build` compiles it. Xcode compiles the target's sources itself, so
    /// without this the bundle would be built under the other default.
    @Test func theBundleIsCompiledOnTheMainActorByDefault() throws {
        let configurations = try Self.inputMethodConfigurations()
        try #require(!configurations.isEmpty, "the project builds no input method")
        for settings in configurations {
            #expect(settings["SWIFT_DEFAULT_ACTOR_ISOLATION"] == "MainActor", "\(settings["INPUT_SOURCE_ID"] ?? "an input method") is compiled under \(settings["SWIFT_DEFAULT_ACTOR_ISOLATION"] ?? "no default isolation")")
        }
    }
}
