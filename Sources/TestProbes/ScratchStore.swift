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

    /// What a scratch install puts in one part of a Parakeet model: a stub folder's contents, if
    /// given, and `files` beside them.
    public struct Part {
        public let stubs: URL?
        public let files: [String: String]

        public init(copying stubs: URL? = nil, files: [String: String] = [:]) {
            self.stubs = stubs
            self.files = files
        }
    }

    /// Installs the parts of a Parakeet model `parts` names as ModelInstall lays them out, each in
    /// its repo's folder and recorded by its manifest; a part left out is not installed. Returns
    /// each installed part's folder.
    @discardableResult
    public func installParakeet(_ parts: [ModelPart: Part], model: ParakeetModel = .tdtV3) throws -> [ModelPart: URL] {
        let store = ModelStore(directory: root)
        var folders: [ModelPart: URL] = [:]
        for (part, contents) in parts {
            let folder = root.appending(components: "models").appending(path: model.source(of: part)!.repo)
            if let stubs = contents.stubs {
                try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: stubs, to: folder)
            }
            for (path, text) in contents.files {
                let url = folder.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let manifest = store.manifestURL(for: .parakeet(model), part)
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Manifest(recording: folder, relativeTo: root).write(to: manifest)
            folders[part] = folder
        }
        return folders
    }

    /// A spotter tokenizer a test can spell by eye: `▁`, the letters of `Zed`, and the pieces
    /// their merges make, `▁Zed` the last at id 5, laid out as tokenizer.json lays out BPE.
    public static let spotterTokenizer = """
        {"model": {"type": "BPE", "vocab": {"<unk>": 0, "\u{2581}": 1, "Z": 2, "e": 3, "d": 4, "\u{2581}Zed": 5, "\u{2581}Z": 6, "\u{2581}Ze": 7},
                   "merges": ["\u{2581} Z", "\u{2581}Z e", "\u{2581}Ze d"]}}
        """

    /// The stub Core ML models scripts/make-parakeet-stubs builds for `part` of a Parakeet model,
    /// with the published interface and arithmetic in place of weights. Throws naming the
    /// resource looked for when the test bundle lacks it.
    public static func parakeetStubs(_ part: ModelPart) throws -> URL {
        let path = "Fixtures/parakeet-stub/\(part.rawValue)"
        guard let url = Bundle.module.url(forResource: part.rawValue, withExtension: nil, subdirectory: "Fixtures/parakeet-stub") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: "TestProbes' bundle has no \(path)"])
        }
        return url
    }

    public var manifestURL: URL { root.appending(components: "installed", "test.json") }
    public var tokenizerManifestURL: URL { root.appending(components: "installed", "tokenizer", "test.json") }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
