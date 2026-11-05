import Dictation
import Foundation
import Insertion
import LowTalkerCore
import Testing
import TestProbes

private struct LoadFailed: Error, CustomStringConvertible {
    var description: String { "a weight file is unreadable" }
}

/// A press the model's load failed under keeps what was said, and what was kept is read into held
/// words once an engine has landed: the words of a press made before the load failed are
/// recoverable once the failure is fixed. [LAW:behavior-not-structure] Asked through the loop and the
/// hold, with an engine that runs its passes through the real `EngineTurns`, and not through
/// what `Recovery` calls.
///
/// A second of speech is the unit, so `seconds` is read as a whole number and a speech is told
/// apart by its first sample.
@MainActor
@Suite struct RecoveryTests {
    private static func second(_ marker: Float) -> [Float] { [marker] + Array(repeating: 0, count: 15_999) }

    private static func said(_ marker: Float, under terms: [String] = []) -> UnheardSpeech {
        UnheardSpeech(said: .now, vocabulary: terms, samples: second(marker))
    }

    /// An engine that says `first`, `second` or `third` by the speech's first sample.
    private static func reading(_ turns: EngineTurns, inside: Gate? = nil) -> TurnedTranscriber {
        TurnedTranscriber(turns: turns, inside: inside) { samples throws(TranscriptionFailure) in
            switch samples.first {
            case 1: Transcript(typed: " first")
            case 2: Transcript(typed: " second")
            default: Transcript(typed: " other")
            }
        }
    }

    /// A load a press waits on, which fails once the test opens `gate`.
    private static func failingLoad(_ gate: Gate) -> Dictation.Engine {
        { () async throws(EngineUnavailable) -> any Transcriber in
            await gate.wait()
            throw EngineUnavailable(LoadFailed())
        }
    }

    private static func store(_ speeches: UnheardSpeech...) throws -> FakeUnheardStore {
        let store = FakeUnheardStore()
        for speech in speeches { _ = try store.keep(speech) }
        return store
    }

    /// A rig with nothing loading, over `store`, which an earlier run may have left speech in.
    private static func rig(over store: FakeUnheardStore = FakeUnheardStore(), turns: EngineTurns = EngineTurns()) async throws -> Rig {
        try await Rig(engine: { () throws(EngineUnavailable) -> Dictation.Engine in throw EngineUnavailable(LoadFailed()) }, keepingSpeech: store, turns: turns)
    }

    // MARK: - a press the load failed under

