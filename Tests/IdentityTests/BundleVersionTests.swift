import Identity
import Insertion
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Every bundle's version comes from one place, project.yml's two settings.
///
/// Held here on what xcodegen writes: each generated Info.plist names the settings rather
/// than a version of its own, and the project sets both once, with no target setting its own.
/// What ships is held by the build itself - the post-build step "The bundle carries the
/// version project.yml sets" fails `make app` when a bundle's plist does not match - since
/// no test sees a shipped bundle. [LAW:single-enforcer] Each of the two checks one thing.
///
/// Read off the generated files, which `make test` writes first; `swift test` alone does
/// not. [LAW:effects-at-boundaries]
@Suite struct BundleVersionTests {
    private static func generated(_ path: String) throws -> Data {
        let url = repository.appending(path: path)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(path) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        return try Data(contentsOf: url)
    }

    /// Each plist defers to the settings. A literal here is a second version, and the one
    /// xcodegen writes by default - 1.0 - is not the one any bundle ships. Named from
    /// `AppIdentity`, not by listing App/Generated, which keeps whatever an older xcodegen
    /// run wrote.
    @Test(arguments: ["\(AppIdentity.displayName)-Info.plist", "\(AppIdentity.displayName)-InputMethod-Info.plist"])
    func everyGeneratedPlistTakesItsVersionFromTheSettings(name: String) throws {
        let data = try Self.generated("App/Generated/\(name)")
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
        #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
        #expect(plist[Build.revisionKey] as? String == "$(SOURCE_REVISION)")
    }

    /// The project sets both, for every configuration: the version a person reads, and a
    /// build number above zero, since that is what an updater compares. No target sets
    /// either, because a target's own value is the one its bundle ships and the post-build
    /// step, reading that target's settings, would agree with it. [LAW:one-source-of-truth]
    /// Nothing in the project sets the source revision: the Makefile hands it to the one
    /// xcodebuild call, so the app and its input method carry the same one.
    @Test func theProjectAloneSetsBoth() throws {
        let project = try #require(PropertyListSerialization.propertyList(from: Self.generated("LowTalker.xcodeproj/project.pbxproj"), format: nil) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let root = try #require(objects[project["rootObject"] as? String ?? ""])
        let list = try #require(objects[root["buildConfigurationList"] as? String ?? ""])
        let projectLevel = Set(try #require(list["buildConfigurations"] as? [String]))
        try #require(!projectLevel.isEmpty)
        for (id, object) in objects where object["isa"] as? String == "XCBuildConfiguration" {
            let settings = try #require(object["buildSettings"] as? [String: Any])
            let name = object["name"] as? String ?? id
            #expect(settings["SOURCE_REVISION"] == nil, "\(name) sets a source revision of its own")
            if projectLevel.contains(id) {
                #expect((settings["MARKETING_VERSION"] as? String)?.isEmpty == false, "project \(name)")
                #expect(((settings["CURRENT_PROJECT_VERSION"] as? String).flatMap(UInt.init) ?? 0) > 0, "project \(name)")
            } else {
                #expect(settings["MARKETING_VERSION"] == nil && settings["CURRENT_PROJECT_VERSION"] == nil,
                        "a target's \(name) configuration sets its own version")
            }
        }
    }
}
