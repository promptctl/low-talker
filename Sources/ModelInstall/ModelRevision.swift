import Foundation
import LowTalkerCore
import WhisperKit

/// Which Hugging Face commits a model's parts come from, one for each part: for a Whisper
/// model, the whisperkit-coreml commit of its weights and the openai commit of the tokenizer
/// they decode with; for Parakeet, the commit of its own repo, whose weights ship their
/// vocabulary, and of each repo its word spotter's halves come from.
///
/// An install from huggingface.co fetches every part at one of these, so a store filled
/// from the hub holds exactly the revision it was given. `upstream(of:)` names the one
/// `main` points at now; a release keys its cached store by it and fetches at it.
///
/// [LAW:types-are-the-program] [LAW:parse-dont-validate] A revision is made for a model, with a
/// commit for each of that model's parts and no other, so its text is read back against the
/// model it names: two models whose parts number the same can never read each other's.
public struct ModelRevision: Hashable, Sendable, CustomStringConvertible {
    public let model: Model
    private let commits: [ModelPart: Commit]

    /// The revision of `model` at `commits`, or nil unless they name exactly its parts.
    public init?(of model: Model, _ commits: [ModelPart: Commit]) {
        guard Set(commits.keys) == Set(model.parts) else { return nil }
        self.model = model
        self.commits = commits
    }

    /// `part`'s commit. A part the model does not have is a bug in the asking, and traps.
    public func commit(of part: ModelPart) -> Commit {
        guard let commit = commits[part] else { preconditionFailure("\(model) has no \(part)") }
        return commit
    }

    /// `model`'s revision read from its text, its commits in the order of its parts.
    public init?(of model: Model, _ description: String) {
        let commits = description.split(separator: "-", omittingEmptySubsequences: false).map { Commit(String($0)) }
        guard commits.count == model.parts.count, !commits.contains(nil) else { return nil }
        self.init(of: model, Dictionary(uniqueKeysWithValues: zip(model.parts, commits.map { $0! })))
    }

    /// The commits joined by `-` in `ModelPart`'s order, the form a cache key takes it in: a
    /// Whisper model's `<weights>-<tokenizer>`.
    public var description: String {
        ModelPart.allCases.compactMap { commits[$0]?.description }.joined(separator: "-")
    }

    /// A git commit hash as the hub writes it: 40 lowercase hex digits.
    public struct Commit: Hashable, Sendable, LosslessStringConvertible {
        public let description: String

        public init?(_ description: String) {
            guard description.count == 40, description.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            self.description = description
        }
    }

    /// The revision `main` names now: the commit it points at in the weights repo, and in each
    /// other part's repo: for a Whisper model, the tokenizer repo those weights' config picks.
    /// Asks the hub at most three small questions and downloads no weights.
    public static func upstream(of model: Model) async throws -> ModelRevision {
        try await upstream(of: model, asking: Hub.get)
    }

    /// [LAW:effects-at-boundaries] The questions and what is made of the answers, with
    /// the asking handed in, so the answers can be ones captured from the hub.
    static func upstream(of model: Model, asking get: (URL) async throws -> Data) async throws -> ModelRevision {
        let weights = try await Hub.Revision.asking(get, for: "main", of: model.repo)
        var commits: [ModelPart: Commit] = [.weights: weights.commit]
        switch model {
        case .parakeet(let parakeet):
            for part in model.parts where part != .weights {
                commits[part] = try await Hub.Revision.asking(get, for: "main", of: parakeet.source(of: part)!.repo).commit
            }
        case .whisperKit:
            let folder = try variantFolder(of: model, among: weights.files.map(\.path))
            let config = try await get(Hub.file("\(folder)/config.json", in: model.repo, at: weights.commit))
            commits[.tokenizer] = try await Hub.Revision.asking(get, for: "main", of: ModelVariant(modelConfig: config).tokenizerRepo).commit
        }
        // The commits are one per part by the loop above, so the revision is made.
        return ModelRevision(of: model, commits)!
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

/// The revision of each model an install takes from huggingface.co, written
/// `<model>@<revision>` and joined by `+`: the form `model-tool revision` prints, a cache key
/// names a store by, and `download --from` takes back.
///
/// [LAW:one-source-of-truth] One text for all three, so the commits a store is keyed by are the
/// commits it is fetched at.
public struct ModelRevisions: Hashable, Sendable, LosslessStringConvertible {
    public let revisions: [Model: ModelRevision]

    /// Each revision under the model it was made for, so the one an install of a model takes is
    /// that model's. Nil when two are for one model.
    public init?(_ revisions: [ModelRevision]) {
        var byModel: [Model: ModelRevision] = [:]
        for revision in revisions {
            guard byModel.updateValue(revision, forKey: revision.model) == nil else { return nil }
        }
        self.revisions = byModel
    }

    public var description: String {
        revisions.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)@\($0.value)" }.joined(separator: "+")
    }

    public init?(_ description: String) {
        var revisions: [ModelRevision] = []
        for entry in description.split(separator: "+", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, let model = Model(rawValue: String(parts[0])), let revision = ModelRevision(of: model, String(parts[1])) else { return nil }
            revisions.append(revision)
        }
        self.init(revisions)
    }

    /// The revisions `main` names now for each of `models`, which are distinct.
    public static func upstream(of models: [Model]) async throws -> ModelRevisions {
        var revisions: [ModelRevision] = []
        for model in models { revisions.append(try await ModelRevision.upstream(of: model)) }
        return ModelRevisions(revisions)!
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