    /// The ticket's case: a press made while the model loads, and the load then fails. What was
    /// said is kept whole, to the key-up, the engine's turn is let go at the failure, and the
    /// report says it is kept.
    @Test(.timeLimit(.minutes(1))) func aPressTheLoadFailsUnderKeepsEverythingSaidAndLetsGoOfTheEngine() async throws {
        let gate = Gate()
        let rig = try await Rig(transcriber: Self.failingLoad(gate))
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2, 3])
        await gate.changed.settled { gate.waiting == 1 }
        // A served decode asked for now runs only once no press holds the engine, so its
        // completing before the key comes up is the hold being let go at the failure.
        let served = Task { try await rig.turns.decode(as: .served) { () async throws(TranscriptionFailure) in 7 } }
        gate.open()
        #expect(try await served.value == 7)
        rig.speak([4, 5])
        rig.keyUp()

        let stopped = try #require(await rig.report().failure as? PressStopped)
        let kept = try #require(stopped.cause as? AudioKept)
        #expect(kept.trouble == nil)
        #expect(kept.description.contains("is kept"))
        #expect(rig.inputMethod.inserted.isEmpty)
        let speech = try #require(rig.unheard.kept.first)
        #expect(rig.unheard.kept.count == 1)
        #expect(speech.samples == [1, 2, 3, 4, 5])
        #expect(speech.vocabulary == Rig.dictation.vocabulary.terms.map(\.text))
        #expect(kept.seconds == speech.seconds)
    }

    /// A keep that fails is a loss, and the report says so with the reason.
    @Test(.timeLimit(.minutes(1))) func aKeepThatFailsIsToldAsLostSpeech() async throws {
        let gate = Gate()
        let rig = try await Rig(transcriber: Self.failingLoad(gate))
        rig.unheard.fail(keeping: UnheardFault("the disk is full"))
        gate.open()
        rig.hold()

        let stopped = try #require(await rig.report().failure as? PressStopped)
        let kept = try #require(stopped.cause as? AudioKept)
        #expect(kept.trouble == UnheardFault("the disk is full"))
        #expect(kept.description.contains("it is lost"))
        #expect(rig.unheard.kept.isEmpty)
    }

    /// A chord that was a typed key's modifier and a press thrown away with Escape are the
    /// person's own discards, as they are for words: nothing of either is kept.
    @Test(.timeLimit(.minutes(1))) func aModifierPressAndACancelledPressKeepNothing() async throws {
        let gate = Gate()
        gate.open()
        let rig = try await Rig(transcriber: Self.failingLoad(gate))

        rig.usedAsModifier()
        guard case .usedAsModifier = await rig.report() else { Issue.record("expected the modifier press to be reported as one"); return }
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2, 3])
        rig.dictation.press(.ended(.cancelled))
        guard case .cancelled = await rig.report() else { Issue.record("expected the press to be reported cancelled"); return }

        #expect(rig.unheard.kept.isEmpty)
    }

    /// What a press the load failed under said is read into held words by the engine that lands
    /// after it, with no press in between.
    @Test(.timeLimit(.minutes(1))) func whatAFailedLoadsPressSaidIsHeldAsWordsOnceAnEngineLands() async throws {
        let gate = Gate()
        gate.open()
        let rig = try await Rig(transcriber: Self.failingLoad(gate))
        rig.hold(speaking: Self.second(1))
        _ = await rig.report()

        rig.recovery.landed(Self.reading(rig.turns).served)
        await rig.recovery.settled()

        #expect(rig.hold.held?.allWords.text == " first")
        #expect(rig.unheard.kept.isEmpty)
        #expect(rig.recovery.kept.isEmpty)
    }

    // MARK: - what is read when an engine lands

    @Test(.timeLimit(.minutes(1))) func speechKeptByAnEarlierRunIsHeldAsWordsInTheOrderSaidWithTheWarning() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1, under: ["Brynleigh"]), Self.said(2)))
        #expect(rig.recovery.lines == ["Speech waiting for the model: 2 s"])
        let engine = Self.reading(rig.turns)

        rig.recovery.landed(engine.served)
        await rig.recovery.settled()

        #expect(rig.hold.held?.allWords.text == " first second")
        #expect(rig.hold.held?.warnings.allSatisfy { $0.hasPrefix("WARNING: These words were said before the model had loaded") } == true)
        #expect(engine.heard.all.map(\.vocabulary.terms.count) == [1, 0])
        #expect(rig.unheard.kept.isEmpty)
        #expect(rig.recovery.lines.isEmpty)
    }

    /// One speech the engine cannot read neither blocks the speech behind it nor is tried again,
    /// and it stays kept, named in the menu, until the person lets it go.
    @Test(.timeLimit(.minutes(1))) func aSpeechThatCannotBeReadStaysKeptAndTheOnesBehindItAreRead() async throws {
        let store = try Self.store(Self.said(9), Self.said(2))
        store.makeUnreadable(try #require(store.ids.first))
        let rig = try await Self.rig(over: store)

        rig.recovery.landed(Self.reading(rig.turns).served)
        await rig.recovery.settled()

        #expect(rig.hold.held?.allWords.text == " second")
        #expect(rig.unheard.kept.count == 1)
        #expect(rig.recovery.lines == ["Speech the model could not read: 1 s (the file is unreadable)"])
    }

    @Test(.timeLimit(.minutes(1))) func aSpeechTheEngineFailsOnStaysKeptAndHoldsNothing() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1)))
        let failing = TurnedTranscriber(turns: rig.turns) { _ throws(TranscriptionFailure) in throw .engine(LoadFailed()) }

        rig.recovery.landed(failing.served)
        await rig.recovery.settled()

        #expect(rig.hold.held == nil)
        #expect(rig.unheard.kept.count == 1)
        #expect(rig.recovery.lines.count == 1 && rig.recovery.lines[0].hasPrefix("Speech the model could not read: 1 s ("))
    }

    @Test(.timeLimit(.minutes(1))) func speechThatWasNothingSpokenIsLetGoAndHoldsNothing() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1)))
        let silent = TurnedTranscriber(turns: rig.turns) { _ throws(TranscriptionFailure) in throw .nothingSpoken(peak: 0, quiet: .none) }

        rig.recovery.landed(silent.served)
        await rig.recovery.settled()

        #expect(rig.hold.held == nil)
        #expect(rig.unheard.kept.isEmpty)
    }

    /// A press made after the landing is heard first: it takes the engine from the recovery's pass,
    /// types its words, and the recovered words stand in the hold behind them, said earlier and
    /// warned of, once the press is done. None is lost and none is typed twice.
    @Test(.timeLimit(.minutes(1))) func aPressMadeAfterTheLandingTypesFirstAndTheRecoveredWordsAreHeldBehindIt() async throws {
        let turns = EngineTurns()
        let live = TurnedTranscriber(turns: turns) { _ throws(TranscriptionFailure) in Transcript(typed: " live") }
        let rig = try await Rig(engine: { { live } }, keepingSpeech: try Self.store(Self.said(1)), turns: turns)
        let inside = Gate()
        let recovering = Self.reading(turns, inside: inside)

        rig.recovery.landed(recovering.served)
        await inside.changed.settled { inside.waiting == 1 }
        rig.hold()
        _ = try await rig.session()
        inside.open()
        await rig.recovery.settled()

        #expect(rig.inputMethod.inserted == [" live"])
        #expect(rig.hold.held?.allWords.text == " first")
        #expect(recovering.heard.all.count == 1)
    }

    /// The load does not wait on the recovery: a press waiting on the load that lands is heard,
    /// with a recovery reading in the same landing.
    @Test(.timeLimit(.minutes(1))) func aPressWaitingOnALoadThatLandsIsHeardWhileKeptSpeechIsRead() async throws {
        let turns = EngineTurns()
        let live = TurnedTranscriber(turns: turns) { _ throws(TranscriptionFailure) in Transcript(typed: " live") }
        let loading = Gate()
        let rig = try await Rig(engine: { { await loading.wait(); return live } }, keepingSpeech: try Self.store(Self.said(1)), turns: turns)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2, 3])
        await loading.changed.settled { loading.waiting == 1 }

        loading.open()
        rig.recovery.landed(Self.reading(turns).served)
        rig.keyUp()
        _ = try await rig.session()
        await rig.recovery.settled()

        #expect(rig.inputMethod.inserted == [" live"])
        #expect(rig.hold.held?.allWords.text == " first")
    }

    // MARK: - the person's discard, and the loop's turn

    /// The hand-off waits for the loop's turn, so it falls between nothing an insert is doing: the
    /// words are not held while an earlier operation on the turn is still running.
    @Test(.timeLimit(.minutes(1))) func theWordsAreHandedToTheHoldInTheLoopsTurn() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1)))
        let busy = Gate()
        try rig.sessions.submit { await busy.wait() }

        rig.recovery.landed(Self.reading(rig.turns).served)
        await busy.changed.settled { busy.waiting == 1 }
        // Long enough for the decode to have been read: the turn is what is being waited on.
        await Task.yield()
        #expect(rig.hold.held == nil)

        busy.open()
        await rig.recovery.settled()
        #expect(rig.hold.held?.allWords.text == " first")
    }

    /// A discard that comes while a speech is being read leaves no words in the hold and no file.
    @Test(.timeLimit(.minutes(1))) func aDiscardWhileASpeechIsBeingReadLeavesNoWordsAndNoFile() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1), Self.said(2)))
        let busy = Gate()
        try rig.sessions.submit { await busy.wait() }

        rig.recovery.landed(Self.reading(rig.turns).served)
        await busy.changed.settled { busy.waiting == 1 }
        rig.recovery.discard()
        busy.open()
        await rig.recovery.settled()

        #expect(rig.hold.held == nil)
        #expect(rig.unheard.kept.isEmpty)
        #expect(rig.recovery.kept.isEmpty)
        #expect(rig.recovery.lines.isEmpty)
    }

    /// A discard while the engine is mid-pass stops the read, and nothing is held.
    @Test(.timeLimit(.minutes(1))) func aDiscardWhileTheEngineIsMidPassStopsTheReading() async throws {
        let rig = try await Self.rig(over: try Self.store(Self.said(1)))
        let inside = Gate()

        rig.recovery.landed(Self.reading(rig.turns, inside: inside).served)
        await inside.changed.settled { inside.waiting == 1 }
        rig.recovery.discard()
        await rig.recovery.settled()

        #expect(rig.hold.held == nil)
        #expect(rig.unheard.kept.isEmpty)
    }

    /// Speech kept after an engine has landed, by a press that was still open when it did, is read
    /// at once and not left until the next launch.
    @Test(.timeLimit(.minutes(1))) func speechKeptAfterTheLandingIsReadAtOnce() async throws {
        let rig = try await Self.rig()
        rig.recovery.landed(Self.reading(rig.turns).served)

        try rig.recovery.keep(Self.said(2))
        await rig.recovery.settled()

        #expect(rig.hold.held?.allWords.text == " second")
        #expect(rig.unheard.kept.isEmpty)
    }

    /// A file that could not be removed once its words were held is told, since a launch that
    /// read it again would hold them twice.
    @Test(.timeLimit(.minutes(1))) func aFileThatCannotBeRemovedAfterItsWordsAreHeldIsToldAsATrouble() async throws {
        let store = try Self.store(Self.said(1))
        store.fail(removing: UnheardFault("the file is locked"))
        let rig = try await Self.rig(over: store)

        rig.recovery.landed(Self.reading(rig.turns).served)
        await rig.recovery.settled()

        #expect(rig.hold.held?.allWords.text == " first")
        #expect(rig.recovery.troubles.count == 1 && rig.recovery.troubles[0].contains("the file is locked"))
        #expect(rig.recovery.kept.isEmpty)
    }
}

