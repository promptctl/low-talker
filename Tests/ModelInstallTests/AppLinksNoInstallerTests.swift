import Foundation
import TestProbes
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Nothing the Xcode project builds - every app and input method that ships - has a way to
/// fetch a model. Read off the two graphs the build resolves rather than off call sites:
/// what Xcode links into each target, from the project xcodegen generated, and what each
/// package target depends on, from SwiftPM's own dump of the manifest. `model-tool`, which
/// SwiftPM builds and nothing ships, reaches the installer by the same read, so the read
/// is not blind. [LAW:one-way-deps]
///
/// The tools' own graphs and not a parse of project.yml or Package.swift: a parser is a
/// second map of the same territory, and the first draft of this test had two ways to
/// lie that the resolved graphs cannot - a product bundling a second target, and a
/// target adding to the template it extends. [LAW:one-source-of-truth]
///
/// The generated project is read, not generated here, for the reason
/// `InputMethodPlistTests` gives: `make test` runs xcodegen first, and a suite that
/// rewrote the project would do so under whatever build is running in the tree.
@Suite struct AppLinksNoInstallerTests {
    static let installer = "ModelInstall"
    static let modelTool = "model-tool"
    static let app = "LowTalker"

    /// Package.swift as SwiftPM reads it: each product to the targets it bundles, and each
    /// target to the package targets it depends on. Dumped into a scratch path of its own,
    /// so it neither waits on nor disturbs the build running this suite.
    static func package() async throws -> (products: [String: [String]], targets: [String: Set<String>]) {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "AppLinksNoInstallerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dump = try await run("/usr/bin/swift", ["package", "dump-package", "--package-path", repository.path, "--scratch-path", scratch.path])
        let json = try JSONSerialization.jsonObject(with: dump)
        let manifest = try #require(json as? [String: Any])
        let targets = try #require(manifest["targets"] as? [[String: Any]])
        let names = Set(try targets.map { try #require($0["name"] as? String) })
        try #require(names.contains("LowTalkerCore"), "read no targets out of the manifest: \(names)")
        let graph = try targets.map { target in
            let dependencies = try #require(target["dependencies"] as? [[String: Any]])
            // A dependency is one of `byName`, `target` or `product`, each holding the name
            // first. Only a package target of this package is an edge here: a product of
            // another package is where the walk stops.
            let named = try dependencies.map { dependency -> String? in
                let value = try #require(dependency.values.first as? [Any], "unrecognised dependency \(dependency)")
                return value.first as? String
            }
            return (try #require(target["name"] as? String), Set(named.compactMap { $0 }).intersection(names))
        }
        let products = try #require(manifest["products"] as? [[String: Any]]).map { product in
            (try #require(product["name"] as? String), try #require(product["targets"] as? [String]))
        }
        return (Dictionary(uniqueKeysWithValues: products), Dictionary(uniqueKeysWithValues: graph))
    }

    /// What Xcode links into each target it builds, off the project xcodegen wrote: the
    /// package products of every native target.
    static func project() async throws -> [String: Set<String>] {
        let pbxproj = repository.appending(path: "LowTalker.xcodeproj/project.pbxproj")
        try #require(FileManager.default.fileExists(atPath: pbxproj.path),
                     "\(pbxproj.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let json = try JSONSerialization.jsonObject(with: try await run("/usr/bin/plutil", ["-convert", "json", "-o", "-", pbxproj.path]))
        let project = try #require(json as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let targets = try objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" }.map { target in
            // A product of this package carries no package reference, as xcodegen writes
            // the project; one that does is another package's, and the walk stops there
            // the way the package side stops at a foreign product.
            let products = try (target["packageProductDependencies"] as? [String] ?? []).compactMap { id -> String? in
                let product = try #require(objects[id], "\(id) is not an object of the project")
                guard product["package"] == nil else { return nil }
                return try #require(product["productName"] as? String, "\(id) is not a package product")
            }
            return (try #require(target["name"] as? String), Set(products))
        }
        let graph = Dictionary(uniqueKeysWithValues: targets)
        // The app links this package's libraries, so a read that finds it linking none is blind.
        try #require(!(graph[app] ?? []).isEmpty, "read no package products linked into \(app): \(graph)")
        return graph
    }

    /// Every target reached from `roots`, themselves included.
    static func reach(_ roots: [String], in graph: [String: Set<String>]) -> Set<String> {
        var reached = Set<String>()
        var pending = roots
        while let next = pending.popLast() {
            if reached.insert(next).inserted { pending.append(contentsOf: graph[next] ?? []) }
        }
        return reached
    }

    /// The package targets a built target links, through the products it names.
    static func roots(of target: String, linking products: Set<String>, in package: [String: [String]]) throws -> [String] {
        try products.sorted().flatMap { product in
            try #require(package[product], "\(target) links \(product), which Package.swift does not export")
        }
    }

    /// Runs `tool` and hands back its stdout, or fails with its stderr: a tool that could
    /// not run must not read as a graph with nothing in it. [LAW:no-silent-failure]
    ///
    /// Waited on from a thread of its own: `swift package dump-package` runs for seconds, and
    /// a test blocked on it holds one of the three threads the CI runner's cooperative pool
    /// has, which starved the timed waits of every suite beside it (low-unfiled-50ff.cis).
    static func run(_ tool: String, _ arguments: [String]) async throws -> Data {
        let errors = FileManager.default.temporaryDirectory.appending(path: "AppLinksNoInstallerTests-\(UUID().uuidString).stderr")
        try #require(FileManager.default.createFile(atPath: errors.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: errors) }
        let (data, status) = try await onAThreadOfItsOwn { () throws -> (Data, Int32) in
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            // Stderr goes to a file rather than a second pipe, so reading stdout to its end
            // cannot wait on a stderr nobody is draining.
            process.standardError = try FileHandle(forWritingTo: errors)
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (data, process.terminationStatus)
        }
        let message = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
        try #require(status == 0, "\(tool) \(arguments.joined(separator: " ")) exited \(status): \(message)")
        return data
    }

    @Test func nothingTheProjectBuildsReachesTheInstaller() async throws {
        let package = try await Self.package()
        try #require(package.targets[Self.installer] != nil, "Package.swift declares no \(Self.installer) target")
        for (target, products) in try await Self.project().sorted(by: { $0.key < $1.key }) {
            let reached = Self.reach(try Self.roots(of: target, linking: products, in: package.products), in: package.targets)
            #expect(!reached.contains(Self.installer), "\(target) reaches \(Self.installer) through \(reached.sorted())")
        }
    }

    /// The same package read finds the installer beneath `model-tool`, so the read above is
    /// not blind.
    @Test func theModelToolReachesIt() async throws {
        let package = try await Self.package()
        try #require(package.targets[Self.modelTool] != nil, "Package.swift declares no \(Self.modelTool) target")
        #expect(Self.reach([Self.modelTool], in: package.targets).contains(Self.installer))
    }
}
