import Foundation
import GrammaticalNumber
import LowTalkerCore
import WhisperKit

/// Making a store whole: the write side of `ModelStore`, in the module only the build's
/// `model-tool` links.
///
/// [LAW:one-way-deps] The app loads the store its bundle carries, read-only, through
/// LowTalkerCore alone. Every way of writing a store - fetching from huggingface.co or a
/// published base, copying from another store, packing one for a base to serve - is here,
/// so "the app cannot download" is a fact of the dependency graph rather than of which
/// calls the app happens to make. `AppLinksNoInstallerTests` reads that graph.
extension ModelStore {
    /// The installed model, taking whatever the store lacks from `source` first. A
    /// part already whole here is not taken again, so a damaged install costs only
    /// the damaged parts, and an installed one costs nothing. One installer at a
    /// time: a second, from any process, waits for the first.
    ///
    /// [LAW:dataflow-not-control-flow] The sequence never changes; whether a part is
    /// fetched is decided by its `Recording`, the domain's own discriminator, judged
    /// under the lock so it describes what this installer owns.
    public func install(
        _ model: Model,
        from source: ModelSource,
        phase: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> InstalledModel {
        try await InstallLock.holding(directory, waiting: { phase(.waitingForAnotherInstall) }) {
            if case .installed(let installed) = try presence(of: model) { return installed }
            return try await OpenSource.with(source, model, beside: self, phase: phase) { source in
                // [LAW:one-source-of-truth] The host `upstream(of:)` named the revision on,
                // rather than HF_ENDPOINT, which the client would read otherwise.
                let hub = HubApiWrapper(downloadBase: directory, endpoint: Hub.endpoint.absoluteString)
                let weights = try await whole(.weights, of: model) {
                    switch source {
                    case .huggingFace(let revision):
                        return try await fromHub(ModelRevision.weightsRepo, at: revision.weights, through: hub, phase: phase) { listing in
                            (try ModelRevision.variantFolder(of: model, among: listing.files.map(\.path)), ["*"])
                        }
                    case .store(let store):
                        return try await copy(.weights, of: model, from: store, phase: phase)
                    }
                }
                let folder = directory.appending(path: weights.folder)
                _ = try await whole(.tokenizer, of: model) {
                    switch source {
                    case .huggingFace(let revision):
                        // WhisperKit fetches the tokenizer on first load, from the hub,
                        // when it is not already here; taking it now is what lets that
                        // load, and every one after, run with the network off.
                        //
                        // [LAW:one-source-of-truth] exception: the files are the ones that
                        // load takes (`Hub.loadConfig` in ArgmaxCore, internal), fetched
                        // here at the revision, which the load cannot be given.
                        let variant = try ModelVariant(modelConfig: Data(contentsOf: folder.appending(path: "config.json")))
                        return try await fromHub(variant.tokenizerRepo, at: revision.tokenizer, through: hub, phase: phase) { _ in
                            (nil, ["config.json", "tokenizer_config.json", "chat_template.jinja", "chat_template.json", "tokenizer.json"])
                        }
                    case .store(let store):
                        return try await copy(.tokenizer, of: model, from: store, phase: phase)
                    }
                }
                return InstalledModel(model: model, folder: folder, hub: directory)
            }
        }
    }

    /// Writes `<directory>/<model>.zip`, the archive a published source serves: a
    /// store holding `model` alone, taken from this store, which must hold it whole.
    ///
    /// [LAW:composability] Packing is an install into an empty store and a zip of the
    /// result, so an archive holds exactly what an install certifies, manifests and
    /// all, and nothing a hub client left beside it.
    public func pack(_ model: Model, into directory: URL, phase: @escaping @Sendable (InstallPhase) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        // [LAW:no-silent-failure] exception: a defer cannot throw, and a staging copy
        // left behind costs disk, not correctness.
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staging = ModelStore(directory: scratch.appending(path: "store"))
        _ = try await staging.install(model, from: .store(self), phase: phase)
        let archive = directory.appending(path: ModelSource.archiveName(of: model))
        try await Archive.pack(staging.directory, to: archive)
        return archive
    }

    /// The part's manifest, taking the part from `fetch` and recording what arrived
    /// when it is not already whole here.
    private func whole(_ part: ModelPart, of model: Model, fetch: () async throws -> Manifest) async throws -> Manifest {
        if case .whole(let manifest) = try recording(part, of: model) { return manifest }
        let manifest = try await fetch()
        try manifest.write(to: manifestURL(for: model, part))
        return manifest
    }

    /// The part `repo` holds at `revision`: the files `globs` match, as the hub client
    /// matches them, in the folder of the repo `locate` names from its listing, or the
    /// repo's top when it names none.
    ///
    /// [LAW:one-source-of-truth] The globs that choose what the client downloads also
    /// choose what the manifest lists, so the two cannot name different files.
    private func fromHub(
        _ repo: String,
        at revision: ModelRevision.Commit,
        through hub: HubApiWrapper,
        phase: @escaping @Sendable (InstallPhase) -> Void,
        locate: (Hub.Revision) throws -> (folder: String?, globs: [String])
    ) async throws -> Manifest {
        let listing = try await Hub.Revision.asking(Hub.get, for: revision.description, of: repo)
        let (folder, globs) = try locate(listing)
        let local = hub.localRepoLocation(HubApiWrapper.Repo(id: repo))
        let manifest = try listing.manifest(of: folder, in: local, store: directory, matching: globs)
        return try await filled(manifest, phase: phase) {
            phase(.downloading(fractionCompleted: 0))
            _ = try await hub.snapshot(from: HubApiWrapper.Repo(id: repo), revision: revision.description, matching: globs.map { [folder, $0].compactMap(\.self).joined(separator: "/") }) {
                phase(.downloading(fractionCompleted: $0.fractionCompleted))
            }
            // [LAW:no-silent-failure] The hub client answers cancellation by returning
            // the folder as far as it got, without throwing; that is a cancellation,
            // not a download that came up short.
            try Task.checkCancellation()
        }
    }

    /// `manifest`, once `fill` has put its files here at the sizes it lists.
    ///
    /// [LAW:single-enforcer] The one judge of whole for every source. The hub client
    /// trusts its own sidecar once a file exists and never hashes the file, so a
    /// truncated file would come back as "already downloaded", and a copy cannot be
    /// renamed over a folder. Every file the manifest rejects is removed before `fill`
    /// runs, so nothing is trusted and nothing is in the way, and anything still
    /// rejected after it fails the install.
    func filled(_ manifest: Manifest, phase: (InstallPhase) -> Void, by fill: () async throws -> Void) async throws -> Manifest {
        let folder = directory.appending(path: manifest.folder)
        let evictions = try manifest.faults(in: folder).filter { $0.kind != .missing }.map(\.path)
        if !evictions.isEmpty { phase(.evicting(evictions)) }
        for path in evictions {
            try FileManager.default.removeItem(at: folder.appending(path: path))
        }
        try await fill()
        let faults = try manifest.faults(in: folder)
        guard faults.isEmpty else { throw ModelInstallError.incomplete(folder: folder, faults: faults) }
        return manifest
    }

    /// Copies the files `source`'s manifest lists for the part to the same paths
    /// here, and hands back that manifest once the copies verify against it.
    ///
    /// Each file lands under a temporary name and is renamed into place, so a copy
    /// stopped part way leaves no listed file half written. Only the listed files are
    /// copied: a sidecar beside them in the source is not the model.
    private func copy(_ part: ModelPart, of model: Model, from source: ModelStore, phase: (InstallPhase) -> Void) async throws -> Manifest {
        let manifest: Manifest
        switch try source.recording(part, of: model) {
        case .whole(let whole): manifest = whole
        case .unrecorded: throw ModelInstallError.sourceLacks(source: source.directory, model: model, part: part, reason: "not installed there")
        case .damaged(let damage): throw ModelInstallError.sourceLacks(source: source.directory, model: model, part: part, reason: damage.description)
        }
        let from = source.directory.appending(path: manifest.folder)
        let to = directory.appending(path: manifest.folder)
        return try await filled(manifest, phase: phase) {
            phase(.copying)
            for file in manifest.files {
                let destination = to.appending(path: file.path)
                let incoming = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: incoming.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try FileManager.default.copyItem(at: from.appending(path: file.path), to: incoming)
                    guard rename(incoming.path, destination.path) == 0 else {
                        throw ModelInstallError.renameFailed(from: incoming, to: destination, errno: errno)
                    }
                } catch {
                    // A hidden name is never recorded or evicted, so a partial copy left
                    // here would outlive every retry. [LAW:no-silent-failure] exception:
                    // the copy's own error is the one the caller needs; a failed removal
                    // of what may never have been created adds nothing to it.
                    try? FileManager.default.removeItem(at: incoming)
                    throw error
                }
            }
        }
    }