/// The files themselves, in a folder of their own that each case removes.
@Suite struct UnheardFilesTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "unheard-\(UUID().uuidString)")
    }

    @Test func aSpeechReadsBackAsItWasKeptAndRemovalLeavesNothing() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = UnheardFiles(directory: directory)
        let speech = UnheardSpeech(said: Date(timeIntervalSince1970: 1_700_000_000), vocabulary: ["Brynleigh", "Fryslie"], samples: [0.25, -0.5, 1, 0])

        let entry = try files.keep(speech)

        #expect(files.entries() == UnheardRead(entries: [entry]))
        #expect(entry.vocabulary == ["Brynleigh", "Fryslie"])
        #expect(try files.samples(of: entry) == speech.samples)
        try files.remove(entry)
        #expect(files.entries() == UnheardRead(entries: []))
        try files.remove(entry)
    }

    @Test func speechIsListedOldestFirst() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = UnheardFiles(directory: directory)
        let later = try files.keep(UnheardSpeech(said: Date(timeIntervalSince1970: 1_700_000_100), vocabulary: [], samples: [1]))
        let earlier = try files.keep(UnheardSpeech(said: Date(timeIntervalSince1970: 1_700_000_000), vocabulary: [], samples: [2]))

        #expect(files.entries().entries == [earlier, later])
    }

    /// A file the store cannot read is moved aside and named, so nothing is written over it and it
    /// is not tried again; the speech beside it is still listed.
    @Test func aFileThatCannotBeReadIsMovedAsideAndNamed() throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = UnheardFiles(directory: directory)
        let good = try files.keep(UnheardSpeech(said: .now, vocabulary: [], samples: [1]))
        try Data("not a speech\n".utf8).write(to: directory.appending(path: "0-garbled.speech"))
        let cut = try files.keep(UnheardSpeech(said: .now + 1, vocabulary: [], samples: [1, 2, 3, 4]))
        let cutURL = directory.appending(path: cut.id)
        try Data(contentsOf: cutURL).dropLast(3).write(to: cutURL)

        let read = files.entries()

        #expect(read.entries == [good])
        #expect(read.setAside.count == 2)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "0-garbled.speech.unreadable").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "\(cut.id).unreadable").path))
        #expect(files.entries().setAside.isEmpty)
    }

    @Test func noFolderIsNothingKept() {
        #expect(UnheardFiles(directory: Self.folder()).entries() == UnheardRead(entries: []))
    }
}
