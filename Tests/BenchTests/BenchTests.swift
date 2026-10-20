import ArgumentParser
import Bench
import Foundation
import LowTalkerCore
import Synchronization
import TestProbes
import Testing

/// An engine that hears every clip as the same words, after its gate opens, and keeps what
/// it was told to expect.
private final class ScriptedEar: Transcriber {
    let gate: Gate
    let expected = Mutex<[Vocabulary]>([])

    init(gate: Gate = { let gate = Gate(); gate.open(); return gate }()) {
        self.gate = gate
    }

    func transcribe(
        _ audio: some AsyncSequence<AudioClip, Never> & Sendable,
        expecting vocabulary: Vocabulary,
        partial: @escaping @Sendable (Partial) -> Void
    ) async throws(TranscriptionFailure) -> Transcription {
        expected.withLock { $0.append(vocabulary) }
        for await _ in audio {}
        await gate.wait()
        guard !Task.isCancelled else { throw .cancelled }
        return Transcription(transcript: Transcript(typed: "hello world"), quiet: Quiet(letGo: 0, room: nil, refusedAsRoom: 0, transients: .none, range: nil, keptOut: nil, keptOutFrames: 0))
    }
}

/// Folders on disk for a run: fixtures, a store, and the bookmarks a pick would have left.
private final class Picked: Sendable {
    let root: URL
    let fixtures: URL
    let store: URL
    let folders: BenchFolders