    /// What `install` is doing now. `waitingForAnotherInstall` is reported once,
    /// when the lock is found held; `downloading` repeats as the fraction grows.
    ///
    /// [LAW:one-source-of-truth] The words every surface shows for a phase live here,
    /// so two terminals cannot describe the same moment differently.
    public enum InstallPhase: Equatable, Sendable, CustomStringConvertible {
        case waitingForAnotherInstall
        case downloading(fractionCompleted: Double)
        /// A published archive has arrived and is being unzipped.
        case unpacking
        /// Files are being copied in from another store.
        case copying
        /// Files here that are not the size the hub lists are being removed, so the
        /// download takes them again.
        case evicting([String])

        public var description: String {
            switch self {
            case .waitingForAnotherInstall: "waiting for another install"
            case .downloading(let fraction): "downloading \(Int(fraction * 100))%"
            case .unpacking: "unpacking model"
            case .copying: "copying model"
            case .evicting(let paths): "removing \(counted(paths.count, "damaged file", "damaged files")): \(paths.joined(separator: ", "))"
            }
        }
    }
}

/// One installer per store at a time, across processes: two `model-tool download`s into one
/// directory would evict and write the same files under each other.
///
/// [LAW:no-ambient-temporal-coupling] The store owns the order of evict, download,
/// and manifest write. A second installer waits its turn by polling the lock between
/// sleeps, so no cooperative thread is held for the minutes a download can take.
private enum InstallLock {
    static func holding<T>(_ directory: URL, waiting: () -> Void, _ body: () async throws -> T) async throws -> T {
        let lock = directory.appending(components: "installed", ".lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ModelInstallError.lockUnavailable(lock: lock, errno: errno)
        }
        defer { close(descriptor) }
        if try !acquire(descriptor, lock: lock) {
            waiting()
            while try !acquire(descriptor, lock: lock) {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        return try await body()
    }

    /// False while another process holds the lock; any other refusal is an error.
    private static func acquire(_ descriptor: Int32, lock: URL) throws -> Bool {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            guard errno == EWOULDBLOCK else {
                throw ModelInstallError.lockUnavailable(lock: lock, errno: errno)
            }
            return false
        }
        return true
    }
}

public enum ModelInstallError: Error, Equatable, CustomStringConvertible {
    case lockUnavailable(lock: URL, errno: Int32)
    /// A source store that does not hold the part whole, so there is nothing to take.
    case sourceLacks(source: URL, model: Model, part: ModelPart, reason: String)
    /// A published base or huggingface.co answered with something other than what was asked.
    case downloadRefused(url: URL, status: Int?)
    /// No single folder in the weights repo is the model's, so no download could take one.
    case noVariantFolder(model: Model, matches: [String])
    case dittoFailed(arguments: [String], status: Int32, message: String)
    case renameFailed(from: URL, to: URL, errno: Int32)
    /// A download or copy finished without putting every file its manifest lists in place,
    /// at its size.
    case incomplete(folder: URL, faults: [Manifest.Fault])

    public var description: String {
        switch self {
        case .lockUnavailable(let lock, let errno):
            "cannot lock \(lock.path): \(String(cString: strerror(errno)))"
        case .sourceLacks(let source, let model, let part, let reason):
            "\(source.path) cannot supply the \(part) of \(model): \(reason)"
        case .downloadRefused(let url, let status):
            "\(url.absoluteString) answered \(status.map { "HTTP \($0)" } ?? "with no HTTP status")"
        case .noVariantFolder(let model, let matches):
            "no single folder in \(ModelRevision.weightsRepo) holds \(model): \(matches.isEmpty ? "none match" : matches.joined(separator: ", "))"
        case .dittoFailed(let arguments, let status, let message):
            "ditto \(arguments.joined(separator: " ")) exited \(status): \(message)"
        case .renameFailed(let from, let to, let errno):
            "cannot move \(from.path) to \(to.path): \(String(cString: strerror(errno)))"
        case .incomplete(let folder, let faults):
            "\(folder.path) came up short after the install: \(faults.map(\.description).joined(separator: "; "))"
        }
    }
}
