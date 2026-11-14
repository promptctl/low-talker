import Foundation
import LowTalkerCore
import WhisperKit

/// Which Hugging Face commits a model's two parts come from: the whisperkit-coreml commit
/// of its weights and the openai commit of the tokenizer they decode with.
///
/// An install from huggingface.co fetches both parts at one of these, so a store filled
/// from the hub holds exactly the revision it was given. `upstream(of:)` names the one
/// `main` points at now; a release keys its cached store by it and fetches at it.
public struct ModelRevision: Hashable, Sendable, LosslessStringConvertible {
    public let weights: Commit
    public let tokenizer: Commit

    public init(weights: Commit, tokenizer: Commit) {
        self.weights = weights
        self.tokenizer = tokenizer
    }

    /// `<weights commit>-<tokenizer commit>`, the form a cache key takes it in.
    public var description: String { "\(weights)-\(tokenizer)" }

    public init?(_ description: String) {
        let commits = description.split(separator: "-", omittingEmptySubsequences: false).map { Commit(String($0)) }
        guard commits.count == 2, let weights = commits[0], let tokenizer = commits[1] else { return nil }
        self.init(weights: weights, tokenizer: tokenizer)
    }

    /// A git commit hash as the hub writes it: 40 lowercase hex digits.
    public struct Commit: Hashable, Sendable, LosslessStringConvertible {
        public let description: String

        public init?(_ description: String) {
            guard description.count == 40, description.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            self.description = description
        }
    }

    /// The repo whisperkit-coreml weights come from.
    static let weightsRepo = "argmaxinc/whisperkit-coreml"

    /// The revision `main` names now: the commit it points at in the weights repo, and in
    /// the tokenizer repo those weights' config picks. Asks the hub three small questions
    /// and downloads no weights.
    public static func upstream(of model: Model) async throws -> ModelRevision {
        try await upstream(of: model, asking: Hub.get)
    }

    /// [LAW:effects-at-boundaries] The questions and what is made of the answers, with
    /// the asking handed in, so the answers can be ones captured from the hub.
    static func upstream(of model: Model, asking get: (URL) async throws -> Data) async throws -> ModelRevision {
        let weights = try await Hub.Revision.asking(get, for: "main", of: weightsRepo)
        let folder = try variantFolder(of: model, among: weights.files.map(\.path))
        let config = try await get(Hub.file("\(folder)/config.json", in: weightsRepo, at: weights.commit))
        let tokenizer = try await Hub.Revision.asking(get, for: "main", of: ModelVariant(modelConfig: config).tokenizerRepo)
        return ModelRevision(weights: weights.commit, tokenizer: tokenizer.commit)
    }

    /// The repo folder that holds `model`, chosen from `files` as `WhisperKit.download`
    /// chooses it: the one folder whose files match `*<model>/*`, or failing that the
    /// one matching `*openai*<model>/*`.
    ///
    /// [LAW:one-source-of-truth] exception: WhisperKit makes this choice inside a download
    /// that fetches only `main`, and exposes no function for it. The globs are matched by
    /// ArgmaxCore's own `matching(glob:)`, so only the fallback order is mirrored.
    static func variantFolder(of model: Model, among files: [String]) throws -> String {
        let candidates = ["*\(model.rawValue)/*", "*openai*\(model.rawValue)/*"].map { glob in
            Set(files.matching(glob: glob).compactMap { $0.split(separator: "/").first.map(String.init) })
        }
        guard let folders = candidates.first(where: { $0.count == 1 }), let folder = folders.first else {
            throw ModelInstallError.noVariantFolder(model: model, matches: candidates[0].sorted())
        }
        return folder
    }
}

/// The questions `upstream(of:)` asks, over the endpoint WhisperKit fetches from.
enum Hub {
    /// The commit a ref points at, and the files it holds with the sizes the hub gives
    /// them: each file's path in the repo, so `Manifest.File` carries it unchanged.
    struct Revision: Decodable {
        let commit: ModelRevision.Commit
        let files: [Manifest.File]

        private enum CodingKeys: String, CodingKey { case sha, siblings }
        private struct Sibling: Decodable { let rfilename: String; let size: Int64 }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let sha = try container.decode(String.self, forKey: .sha)
            guard let commit = ModelRevision.Commit(sha) else {
                throw DecodingError.dataCorruptedError(forKey: .sha, in: container, debugDescription: "not a commit: \(sha)")
            }
            self.commit = commit
            files = try container.decode([Sibling].self, forKey: .siblings).map { Manifest.File(path: $0.rfilename, size: $0.size) }
        }

        /// The manifest of the files in `folder`, or the repo's top when it is nil,
        /// that one of `globs` matches the way the hub client matches them (`fnmatch`,
        /// so `*` crosses `/`), for that folder of `repo`, the repo's copy in `store`.
        func manifest(of folder: String?, in repo: URL, store: URL, matching globs: [String]) throws -> Manifest {
            let prefix = folder.map { "\($0)/" } ?? ""
            return try Manifest(folder: Manifest.folder(folder.map { repo.appending(path: $0) } ?? repo, relativeTo: store), files: files.compactMap { file in
                guard file.path.hasPrefix(prefix) else { return nil }
                let path = String(file.path.dropFirst(prefix.count))
                return globs.contains { fnmatch($0, path, 0) == 0 } ? Manifest.File(path: path, size: file.size) : nil
            })
        }

        static func asking(_ get: (URL) async throws -> Data, for ref: String, of repo: String) async throws -> Revision {
            try await JSONDecoder().decode(Revision.self, from: get(Hub.revision(ref, of: repo)))
        }
    }

    static let endpoint = URL(string: Constants.defaultRemoteEndpoint)!

    /// Answered by the commit `ref` names in `repo`, and the files it holds; `blobs`
    /// asks for each file's size beside its name.
    static func revision(_ ref: String, of repo: String) -> URL {
        endpoint.appending(path: "api/models/\(repo)/revision/\(ref)").appending(queryItems: [URLQueryItem(name: "blobs", value: "true")])
    }

    static func file(_ path: String, in repo: String, at commit: ModelRevision.Commit) -> URL {
        endpoint.appending(path: "\(repo)/resolve/\(commit)/\(path)")
    }

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw ModelInstallError.downloadRefused(url: url, status: status) }
        return data
    }
}