    init(fixtures names: [String], models: [ModelName] = []) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "BenchTests-\(UUID().uuidString)")
        fixtures = root.appending(path: "fixtures")
        store = root.appending(path: "store")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.appending(path: "installed"), withIntermediateDirectories: true)
        let tone = AudioClip(samples: (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })
        for name in names {
            try tone.write(to: fixtures.appending(path: "\(name).wav"))
            try "hello world".write(to: fixtures.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
        }
        for model in models {
            try Data("{}".utf8).write(to: store.appending(components: "installed", "\(model.rawValue).json"))
        }
        folders = BenchFolders(defaults: UserDefaults(suiteName: "BenchTests-\(UUID().uuidString)")!)
    }

    func remembered() throws -> Picked {
        try folders.remember(fixtures)
        try folders.remember(store)
        return self
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct BenchTests {
    /// Every option the window and the flags carry reaches the harness: each model loads from
    /// the picked store, each fixture is held every delivery and serving asked, `runs` times,
    /// expecting the vocabulary.
    @Test func everyOptionReachesTheHarness() async throws {
        let picked = try Picked(fixtures: ["a", "b"]).remembered()
        let ear = ScriptedEar()
        let vocabulary = Vocabulary([try Vocabulary.Term("Kubernetes")])
        let plan = try BenchPlan(models: ["one", "two"], arrivals: [.batch, .streamed], servings: [.idle], runs: 2, vocabulary: vocabulary)
        let loads = Mutex<[String]>([])
        let rows = Mutex<[BenchRow]>([])
        try await Bench.run(
            BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan),
            folders: picked.folders, carried: nil,
            load: { store, model in
                loads.withLock { $0.append("\(store.directory.lastPathComponent)/\(model)") }
                return LatencyHarness.Engine(dictation: ear, served: ear, turns: EngineTurns())
            },
            emit: { if case .row(let row) = $0 { rows.withLock { $0.append(row) } } })
        #expect(loads.withLock { $0 } == ["store/one", "store/two"])
        let table = rows.withLock { $0 }.map { Dictionary(uniqueKeysWithValues: $0.cells.map { ($0.name, $0.value) }) }
        #expect(table.map { "\($0["model"]!) \($0["fixture"]!) \($0["delivery"]!) \($0["serving"]!)" } == [
            "one a batch idle", "one a streamed idle", "one b batch idle", "one b streamed idle",
            "two a batch idle", "two a streamed idle", "two b batch idle", "two b streamed idle",
        ])
        // Two models, two fixtures, two deliveries, two runs each.
        #expect(ear.expected.withLock { $0 } == Array(repeating: vocabulary, count: 16))
    }

    /// The carried store is the default, and a process carrying none says so rather than
    /// reading some other store.
    @Test func theCarriedStoreIsReadWhereItIs() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let ear = ScriptedEar()
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: .empty)
        let options = BenchOptions(fixtures: picked.fixtures, store: .carried, plan: plan)
        let carried = ModelStore(directory: URL(fileURLWithPath: "/carried"))
        let loaded = Mutex<URL?>(nil)
        try await Bench.run(options, folders: picked.folders, carried: carried, load: { store, _ in
            loaded.withLock { $0 = store.directory }
            return LatencyHarness.Engine(dictation: ear, served: ear, turns: EngineTurns())
        }, emit: { _ in })
        #expect(loaded.withLock { $0 } == carried.directory)
        await #expect(throws: CarriesNoStore.self) {
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in fatalError("no store to load from") }, emit: { _ in })
        }
    }

    /// A folder no open panel handed over is refused by its path, with where to pick it.
    @Test func anUnpickedFolderIsRefusedByName() async throws {
        let picked = try Picked(fixtures: ["a"])
        try picked.folders.remember(picked.store)
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: .empty)
        let refusal = await #expect(throws: FolderNotPicked.self) {
            try await Bench.run(BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan), folders: picked.folders, carried: nil, load: { _, _ in fatalError("refused before any load") }, emit: { _ in })
        }
        let path = picked.fixtures.resolvingSymlinksInPath().path(percentEncoded: false).replacing(/\/$/, with: "")
        #expect(refusal?.path == path)
        #expect("\(refusal!)".contains(path))
        #expect("\(refusal!)".contains("Benchmark window"))
    }

    /// A folder picked in a panel, whose URL ends in a slash, opens from a path typed without
    /// one, and from one with a `..` in it.
    @Test func aPickedFolderOpensHoweverItsPathIsSpelled() throws {
        let picked = try Picked(fixtures: ["a"])
        try picked.folders.remember(URL(fileURLWithPath: picked.fixtures.path(percentEncoded: false) + "/", isDirectory: true))
        let typed = picked.fixtures.path(percentEncoded: false)
        #expect(try picked.folders.open(URL(filePath: typed, directoryHint: .notDirectory)).url.lastPathComponent == "fixtures")
        #expect(try picked.folders.open(URL(fileURLWithPath: typed + "/../fixtures")).url.lastPathComponent == "fixtures")
    }

    /// A run logs one event as it starts, one per model it loads, one per row and one as it
    /// ends, and hands the surface each event it logs.
    @Test func eachRowIsOneLogEvent() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let ear = ScriptedEar()
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch, .streamed], servings: [.idle], runs: 1, vocabulary: .empty)
        let lines = Mutex<[String]>([])
        let runs = await BenchRuns(turns: EngineTurns()) { line in lines.withLock { $0.append(line) } }
        let seen = Mutex<[BenchEvent]>([])
        let ending = Mutex<BenchEnding?>(nil)
        let options = BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan)
        let run = try await runs.start("over a", work: { emit in
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in
                LatencyHarness.Engine(dictation: ear, served: ear, turns: EngineTurns())
            }, emit: emit)
        }, events: { event in seen.withLock { $0.append(event) } }, ended: { end in ending.withLock { $0 = end } })
        await run.value
        let rows = seen.withLock { $0 }.compactMap { if case .row(let row) = $0 { row } else { nil } }
        #expect(rows.count == 2)
        #expect(lines.withLock { $0 } == ["bench: started over a", "bench: loading one"] + rows.map { "bench row: \($0.fields)" } + ["bench: finished, 2 rows; 0 served preempted, 0 served waiting"])
        #expect(rows[0].fields.hasPrefix("model=one fixture=a delivery=batch serving=idle audio_s=0.100 "))
        #expect(ending.withLock { $0 } == .finished)
    }

    /// A cancelled run stops where it is held, says so, and lets dictation back in; while it
    /// runs, a press is refused with the reason, and so is a second run.
    @Test func cancellingEndsTheRunAndPressesAreRefusedUntilThen() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let ear = ScriptedEar(gate: Gate())
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 3, vocabulary: .empty)
        let lines = Mutex<[String]>([])
        let runs = await BenchRuns(turns: EngineTurns()) { line in lines.withLock { $0.append(line) } }
        let ending = Mutex<BenchEnding?>(nil)
        let options = BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan)
        let run = try await runs.start("over a", work: { emit in
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in
                LatencyHarness.Engine(dictation: ear, served: ear, turns: EngineTurns())
            }, emit: emit)
        }, events: { _ in }, ended: { end in ending.withLock { $0 = end } })
        while ear.gate.waiting == 0 { await Task.yield() }

        await #expect(throws: BenchmarkRunning()) { try await runs.admitPress() }
        #expect("\(BenchmarkRunning())".hasPrefix("a benchmark is running"))
        await #expect(throws: RunRefused.benchmarkRunning) {
            try await runs.start("again", work: { _ in }, events: { _ in }, ended: { _ in })
        }

        await runs.cancel()
        await run.value
        #expect(ending.withLock { $0 } == .cancelled)
        #expect(lines.withLock { $0 }.last == "bench: cancelled after 0 rows; 0 served preempted, 0 served waiting")
        try await runs.admitPress()
        #expect(await !runs.isRunning)
    }

    /// A run takes the process's turns as a press does, so a served request waits it out, and
    /// is refused while a press already holds them.
    @Test func aRunHoldsTheEngineAndWaitsForNoPress() async throws {
        let turns = EngineTurns()
        let runs = await BenchRuns(turns: turns) { _ in }
        let press = turns.hold()
        await #expect(throws: RunRefused.dictationHeld) {
            try await runs.start("held", work: { _ in }, events: { _ in }, ended: { _ in })
        }
        #expect(await !runs.isRunning)
        press.release()

        let gate = Gate()
        let run = try await runs.start("holding", work: { _ in await gate.wait(); try Task.checkCancellation() }, events: { _ in }, ended: { _ in })
        while gate.waiting == 0 { await Task.yield() }
        #expect(turns.reading.holds == 1)
        await runs.cancel()
        await run.value
        #expect(turns.reading.holds == 0)
    }

    /// The flags and the window build one value: each flag lands where the window's control
    /// puts it, and what a flag leaves out is what the window starts with.
    @Test func theFlagsParseIntoTheWindowsOptions() throws {
        let options = try BenchFlags.options([
            "/bench/say", "--model", "one", "--model", "two", "--delivery", "streamed", "--serving", "idle", "--serving", "served",
            "--runs", "5", "--models-dir", "/stores/hub", "--vocabulary", "Kubernetes", "--vocabulary", "LowTalker",
        ])
        #expect(options == BenchOptions(
            fixtures: URL(fileURLWithPath: "/bench/say"),
            store: .folder(URL(fileURLWithPath: "/stores/hub")),
            plan: try BenchPlan(models: ["one", "two"], arrivals: [.streamed], servings: [.idle, .served], runs: 5,
                                vocabulary: Vocabulary([try Vocabulary.Term("Kubernetes"), try Vocabulary.Term("LowTalker")]))))
        #expect(try BenchFlags.options(["/bench/say"]) == BenchOptions(
            fixtures: URL(fileURLWithPath: "/bench/say"), store: .carried,
            plan: try BenchPlan(models: [.default], arrivals: [.batch, .streamed], servings: [.idle], runs: 3, vocabulary: .empty)))
        #expect(throws: (any Error).self) { try BenchFlags.options(["/bench/say", "--runs", "0"]) }
        #expect(throws: (any Error).self) { try BenchFlags.options(["/bench/say", "--delivery", "carrier-pigeon"]) }
    }

    /// A plan measures something, or is not made.
    @Test func anEmptyChoiceIsRefused() {
        #expect(throws: BenchOptionsError.nothingChosen("model")) { try BenchPlan(models: [], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: .empty) }
        #expect(throws: BenchOptionsError.nothingChosen("delivery")) { try BenchPlan(models: ["one"], arrivals: [], servings: [.idle], runs: 1, vocabulary: .empty) }
        #expect(throws: BenchOptionsError.nothingChosen("serving")) { try BenchPlan(models: ["one"], arrivals: [.batch], servings: [], runs: 1, vocabulary: .empty) }
        #expect(throws: BenchOptionsError.tooFewRuns(0)) { try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 0, vocabulary: .empty) }
    }

    /// The window offers the models a store has recorded, by name and in order.
    @Test func aStoreListsTheModelsItRecorded() throws {
        let picked = try Picked(fixtures: [], models: ["zeta", "alpha"])
        #expect(try ModelStore(directory: picked.store).recordedModels() == ["alpha", "zeta"])
        #expect(throws: (any Error).self) { try ModelStore(directory: picked.fixtures).recordedModels() }
    }
}
