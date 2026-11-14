import ArgumentParser
import Bench
import Foundation
import LowTalkerCore
import LowTalkerCoreFakes
import Synchronization
import TestProbes
import Testing

/// The one fake engine, hearing every clip as the same words, once `gate` opens if one is given.
private func scriptedEar(after gate: Gate? = nil) -> FakeTranscriber {
    FakeTranscriber { _ in
        await gate?.wait()
        return Transcript(typed: "hello world")
    }
}

/// Folders on disk for a run: fixtures, a store, and the bookmarks a pick would have left.
private final class Picked: Sendable {
    let root: URL
    let fixtures: URL
    let store: URL
    let folders: BenchFolders

    init(fixtures names: [String], models: [Model] = []) throws {
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
        let ear = scriptedEar()
        let vocabulary = Vocabulary([try Vocabulary.Term("Kubernetes")])
        let plan = try BenchPlan(models: ["one", "two"], arrivals: [.batch, .streamed], servings: [.idle], runs: 2, vocabulary: vocabulary)
        let loads = Mutex<[String]>([])
        let rows = Mutex<[BenchRow]>([])
        try await Bench.run(
            BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan),
            folders: picked.folders, carried: nil,
            load: { store, model in
                loads.withLock { $0.append("\(store.directory.lastPathComponent)/\(model)") }
                return LatencyHarness.Engine(ear)
            },
            emit: { if case .row(let row) = $0 { rows.withLock { $0.append(row) } } })
        #expect(loads.withLock { $0 } == ["store/one", "store/two"])
        let table = rows.withLock { $0 }.map { Dictionary(uniqueKeysWithValues: $0.cells.map { ($0.name, $0.value) }) }
        #expect(table.map { "\($0["model"]!) \($0["fixture"]!) \($0["delivery"]!) \($0["serving"]!)" } == [
            "one a batch idle", "one a streamed idle", "one b batch idle", "one b streamed idle",
            "two a batch idle", "two a streamed idle", "two b batch idle", "two b streamed idle",
        ])
        // Two models, two fixtures, two deliveries, two runs each.
        #expect(ear.expected == Array(repeating: vocabulary, count: 16))
    }

    /// The carried store is the default, and a process carrying none says so rather than
    /// reading some other store.
    @Test func theCarriedStoreIsReadWhereItIs() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let ear = scriptedEar()
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: .empty)
        let options = BenchOptions(fixtures: picked.fixtures, store: .carried, plan: plan)
        let carried = ModelStore(directory: URL(fileURLWithPath: "/carried"))
        let loaded = Mutex<URL?>(nil)
        try await Bench.run(options, folders: picked.folders, carried: carried, load: { store, _ in
            loaded.withLock { $0 = store.directory }
            return LatencyHarness.Engine(ear)
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
        let ear = scriptedEar()
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch, .streamed], servings: [.idle], runs: 1, vocabulary: .empty)
        let lines = Mutex<[String]>([])
        let runs = await BenchRuns(turns: EngineTurns()) { line in lines.withLock { $0.append(line) } }
        let seen = Mutex<[BenchEvent]>([])
        let ending = Mutex<BenchEnding?>(nil)
        let options = BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan)
        let run = try await runs.start("over a", work: { emit in
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in
                LatencyHarness.Engine(ear)
            }, emit: emit)
        }, events: { event in seen.withLock { $0.append(event) } }, ended: { end in ending.withLock { $0 = end } })
        await run.value
        let rows = seen.withLock { $0 }.compactMap { if case .row(let row) = $0 { row } else { nil } }
        #expect(rows.count == 2)
        #expect(lines.withLock { $0 } == ["bench: started over a", "bench: loading one"] + rows.map { "bench row: \($0.fields)" } + ["bench: finished, 2 rows; 0 served preempted, 0 served waiting"])
        #expect(rows[0].fields.hasPrefix("model=one fixture=a delivery=batch serving=idle audio_s=0.100 "))
        #expect(ending.withLock { $0 } == .finished)
    }

    /// A cancelled run stops where it is held and says so; while it runs, a second run is
    /// refused.
    @Test func cancellingEndsTheRunAndASecondRunIsRefusedUntilThen() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let gate = Gate()
        let ear = scriptedEar(after: gate)
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 3, vocabulary: .empty)
        let lines = Mutex<[String]>([])
        let runs = await BenchRuns(turns: EngineTurns()) { line in lines.withLock { $0.append(line) } }
        let ending = Mutex<BenchEnding?>(nil)
        let options = BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan)
        let run = try await runs.start("over a", work: { emit in
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in
                LatencyHarness.Engine(ear)
            }, emit: emit)
        }, events: { _ in }, ended: { end in ending.withLock { $0 = end } })
        await gate.changed.settled { gate.waiting == 1 }

        await #expect(throws: RunRefused.benchmarkRunning) {
            try await runs.start("again", work: { _ in }, events: { _ in }, ended: { _ in })
        }

        await runs.cancel()
        await run.value
        #expect(ending.withLock { $0 } == .stopped(.cancelled))
        #expect(lines.withLock { $0 }.last == "bench: cancelled after 0 rows; 0 served preempted, 0 served waiting")
        #expect(await !runs.isRunning)
    }

    /// The first press heard during a run stops it, and the run's last line says a dictation
    /// stopped it.
    @Test func aPressHeardDuringARunStopsItAndItsLineSaysSo() async throws {
        let picked = try Picked(fixtures: ["a"]).remembered()
        let gate = Gate()
        let ear = scriptedEar(after: gate)
        let plan = try BenchPlan(models: ["one"], arrivals: [.batch], servings: [.idle], runs: 3, vocabulary: .empty)
        let lines = Mutex<[String]>([])
        let turns = EngineTurns()
        let runs = await BenchRuns(turns: turns) { line in lines.withLock { $0.append(line) } }
        let ending = Mutex<BenchEnding?>(nil)
        let options = BenchOptions(fixtures: picked.fixtures, store: .folder(picked.store), plan: plan)
        let run = try await runs.start("over a", work: { emit in
            try await Bench.run(options, folders: picked.folders, carried: nil, load: { _, _ in
                LatencyHarness.Engine(ear)
            }, emit: emit)
        }, events: { _ in }, ended: { end in ending.withLock { $0 = end } })
        await gate.changed.settled { gate.waiting == 1 }

        let press = turns.hold()
        _ = try await turns.decode(as: .dictation) { () throws(TranscriptionFailure) in "heard" }
        press.release()
        await run.value
        #expect(ending.withLock { $0 } == .stopped(.forPress))
        #expect(lines.withLock { $0 }.last == "bench: stopped for a dictation after 0 rows; 0 served preempted, 0 served waiting")
        #expect(await !runs.isRunning)
    }

    /// A run's own failure is what its ending says, whatever stopped it; with none, a press
    /// heard during it comes before the person's cancel.
    @Test func aRunsFailureIsSaidAheadOfThePressOrTheCancel() {
        #expect(BenchEnding(failure: "a weight file is truncated", yielded: true, cancelled: true) == .failed("a weight file is truncated"))
        #expect(BenchEnding(failure: nil, yielded: true, cancelled: true) == .stopped(.forPress))
        #expect(BenchEnding(failure: nil, yielded: false, cancelled: true) == .stopped(.cancelled))
        #expect(BenchEnding(failure: nil, yielded: false, cancelled: false) == .finished)
    }

    /// Work that finishes after a press was heard during it, before the stop reached it, still
    /// ends saying a dictation stopped it, since what it measured last was measured beside one.
    @Test func aRunWhoseWorkFinishesAfterAPressWasHeardSaysADictationStoppedIt() async throws {
        let lines = Mutex<[String]>([])
        let turns = EngineTurns()
        let runs = await BenchRuns(turns: turns) { line in lines.withLock { $0.append(line) } }
        let ending = Mutex<BenchEnding?>(nil)
        let run = try await runs.start("beside a press", work: { _ in
            let press = turns.hold()
            _ = try await turns.decode(as: .dictation) { () throws(TranscriptionFailure) in "heard" }
            press.release()
        }, events: { _ in }, ended: { end in ending.withLock { $0 = end } })
        await run.value
        #expect(ending.withLock { $0 } == .stopped(.forPress))
        #expect(lines.withLock { $0 }.last == "bench: stopped for a dictation after 0 rows; 0 served preempted, 0 served waiting")
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

    /// A vocabulary Parakeet cannot be told is refused before any model loads, and a Whisper
    /// model alone takes it.
    @Test func aVocabularyAModelRefusesIsRefusedBeforeAnyLoad() throws {
        let vocabulary = Vocabulary([try Vocabulary.Term("Kubernetes")])
        #expect(throws: BenchOptionsError.vocabulary(.engineTakesNone(.parakeet(.tdtV3)))) {
            try BenchPlan(models: [.default, .parakeet(.tdtV3)], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: vocabulary)
        }
        _ = try BenchPlan(models: [.default], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: vocabulary)
    }

    /// The window offers the models a store has recorded, by name and in order.
    @Test func aStoreListsTheModelsItRecorded() throws {
        let picked = try Picked(fixtures: [], models: ["zeta", "alpha"])
        #expect(try ModelStore(directory: picked.store).recordedModels() == ["alpha", "zeta"])
        #expect(throws: (any Error).self) { try ModelStore(directory: picked.fixtures).recordedModels() }
    }

    /// The bench holds a fixture on a Parakeet model installed as ModelInstall lays out the
    /// repo, the stub models in place of weights, loaded by `Bench.loadInPlace`. The utterance
    /// hands the pass the second of audio and its 0.3 s hangover, 17 frames. Each id is read as
    /// the word `w<id>`, and at each step the stub joint emits its frame's index and moves on by
    /// the token fed before it mod 5, the blank's 8192 first: 0 +2, 2 +0, 2 +2, 4 +2, 6 +4,
    /// 10 +1, 11 +0, 11 +1, 12 +1, 13 +2, 15 +3, past the last frame.
    @Test func aFixtureIsHeldOnAnInstalledParakeetModel() async throws {
        let scratch = try ScratchStore(files: [:])
        let pieces = Dictionary(uniqueKeysWithValues: (0..<ParakeetWindow.blank).map { (String($0), " w\($0)") })
        try scratch.installParakeet(copying: ScratchStore.parakeetStubs, files: [ParakeetModel.vocabulary: String(decoding: JSONEncoder().encode(pieces), as: UTF8.self)])
        let store = ModelStore(directory: scratch.root)
        let heard = "w0 w2 w2 w4 w6 w10 w11 w11 w12 w13 w15"
        let fixture = try Fixture(name: "second", clip: AudioClip(samples: [Float](repeating: 0.25, count: 16_000)), reference: heard)
        let plan = try BenchPlan(models: [.parakeet(.tdtV3)], arrivals: [.batch], servings: [.idle], runs: 1, vocabulary: .empty)
        let rows = Mutex<[BenchRow]>([])
        try await Bench.measure([fixture], plan: plan, load: { try await Bench.loadInPlace(store, $0) }, emit: {
            if case .row(let row) = $0 { rows.withLock { $0.append(row) } }
        })
        let held = rows.withLock { $0 }
        #expect(held.map { $0.cells.first { $0.name == "model" }?.value } == ["parakeet-tdt-0.6b-v3"])
        let row = try #require(held.first)
        #expect(row.cells.first { $0.name == "wer" }?.value == "0.000")
        #expect(row.narration.hasPrefix("second batch idle: heard \" \(heard)\","))
    }
}
