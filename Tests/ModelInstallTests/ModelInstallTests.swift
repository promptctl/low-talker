import Foundation
import LowTalkerCore
@testable import ModelInstall
import Synchronization
import TestProbes
import Testing

/// What an install writes, exercised on a scratch directory with small files in place
/// of model weights. The download itself needs the network and 632 MB, so it is
/// exercised by `model-tool download` on a Mac, not here; what a whole store reads
/// as is `ModelStoreTests`, in the core.
@Suite struct ModelInstallTests {
    /// An installed model is found before any source is opened, so a published base
    /// that cannot be reached costs nothing when there is nothing to take from it.
    @Test func installOnAnInstalledStoreNeverOpensAPublishedSource() async throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await ModelStore(directory: scratch.root).install("test", from: .published(URL(string: "http://127.0.0.1:9/")!)) { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(phases.withLock { $0 }.isEmpty)
    }

    /// The terminal shows a phase's own words, so the words are pinned once, here; the
    /// load's own words are the core's, and the road repeats them rather than keeping a
    /// second copy.
    @Test func phasesDescribeThemselves() {
        #expect("\(LoadedEngine.InstallingLoadPhase.installing(.waitingForAnotherInstall))" == "waiting for another install")
        #expect("\(LoadedEngine.InstallingLoadPhase.installing(.downloading(fractionCompleted: 0.426)))" == "downloading 42%")
        #expect("\(LoadedEngine.InstallingLoadPhase.installing(.unpacking))" == "unpacking model")
        #expect("\(LoadedEngine.InstallingLoadPhase.installing(.copying))" == "copying model")
        #expect("\(LoadedEngine.InstallingLoadPhase.installing(.evicting(["a.bin"])))" == "removing 1 damaged file: a.bin")
        #expect("\(LoadedEngine.InstallingLoadPhase.loading)" == "\(LoadPhase.loading)")
    }

