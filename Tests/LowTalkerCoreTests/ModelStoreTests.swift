import Foundation
import LowTalkerCore
import TestProbes
import Testing

/// What "installed" means, exercised on a scratch directory with small files in
/// place of model weights. Writing a store is `ModelInstallTests`, over the module
/// that does it.
@Suite struct ModelStoreTests {
    @Test func recordingListsEveryFileWithItsSizeInPathOrder() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        #expect(manifest.folder == "models/argmaxinc/whisperkit-coreml/openai_whisper-test")
        #expect(manifest.files == [
            .init(path: "AudioEncoder.mlmodelc/model.mil", size: 7),
            .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", size: 10),
            .init(path: "config.json", size: 2),
        ])
    }

    /// The hub client's sidecars sit inside a tokenizer's folder; they describe a
    /// download, not the model, and a manifest listing them would travel into every
    /// archive packed from it.
    @Test func recordingLeavesOutHiddenFiles() throws {
        let scratch = try ScratchStore(files: ["tokenizer.json": "{}", ".cache/huggingface/download/tokenizer.json.metadata": "etag"])
        #expect(try Manifest(recording: scratch.folder, relativeTo: scratch.root).files == [.init(path: "tokenizer.json", size: 2)])
    }

    @Test func recordingRefusesAFolderOutsideTheRoot() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        #expect(throws: ManifestError.self) {
            try Manifest(recording: scratch.folder, relativeTo: FileManager.default.temporaryDirectory.appending(path: "elsewhere"))
        }
    }

    /// A walk that stops early must not become a manifest of the files seen so far.
    @Test func recordingAFolderThatDoesNotExistThrows() throws {
        let scratch = try ScratchStore(files: [:])
        #expect(throws: ManifestError.self) {
            try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        }
    }

    @Test func recordingAnEmptyFolderThrows() throws {
        let scratch = try ScratchStore(files: [:])
        try FileManager.default.createDirectory(at: scratch.folder, withIntermediateDirectories: true)
        #expect(throws: ManifestError.noFiles(folder: "models/argmaxinc/whisperkit-coreml/openai_whisper-test")) {
            try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        }
    }

    @Test func manifestSurvivesTheRoundTripToDisk() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try manifest.write(to: scratch.manifestURL)
        #expect(try Manifest(contentsOf: scratch.manifestURL) == manifest)
    }

    @Test func untouchedFolderHasNoFaults() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        #expect(try manifest.faults(in: scratch.folder).isEmpty)
    }

    /// Extra files are not damage: the hub adds sidecars of its own.
    @Test func extraFilesAreNotFaults() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "sidecar".write(to: scratch.folder.appending(path: "extra.metadata"), atomically: true, encoding: .utf8)
        #expect(try manifest.faults(in: scratch.folder).isEmpty)
    }

    @Test func missingFileIsAFault() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))
        #expect(try manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .missing)])
    }

    /// A download that stopped mid-file leaves a short file behind; the size is the
    /// tell.
    @Test func truncatedFileIsAFault() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        try "0123".write(to: scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"), atomically: true, encoding: .utf8)
        #expect(try manifest.faults(in: scratch.folder) == [.init(path: "AudioEncoder.mlmodelc/weights/weight.bin", kind: .wrongSize(expected: 10, actual: 4))])
    }

    /// A folder standing where a file belongs is its own kind of fault, not a size:
    /// a 0-byte file is a legitimate recording, so no size may stand in for "none".
    @Test func folderInAFilesPlaceIsAFault() throws {
        let scratch = try ScratchStore(files: ScratchStore.files.merging(["empty.txt": ""]) { _, new in new })
        let store = ModelStore(directory: scratch.root)
        try scratch.record()
        let empty = scratch.folder.appending(path: "empty.txt")
        try FileManager.default.removeItem(at: empty)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let presence = try store.presence(of: "test")
        guard case .damaged(let damages) = presence, case .files(_, let faults) = damages.first, damages.count == 1 else {
            Issue.record("a folder in a listed file's place must count as damaged")
            return
        }
        #expect(faults == [.init(path: "empty.txt", kind: .notAFile)])
    }

    /// The menu bar and the log both show the phase's own words, so the words are
    /// pinned once, here.
    @Test func phasesDescribeThemselves() {
        #expect("\(LoadPhase.loading)" == "loading model, minutes the first time on this Mac")
    }

    /// A file this process may not reach is not a missing file: a download would
    /// not repair it, so the trouble is reported as itself.
    @Test func unreachableFileIsAnErrorNotAFault() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let manifest = try Manifest(recording: scratch.folder, relativeTo: scratch.root)
        let weights = scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: weights.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: weights.path) }
        #expect(throws: CocoaError.self) {
            try manifest.faults(in: scratch.folder)
        }
    }

    @Test func storeWithoutAManifestIsMissing() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        guard case .missing = try ModelStore(directory: scratch.root).presence(of: "test") else {
            Issue.record("a folder without a manifest must not count as installed")
            return
        }
    }

    @Test func storeWithAManifestThatVerifiesIsInstalled() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let store = ModelStore(directory: scratch.root)
        try scratch.record()
        guard case .installed(let installed) = try store.presence(of: "test") else {
            Issue.record("a verified manifest must count as installed")
            return
        }
        #expect(installed.model == "test")
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
        #expect(installed.hub == scratch.root)
    }

    @Test func storeWithAManifestThatDoesNotVerifyIsDamaged() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let store = ModelStore(directory: scratch.root)
        try scratch.record()
        try FileManager.default.removeItem(at: scratch.folder.appending(path: "config.json"))
        let presence = try store.presence(of: "test")
        guard case .damaged(let damages) = presence, case .files(_, let faults) = damages.first, damages.count == 1 else {
            Issue.record("a manifest naming a missing file must count as damaged")
            return
        }
        #expect(faults == [.init(path: "config.json", kind: .missing)])
    }

    /// A folder this process may not search is not damage a download would repair,
    /// so the store passes the trouble up instead of folding it into `.damaged`.
    @Test func storeThatCannotBeSearchedThrowsRatherThanReadingDamaged() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let store = ModelStore(directory: scratch.root)
        try scratch.record()
        let weights = scratch.folder.appending(path: "AudioEncoder.mlmodelc/weights")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: weights.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: weights.path) }
        #expect(throws: CocoaError.self) {
            try store.presence(of: "test")
        }
    }

    @Test func storeWithAnUnreadableManifestIsDamaged() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let url = try scratch.writeManifest("not json")
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(let damages) = presence, case .manifestUnreadable(let manifest, .weights, _) = damages.first else {
            Issue.record("a corrupt manifest must count as damaged, not missing")
            return
        }
        #expect(manifest == url)
    }

    /// A manifest this process may not read is not a corrupt one: telling the user
    /// to delete the model would be the wrong instruction, so the trouble is passed up.
    @Test func storeWhoseManifestCannotBeReadThrowsRatherThanReadingDamaged() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let store = ModelStore(directory: scratch.root)
        try scratch.record()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: scratch.manifestURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.manifestURL.path) }
        #expect(throws: CocoaError.self) {
            try store.presence(of: "test")
        }
    }

    /// The manifest is the only path the store follows blindly, so a manifest that
    /// points outside the store is refused as unreadable rather than followed.
    @Test func manifestPointingOutsideTheStoreIsRefused() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let url = try scratch.writeManifest(#"{"folder": "../../etc", "files": [{"path": "passwd", "size": 1}]}"#)
        #expect(throws: ManifestError.pathEscapes("../../etc")) {
            try Manifest(contentsOf: url)
        }
        guard case .damaged(let damages) = try ModelStore(directory: scratch.root).presence(of: "test"), case .manifestUnreadable = damages.first else {
            Issue.record("a manifest that escapes the store must count as damaged")
            return
        }
    }

    /// A manifest listing nothing would verify against any folder at all.
    @Test func manifestWithNoFilesIsRefused() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        let url = try scratch.writeManifest(#"{"folder": "models/x", "files": []}"#)
        #expect(throws: ManifestError.noFiles(folder: "models/x")) {
            try Manifest(contentsOf: url)
        }
    }

    @Test(arguments: ["a/b", "..", ".", "", "/x"])
    func modelNameRefusesAnythingButOnePathStep(raw: String) {
        #expect(Model(rawValue: raw) == nil)
    }

    @Test func modelNameAcceptsAFolderName() {
        #expect(Model(rawValue: "base.en")?.rawValue == "base.en")
    }

    /// A whole store loads read-only, in place. A release's carried store sits inside a
    /// signed, read-only bundle, so `installedModel` confirms it and returns without a
    /// lock or a write. The store here is made unwritable, down to the `installed` folder
    /// a lock file would need, so any write would throw; returning the model proves none
    /// is attempted. [LAW:parse-dont-validate]
    @Test func installedModelOnAWholeReadOnlyStoreReturnsWithoutWriting() throws {
        // 0o555 stops writes for a non-root user only; root ignores the mode bits and would
        // pass this test vacuously, hiding a regression that began writing under the lock.
        // [LAW:no-silent-failure] the precondition fails loudly rather than proving nothing.
        try #require(geteuid() != 0, "run as a non-root user; 0o555 does not stop root")
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        let installedFolder = scratch.root.appending(path: "installed")
        let setMode: (Int, URL) throws -> Void = { mode, url in
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try setMode(0o555, installedFolder)
        try setMode(0o555, scratch.root)
        defer {
            // Restore write so `ScratchStore`'s deinit can delete the tree.
            try? setMode(0o755, scratch.root)
            try? setMode(0o755, installedFolder)
        }
        let installed = try ModelStore(directory: scratch.root).installedModel("test")
        #expect(installed.folder.standardizedFileURL == scratch.folder.standardizedFileURL)
    }

    /// A store that does not hold the model whole fails with the part-level reason, not a
    /// lock or permission error: `installedModel` never tries to write it, so a read-only
    /// carried store that is somehow incomplete says why rather than "read-only file
    /// system". [LAW:no-silent-failure]
    @Test func installedModelOnAStoreLackingTheModelFailsWithTheReason() throws {
        let scratch = try ScratchStore(files: [:], tokenizer: [:])
        do {
            _ = try ModelStore(directory: scratch.root).installedModel("test")
            Issue.record("a store that lacks the model must fail")
        } catch let error as ModelStoreError {
            #expect("\(error)".contains("does not hold") && "\(error)".contains("not installed"))
        }
    }

    /// A store written before the tokenizer had a manifest has whole weights and no
    /// record of the tokenizer: it is not installed.
    @Test func storeWithWeightsButNoTokenizerManifestIsDamaged() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try Manifest(recording: scratch.folder, relativeTo: scratch.root).write(to: scratch.manifestURL)
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(let damages) = presence, case .unrecorded(.tokenizer) = damages.first, damages.count == 1 else {
            Issue.record("weights without a tokenizer must not count as installed")
            return
        }
        #expect("\(damages[0])" == "the tokenizer is not installed")
    }

    /// Both parts are judged, so a damaged tokenizer is reported beside damaged weights.
    @Test func damageInBothPartsIsReportedTogether() throws {
        let scratch = try ScratchStore(files: ScratchStore.files)
        try scratch.record()
        try "{".write(to: scratch.folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try "{".write(to: scratch.tokenizer.appending(path: "tokenizer.json"), atomically: true, encoding: .utf8)
        let presence = try ModelStore(directory: scratch.root).presence(of: "test")
        guard case .damaged(let damages) = presence, damages.count == 2 else {
            Issue.record("damage in both parts must be reported as two damages")
            return
        }
        #expect(damages.map(\.description) == ["config.json is 1 bytes, expected 2", "tokenizer.json is 1 bytes, expected 13"])
    }

    /// A Parakeet model is its weights alone, its vocabulary beside them: one manifest makes it
    /// installed, by the same rule a Whisper model's two make it so, and its folder is the repo.
    @Test func aParakeetModelIsInstalledByItsWeightsAlone() throws {
        let scratch = try ScratchStore(files: [:])
        let store = ModelStore(directory: scratch.root)
        let parakeet = Model.parakeet(.tdtV3)
        guard case .missing = try store.presence(of: parakeet) else {
            Issue.record("a store with no Parakeet manifest must not hold Parakeet")
            return
        }
        let folder = try scratch.installParakeet(files: [ParakeetModel.vocabulary: "{}"])
        // The layout every install already on disk was written in, spelled out here alone.
        #expect(folder.path(percentEncoded: false).hasSuffix("/models/FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        #expect(FileManager.default.fileExists(atPath: scratch.root.appending(components: "installed", "parakeet-tdt-0.6b-v3.json").path(percentEncoded: false)))
        let vocabulary = folder.appending(path: ParakeetModel.vocabulary)
        #expect(try store.installedModel(parakeet).folder.standardizedFileURL == folder.standardizedFileURL)
        try FileManager.default.removeItem(at: vocabulary)
        guard case .damaged(let damages) = try store.presence(of: parakeet) else {
            Issue.record("a Parakeet model missing a file must be damaged")
            return
        }
        #expect(damages.map(\.description) == ["parakeet_v3_vocab.json is missing"])
    }
}
