import Foundation
import LowTalkerCore

/// A store root with a model folder and a tokenizer folder inside it, small files in
/// place of model weights, deleted when the test ends. What the core reads
/// (`ModelStoreTests`) and what the installer writes (`ModelInstallTests`) are two suites
/// over one layout, so the layout is built here once. [LAW:one-source-of-truth]
public struct ScratchStore: ~Copyable {
    public let root: URL
    public let folder: URL
    public let tokenizer: URL

    public static let tokenizerFiles = [
        "tokenizer.json": "{\"model\": {}}",
        "tokenizer_config.json": "{}",
    ]

    public static let files = [
        "config.json": "{}",
        "AudioEncoder.mlmodelc/model.mil": "program",
        "AudioEncoder.mlmodelc/weights/weight.bin": "0123456789",
    ]

    public init(files: [String: String], tokenizer tokenizerFiles: [String: String] = ScratchStore.tokenizerFiles) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ScratchStore-\(UUID().uuidString)")
        folder = root.appending(components: "models", "argmaxinc", "whisperkit-coreml", "openai_whisper-test")
        tokenizer = root.appending(components: "models", "openai", "whisper-test")
        for (base, files) in [(folder, files), (tokenizer, tokenizerFiles)] {
            for (path, contents) in files {
                let url = base.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Writes both manifests over what is on disk, as a finished install would.
    public func record() throws {
        try Manifest(recording: folder, relativeTo: root).write(to: manifestURL)
        try Manifest(recording: tokenizer, relativeTo: root).write(to: tokenizerManifestURL)
    }

    /// Puts `contents` where the store expects the manifest for model `test`.
    public func writeManifest(_ contents: String) throws -> URL {
        let url = manifestURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Installs a Parakeet model as ModelInstall lays out its repo: `stubs`' models, if
    /// given, and `files`, in the repo's folder, recorded by the model's manifest. Returns the
    /// folder.
    @discardableResult
    public func installParakeet(_ model: ParakeetModel = .tdtV3, copying stubs: URL? = nil, files: [String: String]) throws -> URL {
        let folder = root.appending(components: "models").appending(path: Model.parakeet(model).repo)
        if let stubs {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: stubs, to: folder)
        }
        for (path, contents) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let store = ModelStore(directory: root)
        try Manifest(recording: folder, relativeTo: root).write(to: store.manifestURL(for: .parakeet(model), .weights))
        return folder
    }

    /// The four stub Core ML models scripts/make-parakeet-stubs builds, with the published
    /// interface and arithmetic in place of weights. Throws naming the resource looked for
    /// when the test bundle lacks it.
    public static var parakeetStubs: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "parakeet-stub", withExtension: nil, subdirectory: "Fixtures") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/parakeet-stub", NSLocalizedDescriptionKey: "TestProbes' bundle has no Fixtures/parakeet-stub"])
            }
            return url
        }
    }

    public var manifestURL: URL { root.appending(components: "installed", "test.json") }
    public var tokenizerManifestURL: URL { root.appending(components: "installed", "tokenizer", "test.json") }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
