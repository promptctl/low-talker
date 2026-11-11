import Foundation
@testable import Insertion
import Testing

/// A build read off a bundle.
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
}