    /// An unreadable manifest names no files, so the part is taken whole from the
    /// source and recorded with the source's manifest.
    @Test func installRepairsAPartWhoseManifestIsUnreadable() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try source.record()
        let destination = try ScratchStore(files: ScratchStore.files)
        try destination.record()
        try "not json".write(to: destination.tokenizerManifestURL, atomically: true, encoding: .utf8)
        let store = ModelStore(directory: destination.root)
        _ = try await store.install("test", from: .store(ModelStore(directory: source.root))) { _ in }
        guard case .installed = try store.presence(of: "test") else {
            Issue.record("a part with an unreadable manifest must be repaired from the source")
            return
        }
        #expect(try Manifest(contentsOf: destination.tokenizerManifestURL) == Manifest(contentsOf: source.tokenizerManifestURL))
    }

    /// A Parakeet model is copied as its weights alone, under the one manifest that proves it
    /// whole, and a revision of WhisperKit's shape is refused for it before anything is fetched.
    @Test func aParakeetModelIsInstalledAsItsWeightsAlone() async throws {
        let source = try ScratchStore(files: [:])
        let folder = source.root.appending(components: "models", "FluidInference", "parakeet-tdt-0.6b-v3-coreml")
        for path in [ParakeetModel.vocabulary, "\(ParakeetModel.joint)/model.mil"] {
            try FileManager.default.createDirectory(at: folder.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try "parakeet".write(to: folder.appending(path: path), atomically: true, encoding: .utf8)
        }
        try Manifest(recording: folder, relativeTo: source.root).write(to: source.root.appending(components: "installed", "parakeet-tdt-0.6b-v3.json"))
        let destination = try ScratchStore(files: [:])
        let store = ModelStore(directory: destination.root)
        let installed = try await store.install(.parakeet(.tdtV3), from: .store(ModelStore(directory: source.root))) { _ in }
        #expect(installed.folder.path.hasSuffix("models/FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        #expect(!FileManager.default.fileExists(atPath: destination.root.appending(components: "installed", "tokenizer", "parakeet-tdt-0.6b-v3.json").path))

        let empty = try ScratchStore(files: [:])
        let whisperShaped = try #require(ModelRevisions("parakeet-tdt-0.6b-v3@\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))"))
        await #expect(throws: ModelInstallError.revisionNotFor(model: .parakeet(.tdtV3), revision: whisperShaped.revisions[.parakeet(.tdtV3)]!)) {
            try await ModelStore(directory: empty.root).install(.parakeet(.tdtV3), from: .huggingFace(whisperShaped)) { _ in }
        }
    }

    /// A Whisper model at a revision naming its weights alone is refused before anything is
    /// fetched: the store is left with no manifest, and no request reaches the hub.
    @Test func aWhisperRevisionWithNoTokenizerIsRefusedBeforeAnyFetch() async throws {
        let empty = try ScratchStore(files: [:])
        let parakeetShaped = try #require(ModelRevisions("\(Model.default)@\(String(repeating: "a", count: 40))"))
        await #expect(throws: ModelInstallError.revisionNotFor(model: .default, revision: parakeetShaped.revisions[.default]!)) {
            try await ModelStore(directory: empty.root).install(.default, from: .huggingFace(parakeetShaped)) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: empty.root.appending(components: "installed", "\(Model.default).json").path))
    }

    /// A folder standing where a listed file belongs is removed before the copy, so
    /// the copy can be renamed into its place and the store is repaired.
    @Test func installFromAStoreReplacesAFolderInAFilesPlace() async throws {
        let files = ScratchStore.files.merging(["empty.txt": ""]) { _, new in new }
        let source = try ScratchStore(files: files)
        try source.record()
        let destination = try ScratchStore(files: files)
        try destination.record()
        let empty = destination.folder.appending(path: "empty.txt")
        try FileManager.default.removeItem(at: empty)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let store = ModelStore(directory: destination.root)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        _ = try await store.install("test", from: .store(ModelStore(directory: source.root))) { phase in phases.withLock { $0.append(phase) } }
        guard case .installed = try store.presence(of: "test") else {
            Issue.record("a folder in a listed file's place must be repaired from the source")
            return
        }
        #expect(phases.withLock { $0 } == [.evicting(["empty.txt"]), .copying])
    }

    /// Two `model-tool download`s share one store: the second installer waits for the
    /// first, then finds its work already done.
    @Test(.timeLimit(.minutes(1))) func installWaitsForAnotherInstallerAndTakesItsResult() async throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        let lock = scratch.root.appending(components: "installed", ".lock")
        let descriptor = open(lock.path, O_RDONLY | O_CREAT, 0o644)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX) == 0)

        // [LAW:no-ambient-temporal-coupling] The install reports its phases into the
        // stream and finishes it when it returns, so the test advances on what the
        // install says, and an install that never reports the wait ends the stream.
        let (phases, report) = AsyncStream.makeStream(of: ModelStore.InstallPhase.self)
        let store = ModelStore(directory: scratch.root)
        let installing = Task {
            defer { report.finish() }
            return try await store.install("test", from: .huggingFace(nil)) { report.yield($0) }
        }
        var reported = phases.makeAsyncIterator()
        try #require(await reported.next() == .waitingForAnotherInstall, "the second installer reports the wait before anything else")
        try #require(flock(descriptor, LOCK_UN) == 0)

        let installed = try await installing.value
        #expect(installed.model == "test")
        #expect(await reported.next() == nil, "an installed model is taken as found, with no download")
    }

    /// An installed model costs nothing to install again.
    @Test func installOnAnInstalledStoreReturnsItWithoutDownloading() async throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await ModelStore(directory: scratch.root).install("test", from: .huggingFace(nil)) { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(phases.withLock { $0 }.isEmpty)
    }

    /// Another store is a source: both parts arrive at the same paths with their
    /// manifests, and a sidecar beside the files in the source stays behind.
    @Test func installFromAStoreCopiesBothPartsAndTheirManifests() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try source.record()
        try "sidecar".write(to: source.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        let destination = try ScratchStore(files: [:], tokenizer: [:])
        let store = ModelStore(directory: destination.root)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let installed = try await store.install("test", from: .store(ModelStore(directory: source.root))) { phase in phases.withLock { $0.append(phase) } }
        #expect(installed.folder.standardizedFileURL == destination.folder.standardizedFileURL)
        guard case .installed = try store.presence(of: "test") else {
            Issue.record("a copied model must read as installed")
            return
        }
        #expect(try Manifest(contentsOf: destination.manifestURL) == Manifest(contentsOf: source.manifestURL))
        #expect(try Manifest(contentsOf: destination.tokenizerManifestURL) == Manifest(contentsOf: source.tokenizerManifestURL))
        #expect(!FileManager.default.fileExists(atPath: destination.folder.appending(path: "extra.metadata").path))
        #expect(phases.withLock { $0 } == [.copying, .copying])
    }

    /// A repair from a store replaces only what the destination lacks: a whole part
    /// is not copied again.
    @Test func installFromAStoreRepairsOnlyTheDamagedPart() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try source.record()
        let destination = try ScratchStore(files: ScratchStore.files)
        try destination.record()
        try "0123".write(to: destination.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        let phases = Mutex<[ModelStore.InstallPhase]>([])
        let store = ModelStore(directory: destination.root)
        _ = try await store.install("test", from: .store(ModelStore(directory: source.root))) { phase in phases.withLock { $0.append(phase) } }
        #expect(try Data(contentsOf: destination.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin")) == Data("0123456789".utf8))
        #expect(phases.withLock { $0 } == [.evicting(["AudioEncoder.mlmodelc/weights/weight.bin"]), .copying])
    }

    /// A source that does not hold the model whole has nothing to give, and says
    /// which part and why rather than copying what it has.
    @Test func installFromAStoreWithoutTheTokenizerIsRefused() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try Manifest(recording: source.folder, relativeTo: source.root).write(to: source.manifestURL)
        let destination = try ScratchStore(files: [:], tokenizer: [:])
        await #expect(throws: ModelInstallError.sourceLacks(source: source.root, model: "test", part: .tokenizer, reason: "not installed there")) {
            try await ModelStore(directory: destination.root).install("test", from: .store(ModelStore(directory: source.root))) { _ in }
        }
    }

    /// An install cancelled before its unpack starts is told so, and launches no `ditto`:
    /// stopping one never launched would raise rather than throw.
    @Test func anUnpackCancelledBeforeItStartsThrowsCancellation() async throws {
        let out = try ScratchStore(files: [:], tokenizer: [:])
        let unpacked = out.root.appending(path: "unpacked")
        let unpacking = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await Archive.unpack(out.root.appending(path: "absent.zip"), into: unpacked)
        }
        await #expect(throws: CancellationError.self) { try await unpacking.value }
        #expect(!FileManager.default.fileExists(atPath: unpacked.path))
    }

    /// The archive a published base serves unpacks into a store that holds the model
    /// installed, and holds nothing the source's manifests do not list.
    @Test func packedArchiveUnpacksIntoAStoreHoldingTheModel() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try source.record()
        try "sidecar".write(to: source.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        let out = try ScratchStore(files: [:], tokenizer: [:])
        let archive = try await ModelStore(directory: source.root).pack("test", into: out.root) { _ in }
        #expect(archive.lastPathComponent == "test.zip")
        let unpacked = out.root.appending(path: "unpacked")
        try await Archive.unpack(archive, into: unpacked)
        guard case .installed = try ModelStore(directory: unpacked).presence(of: "test") else {
            Issue.record("a packed archive must unpack into an installed store")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: unpacked.appending(components: "models", "argmaxinc", "whisperkit-coreml", "openai_whisper-test", "extra.metadata").path))
    }

    /// A copy that fails part way leaves no hidden partial file behind, since nothing
    /// records or evicts a hidden name and every retry would add another.
    @Test func failedCopyLeavesNoPartialFile() async throws {
        let source = try ScratchStore(files: ScratchStore.files)
        try source.record()
        let unreadable = source.folder.appending(path: "config.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let destination = try ScratchStore(files: [:], tokenizer: [:])
        await #expect(throws: (any Error).self) {
            try await ModelStore(directory: destination.root).install("test", from: .store(ModelStore(directory: source.root))) { _ in }
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.folder.path)
        #expect(!left.contains { $0.hasPrefix(".config.json.") })
    }
}
