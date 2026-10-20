import Foundation
@testable import Insertion
import Testing

/// A build read off a bundle, and the one rule over two of them.
@Suite struct BuildTests {
    /// A bundle on disk carrying `info` as its Info.plist, at a path no other case uses, since
    /// a `Bundle` is kept by path for the life of the process.
    private static func bundle(carrying info: [String: String]) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory.appending(path: "build-\(UUID().uuidString).bundle")
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        return try #require(Bundle(url: url))
    }

    @Test func aBundleCarryingBothIsThatBuild() throws {
        let bundle = try Self.bundle(carrying: ["CFBundleVersion": "9", Build.revisionKey: "0123456789ab"])
        #expect(Build(of: bundle) == Build(number: "9", revision: "0123456789ab"))
    }

    @Test(arguments: [["CFBundleVersion": "9"], [Build.revisionKey: "0123456789ab"], ["CFBundleVersion": "9", Build.revisionKey: ""]])
    func aBundleMissingEitherIsNoBuild(info: [String: String]) throws {
        #expect(Build(of: try Self.bundle(carrying: info)) == nil)
    }

    /// The number alone counts releases, so two builds between releases differ only in
    /// revision, and are two builds.
    @Test func buildsMatchOnlyWhenEqual() {
        let app = Build(number: "9", revision: "0123456789ab")
        #expect(BuildMismatch(app: app, inputMethod: app) == nil)
        #expect(BuildMismatch(app: app, inputMethod: Build(number: "9", revision: "ba9876543210")) != nil)
        #expect(BuildMismatch(app: app, inputMethod: Build(number: "8", revision: "0123456789ab")) != nil)
        #expect(BuildMismatch(app: app, inputMethod: nil) != nil)
    }

    /// Words refused for a mismatch were never sent, so they are held to be offered again
    /// rather than kept as ones that may have landed.
    @Test func wordsRefusedForAMismatchWereNotSent() throws {
        let mismatch = try #require(BuildMismatch(app: Build(number: "9", revision: "a"), inputMethod: nil))
        #expect(!InsertFailure.buildMismatch(mismatch).wordsMayHaveLanded)
    }

    /// The warning names both builds and what fixes it, since the person can do nothing else.
    @Test func theWarningNamesBothBuildsAndTheFix() throws {
        let app = Build(number: "9", revision: "0123456789ab")
        let said = Build(number: "8", revision: "ba9876543210")
        let warning = try #require(BuildMismatch(app: app, inputMethod: said)).description
        #expect(warning.contains("\(app)") && warning.contains("\(said)") && warning.contains(BuildMismatch.fix))
        #expect(try #require(BuildMismatch(app: app, inputMethod: nil)).description.contains("saying no build"))
    }
}
