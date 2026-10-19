import Dictation
import Foundation
import Grants
import Insertion
import LowTalkerCore
import Synchronization
import Testing
import TestProbes

private struct NoEngine: Error {}
private struct BadBuffer: Error {}

/// The loop with a fake behind every seam: the microphone is fed by hand, the engine
/// answers as scripted, the input method keeps what it inserted, and every session's report is
/// awaited off a stream rather than polled for.
@MainActor
final class Rig {
    static let textEdit = BundleID(rawValue: "com.apple.TextEdit")
    static let dictation = Mode.dictation

    let hardware = FakeHardware()
    let capture: AudioCapture
    /// Where the fake microphone's clock starts; any moment would do, since a timeline
    /// is measured in differences.
    static let origin = HostTime(uptime: .zero)
    /// The host clock the fake microphone stamps its buffers with. It starts where the
    /// capture's timeline does and advances by the audio the test feeds, so a test can
    /// name the moment a key went down in the middle of speech already spoken.
    private(set) var now = Rig.origin
    let inputMethod = FakeInputMethod()
    let turns = EngineTurns()
    let dictation: Dictation
    private let reports: AsyncStream<Dictation.Report>
    /// Raised by the first outcome to be reported. The stream says what the next report
    /// is, this says whether one has come at all - the difference a `finish` that
    /// returned before its session was reported would show.
    let reported = Flag()
    /// Every activity the loop has shown, in order.
    let shown = Shown()
    /// The words no cursor took, which outlive the loop as they do in the app.
    let hold: Hold
    /// Where they are kept, which outlives the app.
    let store: FakeHeldStore

    init(
        transcriber: @escaping @Sendable @MainActor () async throws(EngineUnavailable) -> any Transcriber,
        retaining: TimeInterval = AudioCapture.defaultRetention,
        atRest: MicrophoneAtRest = .shut,
        frontmost: @escaping @Sendable @MainActor () throws(FrontmostUnknown) -> BundleID = { textEdit },
        keeping store: FakeHeldStore = FakeHeldStore()
    ) async throws {
        capture = AudioCapture(retaining: retaining, hardware: hardware, startingAt: Self.origin, reporting: { _ in })
        // Shut between presses unless a test says otherwise, which is the loop the app
        // runs when no config file asks for the microphone to be held.
        try await capture.start(try MicrophonePermission(authority: Authorized()).current.grant(), atRest: atRest)
        let (stream, feed) = AsyncStream.makeStream(of: Dictation.Report.self)
        reports = stream
        let reported = reported
        let shown = shown
        self.store = store
        hold = Hold(store: store, failedToKeep: { shown.unkept.append($0) }, showing: { shown.held.append($0) })
        dictation = Dictation(
            capture: capture,
            transcriber: transcriber,
            turns: turns,
            executor: Executor(insertingThrough: inputMethod),
            hold: hold,
            frontmost: frontmost,
            report: { press in
                reported.raise()
                feed.yield(press)
            },
            showing: { shown.activities.append($0) }
        )
    }

    convenience init(
        hearing transcriber: FakeTranscriber,
        retaining: TimeInterval = AudioCapture.defaultRetention,
        atRest: MicrophoneAtRest = .shut,
        keeping store: FakeHeldStore = FakeHeldStore()
    ) async throws {
        try await self.init(transcriber: { transcriber }, retaining: retaining, atRest: atRest, keeping: store)
    }

    /// Audio captured from `now` on, stamped as the microphone would stamp it, into
    /// whichever engine is running: a replaced one is deaf, as it is on a real Mac.
    func speak(_ samples: [Float]) {
        hardware.live.appending(samples, now)
        now = now + .seconds(AudioClip.duration(for: samples.count))
    }

    /// Time passing with nothing appended: the speaker may be talking, and that is exactly
    /// what nothing is capturing. This is how a test says a key-down reached the loop late:
    /// the stamp is taken before the wait and the press is made after it.
    func wait(_ duration: TimeInterval) {
        now = now + .seconds(duration)
    }

    /// The input device changes: macOS stops the engine and posts the change, and capture
    /// launches a fresh one on the new device. Nothing is captured in between, and the
    /// test's clock does not advance over it either - the gap leaves no samples behind to
    /// be measured by, which is the whole of why it has to be marked when it happens.
    func changeDevice() {
        hardware.readied.onStale()
    }

    /// A hold of `mode`'s chord with `samples` captured during it, the key-down heard the
    /// moment it was made.
    func hold(in mode: Mode = Rig.dictation, speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(mode, at: now))
        speak(samples)
        keyUp()
    }

    /// The key of a hold coming up, its event stamped on the real host clock - the clock
    /// key-up figures are timed by - and told to the loop `late` after it was stamped.
    func keyUp(deliveredLate late: Duration = .zero) {
        dictation.press(.ended(.released(.hold, at: HostTime(uptime: HostTime.now.uptime - late))))
    }

    /// A hold that opens no microphone, because something refused the press before one
    /// could open - no app to insert into, or no device to record with. Nothing is spoken
    /// into it, which is not the test being coy: there is nothing listening, and that is
    /// the state being described.
    func refusedHold() {
        dictation.press(.began(Self.dictation, at: now))
        keyUp()
    }

    /// The same hold, ended by the hotkey stopping rather than by the speaker letting
    /// go: everything up to here was captured, and what came after it was not.
    func lapse(speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(Self.dictation, at: now))
        speak(samples)
        dictation.press(.ended(.lapsed))
    }

    /// The same hold, its chord the modifier of a key typed while it was down: Right Option
    /// held for a special character.
    func usedAsModifier(speaking samples: [Float] = [1, 2, 3]) {
        dictation.press(.began(Self.dictation, at: now))
        speak(samples)
        dictation.press(.ended(.usedAsModifier))
    }

    /// The next session's outcome, in press order.
    func report() async -> Dictation.Report.Outcome {
        await pressReport().outcome
    }

    /// The next press's whole report: its outcome and what its microphone delivered.
    func pressReport() async -> Dictation.Report {
        for await report in reports { return report }
        preconditionFailure("the report stream ended while a test was still reading it")
    }

    func session() async throws -> Dictation.Session {
        try await report().get()
    }
}

@MainActor
final class Shown {
    var activities: [Dictation.Activity] = []
    /// What is held at the start, then every change of it, in order.
    var held: [Held?] = []
    /// Every write of what is held that failed, in order.
    var unkept: [HeldUnkept] = []
}

/// Whether `cause` is the engine's own library failing with an error of type `error`.
private func engineFailed(_ cause: any Accounted, with error: any Error.Type) -> Bool {
    guard case .engine(let thrown)? = cause as? TranscriptionFailure else { return false }
    return type(of: thrown) == error
}

/// A press that came to something other than a session or a failure.
struct NotASession: Error {
    let outcome: Dictation.Report.Outcome
}

extension Dictation.Report.Outcome {
    /// The session, or why there was none, thrown.
    func get() throws -> Dictation.Session {
        switch self {
        case .session(let session): return session
        case .failed(let failed): throw failed
        case .usedAsModifier: throw NotASession(outcome: self)
        }
    }

    /// What failed, when the press did.
    var failure: (any Accounted)? {
        if case .failed(let failed) = self { return failed.failure }
        return nil
    }
}

/// One way an insert fails, and whether its words could be at a cursor anyway.
struct FailedInsert: Sendable, CustomTestStringConvertible {
    let failure: InsertFailure
    let mayHaveLanded: Bool

    var testDescription: String { "\(failure)" }
}

/// Held words as typed, which say something, so the part is made.
func part(_ typed: String, _ warning: String) -> Held.Part {
    Held.Part(words: Transcript(typed: typed), warning: warning)!
}

private let port = "ai.promptctl.low-talker.test.insert"
private let stranger = PeerIdentity.signed(identifier: "someone.else", certificate: String(repeating: "0", count: 40))

/// Every refusal, every way the channel fails, words not yet taken, and an answerer this end
/// could not name.
let failedInserts: [FailedInsert] = Refusal.allCases.map { FailedInsert(failure: .refused($0), mayHaveLanded: false) } + [
    FailedInsert(failure: .unreachable(.nothingIsListening(port: port)), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.requestWasNotTaken(port: port, after: .seconds(1))), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.answerDidNotArrive(port: port, after: .seconds(1))), mayHaveLanded: true),
    FailedInsert(failure: .unreachable(.didNotSayWhoItIs(port: port, after: .seconds(1))), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.answerWasAbandoned(port: port)), mayHaveLanded: true),
    FailedInsert(failure: .unreachable(.answeredByAStranger(port: port, pid: 7, because: .someoneElse(stranger), required: stranger, words: .notSent)), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.answeredByAStranger(port: port, pid: 7, because: .someoneElse(stranger), required: stranger, words: .mayHaveLanded)), mayHaveLanded: true),
    FailedInsert(failure: .unreachable(.failed(port: port, status: KERN_FAILURE, words: .notSent)), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.failed(port: port, status: KERN_FAILURE, words: .mayHaveLanded)), mayHaveLanded: true),
    FailedInsert(failure: .unreachable(.answerWasNotReadable(port: port, bytes: 3, words: .notSent)), mayHaveLanded: false),
    FailedInsert(failure: .unreachable(.answerWasNotReadable(port: port, bytes: 3, words: .mayHaveLanded)), mayHaveLanded: true),
    FailedInsert(failure: .notYetTaken(NotYetTaken(characters: 11, into: "com.apple.TextEdit")), mayHaveLanded: true),
    FailedInsert(failure: .answererUnreadable(.noCertificate), mayHaveLanded: false),
]

@MainActor
@Suite struct DictationTests {
    @Test func aHoldInsertsWhatWasSaidIntoTheAppThatWasInFront() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "hi") }
        let rig = try await Rig(hearing: engine)
        rig.hold(speaking: [1, 2, 3])
        let session = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 3]])
        #expect(session.transcription.transcript.text == "hi")
        #expect(session.context.frontmostApp == Rig.textEdit)
        #expect(session.context.press == .hold)
        #expect(session.performed.count == 1)
        #expect(session.performed[0].into == Rig.textEdit)
        #expect(session.keyUpToTranscript >= .zero)
        #expect(rig.inputMethod.inserted == ["hi"])
    }

    /// The press's line says the room its quiet was judged against, what that room refused, and the transients refused.
    @Test func aPressLineSaysTheRoomItsQuietWasJudgedAgainst() async throws {
        let rig = try await Rig(hearing: FakeTranscriber(quiet: Quiet(letGo: 2, room: 0.001, refusedAsRoom: 1.5, transients: Transients(count: 2, longest: 0.03))) { _ in Transcript(typed: "hi") })
        rig.hold(speaking: [1, 2, 3])
        let line = try await rig.session().description
        #expect(line.contains("past 2.0 s of quiet (room -60.0 dBFS, 1.5 s refused as room, 2 transients refused, the longest sounding 0.03 s)"), "\(line)")
    }

    /// Confirmed words land while the key is still down, each run once and in order, and
    /// key-up commits only what follows them. The press's line counts the commits acknowledged
    /// while it was open, the words they carried, and when the first landed.
    ///
    /// [LAW:no-ambient-temporal-coupling] The third run is held at the input method's gate
    /// across the key-up: the runs go one at a time, so a third insert waiting there is the
    /// proof the second has been counted, where the fake having taken the second's text is not.
    @Test func confirmedWordsAreCommittedInOrderWhileThePressIsOpenAndKeyUpCommitsTheRest() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 6 ? "hello there my" : samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there my friend") }
        let rig = try await Rig(hearing: engine)
        let keyDown = HostTime.now
        rig.dictation.press(.began(Rig.dictation, at: keyDown))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello"] })
        rig.speak([3])
        rig.speak([4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello", " there"] })
        let landed = HostTime.now
        rig.inputMethod.hold()
        rig.speak([5, 6])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.keyUp()
        rig.inputMethod.letGo()
        let session = try await rig.session()
        #expect(rig.inputMethod.inserted == ["hello", " there", " my", " friend"])
        #expect(session.transcription.transcript.text == "hello there my friend")
        #expect(session.performed.count == 4)
        #expect(session.duringPress.commits == 2)
        #expect(session.duringPress.wordsCommitted == 2)
        let firstCommit = try #require(session.duringPress.firstCommit)
        #expect(firstCommit > .zero && firstCommit <= landed - keyDown)
        #expect("\(session)".contains("2 commits of 2 words, the first \(Int(firstCommit / .milliseconds(1))) ms after key-down"))
        #expect("\(session.performed[2])".contains("key-down to acknowledged"))
        #expect("\(session.performed[3])".contains("key-up to acknowledged"))
    }

    /// A refusal while the press is open inserts nothing anywhere else: the words from it on,
    /// the key-up's rest included, are held with what refused them, and the report says how
    /// many words landed before it.
    @Test func aRefusalDuringThePressHoldsTheRestAndSaysHowManyLanded() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello"] })
        rig.inputMethod.refusing(.refused(.cursorIsInAnotherApp))
        rig.speak([3, 4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2, 3, 4] })
        rig.keyUp()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(stopped.landed == 1)
        #expect(stopped.cause as? InsertFailure == .refused(.cursorIsInAnotherApp))
        #expect(failureLine(stopped) == "\(Refusal.cursorIsInAnotherApp) 1 words of your dictation were inserted before it; the rest were not.")
        #expect("\(stopped)".hasSuffix("1 words of your dictation were inserted before it; the rest were not."))
        #expect(rig.inputMethod.inserted == ["hello"])
        #expect(rig.hold.held == .unplaced(part(" there friend", "\(Refusal.cursorIsInAnotherApp)")))
    }

    /// The person moves to another app with a text client while the press is open - the
    /// Finder, on studious - and the words after the move are refused there, never typed
    /// into it: they are held, and the report says how many landed in the app they began in.
    @Test func movingToAnotherAppMidPressHoldsTheRest() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello"] })
        // The move is a cursor arriving in the Finder, which the input method tells the app.
        rig.inputMethod.reaching(BundleID(rawValue: "com.apple.finder"))
        rig.dictation.cursorArrived()
        rig.speak([3, 4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2, 3, 4] })
        rig.keyUp()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(stopped.landed == 1)
        #expect(stopped.cause as? InsertFailure == .refused(.dictationIsInAnotherApp))
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["hello"])
        #expect(rig.hold.held?.words == Transcript(typed: " there friend"))
    }

    /// The same move with nothing confirmed after it: what key-up inserts is the press's rest,
    /// and it is bound to the app the press's words went to like every commit before it.
    @Test func movingToAnotherAppBeforeKeyUpKeepsTheRestOutOfIt() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello"] })
        rig.inputMethod.reaching(BundleID(rawValue: "com.apple.finder"))
        rig.keyUp()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(stopped.landed == 1)
        #expect(stopped.cause as? InsertFailure == .refused(.dictationIsInAnotherApp))
        #expect(failureLine(stopped) == "\(Refusal.dictationIsInAnotherApp) 1 words of your dictation were inserted before it; the rest were not.")
        #expect(rig.inputMethod.inserted == ["hello"])
        #expect(rig.hold.held?.words == Transcript(typed: " there friend"))
    }

    /// A refusal while the press is open stops nothing: the press keeps listening, and once
    /// a cursor takes words again the next run carries the held ones ahead of its own, as one
    /// insert, and nothing is held after it.
    @Test func aPressRefusedMidwayKeepsListeningAndLandsTheHeldWordsWithTheNextRun() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 6 ? "hello there my" : samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there my friend") }
        let rig = try await Rig(hearing: engine)
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.hold.held?.words == Transcript(typed: "hello") })
        rig.speak([3, 4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.hold.held?.words == Transcript(typed: "hello there") })
        rig.inputMethod.refusing(nil)
        rig.speak([5, 6])
        // The hold empties on the main actor in the step that counts the words, after the
        // input method has them.
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello there my"] && rig.hold.held == nil })
        rig.keyUp()
        let session = try await rig.session()
        #expect(rig.inputMethod.inserted == ["hello there my", " friend"])
        #expect(session.duringPress.wordsCommitted == 3)
        #expect(rig.hold.held == nil)
        #expect(rig.shown.held.last == .some(nil))
    }

    /// A refusal while the press is open is what the report names even when the press then
    /// lapses, or turns out to be a typed key's modifier: it is what left spoken words unplaced,
    /// and the ending came after it. A pass between them that confirms nothing new is no run,
    /// so the held words are not inserted on their own, before the ending or after it.
    @Test(arguments: [HotkeyDetector.Ending.lapsed, .usedAsModifier])
    func aRefusalBeforeALapseIsWhatTheReportNames(ending: HotkeyDetector.Ending) async throws {
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.count >= 2 ? "hello" : "") }) { _ in Transcript(typed: "hello") }
        let rig = try await Rig(hearing: engine)
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.hold.held != nil })
        rig.inputMethod.refusing(nil)
        rig.speak([3])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing.count == 3 })
        rig.dictation.press(.ended(ending))
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(stopped.cause as? InsertFailure == .refused(.noTextFieldHasFocus))
        #expect(rig.inputMethod.inserted == [])
        // The ending heard nothing past the refused run, so the warning stays the refusal's.
        #expect(rig.hold.held == .unplaced(part("hello", "\(Refusal.noTextFieldHasFocus)")))
    }

    /// A pass that confirms only whitespace confirms nothing said, so it is no run either:
    /// the held words wait for key-up rather than going in with a space after them.
    @Test func aPassConfirmingOnlyWhitespaceIsNoRun() async throws {
        let blank = Transcript(words: Transcript(typed: "hello").words + [Transcript.Word(text: " ", time: 0...0, confidence: 1.0)])
        let engine = FakeTranscriber(confirming: { samples in samples.count >= 3 ? blank : Transcript(typed: samples.count >= 2 ? "hello" : "") }) { _ in blank }
        let rig = try await Rig(hearing: engine)
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.hold.held != nil })
        rig.inputMethod.refusing(nil)
        rig.speak([3])
        rig.keyUp()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["hello"])
    }

    /// A decode that fails after words were committed says how many are at the cursor
    /// rather than that nothing was placed.
    @Test func aDecodeThatFailsAfterCommitsSaysHowManyLanded() async throws {
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.count >= 2 ? "hello there" : "") }) { _ throws(TranscriptionFailure) in throw .engine(NoEngine()) }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello there"] })
        rig.keyUp()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(engineFailed(stopped.cause, with: NoEngine.self))
        #expect(stopped.landed == 2)
        #expect(failureLine(stopped) == "Your last dictation stopped: NoEngine(). 2 words of your dictation were inserted before it; the rest were not.")
    }

    /// [LAW:no-silent-failure] A press whose microphone opened after the words it was pressed
    /// for commits nothing: the engine reads the fragment it was given as a fluent sentence
    /// with the first words gone, and the capture knew the head was lost before any of it was
    /// confirmed. What it read is held beside the loss.
    @Test func aPressMissingItsHeadCommitsNothingAndHoldsWhatItHeard() async throws {
        let engine = FakeTranscriber(confirming: { samples in Transcript(typed: samples.count >= 2 ? "there" : "") }) { _ in Transcript(typed: "there") }
        let rig = try await Rig(hearing: engine)
        let keyWentDown = rig.now
        rig.wait(AudioCapture.warmUpAllowance + 0.4)
        rig.dictation.press(.began(Rig.dictation, at: keyWentDown))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2] })
        rig.keyUp()
        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.unopened)
        #expect(press.landed == 0)
        #expect(press.held == 1)
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held == .unplaced(part("there", "WARNING: Your microphone was not open for the whole of your dictation.")))
    }

    /// A press that lapses after some of its words were committed keeps them, commits
    /// nothing more, holds what it heard after them, and says how many of each.
    @Test func aLapseAfterCommitsKeepsThemAndHoldsTheRest() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 2 ? "hello there" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello there"] })
        rig.dictation.press(.ended(.lapsed))
        let lapsed = try #require(await rig.report().failure as? PressLapsed)
        #expect(lapsed.landed == 2)
        #expect(lapsed.held == 1)
        #expect("\(lapsed)" == "WARNING: The hotkey stopped listening during your dictation. The 2 words already inserted stay, and the 1 heard after them are held.")
        #expect(failureLine(lapsed) == "\(lapsed)")
        #expect(rig.inputMethod.inserted == ["hello there"])
        #expect(rig.hold.held == .unplaced(part(" friend", "WARNING: The hotkey stopped listening during your dictation.")))
    }

    /// The input device changes while the key is down, after a commit: the commits stop at
    /// once, since what is confirmed past the gap reads a fragment, but the decode hears on
    /// across the gap to key-up, and everything it read past the commit is held.
    @Test func aLossWhileTheKeyIsDownStopsTheCommitsAndTheDecodeHearsOn() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.inserted == ["hello"] })
        rig.changeDevice()
        rig.speak([3, 4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2, 3, 4] })
        rig.keyUp()
        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.interrupted)
        #expect(press.landed == 1)
        #expect(press.held == 2)
        #expect(engine.clips.map(\.samples) == [[1, 2, 3, 4]])
        #expect(rig.inputMethod.inserted == ["hello"])
        #expect(rig.hold.held?.words == Transcript(typed: " there friend"))
    }

    /// A press cut short whose decode fails says so, with how many words had landed: the
    /// words it heard could not be read, so there is nothing to hold.
    @Test func aCutPressWhoseDecodeFailsIsReportedAsTheFailure() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ throws(TranscriptionFailure) in throw .engine(NoEngine()) })
        rig.lapse()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(engineFailed(stopped.cause, with: NoEngine.self))
        #expect(rig.hold.held == nil)
    }

    /// The engine hears a press while it is still going on: the audio reaches it as it is
    /// captured, and what it reads comes back before the key does. The press's line carries
    /// the passes run by key-up, how many re-punctuated a settled word, and how long after
    /// key-down the first words came.
    @Test func aPressIsHeardWhileTheKeyIsStillDown() async throws {
        let engine = FakeTranscriber(reading: { Transcript(typed: $0.isEmpty ? "" : "hello") }, repunctuating: { $0.isEmpty ? 0 : 2 }) { _ in Transcript(typed: "hello") }
        let rig = try await Rig(hearing: engine)
        let keyDown = HostTime.now
        rig.dictation.press(.began(Rig.dictation, at: keyDown))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2] })
        #expect(engine.clips.isEmpty)
        let read = HostTime.now
        rig.keyUp()
        let session = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2]])
        #expect(session.duringPress.passes >= 1)
        #expect(session.duringPress.repunctuated == 2)
        let firstWords = try #require(session.duringPress.firstWords)
        #expect(firstWords > .zero && firstWords <= read - keyDown)
        #expect("\(session)".contains("passes during the press, 2 repunctuating a settled word, first words \(Int(firstWords / .milliseconds(1))) ms after key-down"))
        #expect(rig.inputMethod.inserted == ["hello"])
    }

    /// A key-up told late is timed from where the key came up, as a key-down is: the input
    /// method's hop to the app and the main queue's wait behind it are inside every key-up
    /// figure, and the session names how long the telling took.
    @Test func aKeyUpDeliveredLateIsTimedFromTheKeyComingUp() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "hi") })
        let late = Duration.milliseconds(300)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2, 3])
        rig.keyUp(deliveredLate: late)
        let session = try await rig.session()
        #expect(session.keyUpDelivery >= late)
        #expect(session.keyUpToTranscript >= session.keyUpDelivery)
        let insert = try #require(session.performed.last)
        #expect(insert.since == .up && insert.acknowledged >= session.keyUpDelivery)
        #expect("\(session)".contains("after key-up (delivered \(Int(session.keyUpDelivery / .milliseconds(1))) ms after it;"))
    }

    /// A press whose engine read nothing before the key came up says so, rather than
    /// timing words it never showed.
    @Test func aPressThatShowedNoWordsBeforeKeyUpSaysSo() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "hi") })
        rig.hold()
        let session = try await rig.session()
        #expect(session.duringPress.firstWords == nil)
        #expect("\(session)".contains("no words before key-up"))
    }

    /// The audio is what the ring held between the marks, and the microphone opens for
    /// the press, so there is nothing in front of them: the pre-roll reaches back over the
    /// moment the engine started and stops there. A press hears what was said into it and
    /// never the tail of the press before it - those words were said a minute ago, and a
    /// clip that began with them would transcribe to a sentence nobody just spoke.
    @Test func aPressHearsWhatWasSaidIntoItAndNotThePressBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try await Rig(hearing: engine)
        rig.hold(speaking: [1, 2])
        _ = try await rig.session()
        rig.hold(speaking: [7, 8])
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2], [7, 8]])
    }

    /// The other side of that trade, driven through the same loop: a microphone the resting
    /// mode has held open since `start()` has audio behind the key, so a press made a word
    /// into a sentence carries the word it was pressed a moment too late for. The test above
    /// pins what `shut` gives the indicator up for; this one pins what `open` buys back.
    @Test func aPressMadeWhileTheMicrophoneIsHeldOpenHearsTheWordsBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try await Rig(hearing: engine, atRest: .open)
        rig.speak([1, 2])
        rig.hold(speaking: [7, 8])
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 7, 8]])
    }

    /// The mark still comes from the key event's own stamp rather than from the moment
    /// the handler ran, and what that buys has changed with the microphone's lifetime:
    /// there is no audio behind an engine that has just started for the mark to reach
    /// into, so the stamp's remaining job is the other half - keeping a key-down stamped
    /// back among an earlier press's samples from beginning this press among them.
    @Test func aKeyDownDeliveredLateDoesNotReachIntoThePressBeforeIt() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "") }
        let rig = try await Rig(hearing: engine)
        let duringTheFirstPress = rig.now
        rig.hold(speaking: [1, 2, 3])
        _ = try await rig.session()

        rig.dictation.press(.began(Rig.dictation, at: duringTheFirstPress))
        rig.speak([4, 5])
        rig.keyUp()
        _ = try await rig.session()
        #expect(engine.clips.map(\.samples) == [[1, 2, 3], [4, 5]])
    }

    @Test func nothingSaidIsASessionThatInsertsNothing() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "") })
        rig.hold()
        let session = try await rig.session()
        #expect(session.performed.isEmpty)
        #expect(rig.inputMethod.inserted.isEmpty)
    }

    /// A press before the model is resident waits for it; loading is not a refusal.
    @Test func aPressWhileTheEngineLoadsWaitsForIt() async throws {
        let gate = Gate()
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig { await gate.wait(); return engine }
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.inputMethod.inserted.isEmpty)
        gate.open()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["a"])
    }

    /// A press holds the engine from key-down, before anything is heard, until its
    /// transcript is out, and lets go of it before the insert: served callers wait for the
    /// speaker and no longer. A refused press takes and lets go of it the same way.
    @Test func aPressHoldsTheEngineFromKeyDownUntilItsTranscriptIsOut() async throws {
        let gate = Gate()
        let rig = try await Rig(hearing: FakeTranscriber { _ in await gate.wait(); return Transcript(typed: "a") })
        rig.inputMethod.hold()
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        #expect(rig.turns.reading.holds == 1)
        rig.speak([1, 2, 3])
        rig.keyUp()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.turns.reading.holds == 1)
        gate.open()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        #expect(rig.turns.reading.holds == 0)
        rig.inputMethod.letGo()
        let displaced = try await rig.session().displaced
        #expect(!displaced.preempted && displaced.waiting == 0)

        rig.hardware.failingToLaunch = BadBuffer()
        rig.refusedHold()
        #expect(await rig.report().failure is NoMicrophone)
        #expect(rig.turns.reading.holds == 0)
    }

    /// Two presses are heard and inserted in the order they were spoken: the second press's
    /// decode takes the engine once the first has its transcript, so its passes cannot hold
    /// up the first's last one, and the words of one can never land inside the other's.
    @Test func sessionsAreHeardAndInsertedInOrder() async throws {
        let gate = Gate()
        let engine = FakeTranscriber { clip in
            // The first hold says "a" and waits; the second says "b" at once.
            if clip.samples == [1] { await gate.wait() }
            return Transcript(typed: clip.samples == [1] ? "a" : "b")
        }
        let rig = try await Rig(hearing: engine)
        rig.hold(speaking: [1])
        rig.hold(speaking: [2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(engine.clips.count == 1)
        #expect(engine.hearing == [1])
        #expect(rig.inputMethod.inserted.isEmpty)
        gate.open()
        let first = try await rig.session()
        let second = try await rig.session()
        #expect(first.transcription.transcript.text == "a")
        #expect(second.transcription.transcript.text == "b")
        #expect(rig.inputMethod.inserted == ["a", "b"])
    }

    /// [LAW:no-silent-failure] The key-down reached the loop long after the key went down,
    /// and the microphone opens when the loop hears it: the speaker had been talking for
    /// 0.4 s to a microphone that was shut, and no engine can be started in the past. What
    /// is left is the back of an utterance, and nothing in those samples or in the text
    /// they transcribe to says the front is missing - which is the whole reason the press
    /// says it rather than inserting it.
    ///
    /// This is the cost the epic traded the look-back for, and the door it has to leave by.
    /// Under continuous capture the pre-roll covered a late key-down by reaching back over
    /// audio already on the ring; with the microphone opening per press there is nothing
    /// behind the mark to reach into, so a loss that used to be repaired is now reported.
    @Test func aPressWhoseMicrophoneOpenedAfterTheWordsItWasPressedForIsHeldNotInserted() async throws {
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples == [4, 5] ? " b" : "a") }
        let rig = try await Rig(hearing: engine)

        let keyWentDown = rig.now
        // The speaker starts talking as they press. The loop hears the press later than the
        // warm-up an engine is allowed, so none of those words was captured.
        rig.wait(AudioCapture.warmUpAllowance + 0.4)
        rig.dictation.press(.began(Rig.dictation, at: keyWentDown))
        rig.speak([1, 2, 3])
        rig.keyUp()

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.unopened)
        #expect("\(press)" == "WARNING: Your microphone was not open for the whole of your dictation. Its 1 words are held.")
        #expect(!press.lost.interrupted)
        #expect(press.lost.scrolledOff == 0)
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held?.words == Transcript(typed: "a"))

        // The next press is heard the moment it is made, so its microphone is open for all
        // of it and it inserts, carrying the held words ahead of its own.
        rig.hold(speaking: [4, 5])
        #expect(try await rig.session().transcription.transcript.text == " b")
        #expect(engine.clips.last?.samples == [4, 5])
        #expect(rig.inputMethod.inserted == ["a b"])
    }

    /// The epic's contract, as one run: speech spoken into a press appears in that
    /// press's clip, whatever the loop is doing at the time. [LAW:behavior-not-structure]
    /// It asserts the audio each session was given and the text each one inserted - not
    /// which actor ran what, which is how the loop keeps the promise and not the promise.
    ///
    /// The run is the one that was reported from live use: a press says a sentence, and
    /// while that sentence is still being inserted the speaker starts the next utterance and
    /// presses the key again. The insert is held where a real one waits for the app to
    /// answer. Held at a gate rather than for a duration: a loop that only kept its words
    /// when the app answered fast enough would be the same bug wearing a stopwatch.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// What the second press needs is for its key-down to be handled while the insert is
    /// still running, because that is where the microphone opens now: a key-down queued
    /// behind the insert would open the microphone after the words it was pressed for had
    /// been said, and the clip would show it. Every sample of the second utterance is in
    /// the second clip and none of the first is, which is both halves of the promise.
    @Test func everyWordSpokenIntoAPressMadeDuringAnInsertIsInThatPressesClip() async throws {
        let sentence = "the quick brown fox jumps over the lazy dog"
        // Each press is spoken in a sample value of its own, so a clip says which press's
        // words it is holding and speech that landed in the wrong one cannot pass for the
        // right one. Nothing is spoken between them: the microphone is shut there, and a
        // test that fed it would be describing a Mac that does not exist.
        let said = [Float](repeating: 1, count: AudioClip.sampleCount(for: 0.5))
        let andThen = [Float](repeating: 2, count: AudioClip.sampleCount(for: 0.8))
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples.contains(1) ? sentence : "b") }
        let rig = try await Rig(hearing: engine)
        rig.inputMethod.hold()

        rig.hold(speaking: said)
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        #expect(rig.inputMethod.inserted.isEmpty)

        rig.hold(speaking: andThen)
        #expect(rig.inputMethod.inserted.isEmpty)

        rig.inputMethod.letGo()
        #expect(try await rig.session().transcription.transcript.text == sentence)
        #expect(try await rig.session().transcription.transcript.text == "b")
        #expect(engine.clips.map(\.samples) == [said, andThen])
        #expect(rig.inputMethod.inserted == [sentence, "b"])
    }

    @Test func aPressWithNothingToInsertIntoIsReportedAndTheNextPressInserts() async throws {
        let refused = Mutex(true)
        let rig = try await Rig(transcriber: { FakeTranscriber { _ in Transcript(typed: "a") } }) { () throws(FrontmostUnknown) in
            if refused.withLock({ $0 }) { throw .noFrontmostApp }
            return Rig.textEdit
        }
        rig.refusedHold()
        #expect(await rig.report().failure is FrontmostUnknown)
        refused.withLock { $0 = false }
        rig.hold()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["a"])
    }

    /// A press with nothing to insert into is refused at key-down, before anything is
    /// heard, so it is the one outcome that could be ready before an earlier press's.
    /// It waits its turn all the same: outcomes are reported in the order the presses
    /// came, whatever each one costs.
    @Test func aRefusedPressIsReportedAfterAnEarlierPressStillBeingHeard() async throws {
        let gate = Gate()
        let refusing = Mutex(false)
        let rig = try await Rig(transcriber: {
            FakeTranscriber { _ in
                await gate.wait()
                return Transcript(typed: "a")
            }
        }) { () throws(FrontmostUnknown) in
            if refusing.withLock({ $0 }) { throw .noFrontmostApp }
            return Rig.textEdit
        }
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        refusing.withLock { $0 = true }
        rig.refusedHold()
        gate.open()
        let first = await rig.report()
        let second = await rig.report()
        #expect(try first.get().transcription.transcript.text == "a")
        #expect(second.failure is FrontmostUnknown)
    }

    /// What the app awaits before it quits. A surface that went while a session was still in
    /// flight would lose words the speaker has already said. The session is held at the
    /// engine with nothing inserted yet, so a `finish` that did not wait is caught by the
    /// empty list of inserts - and by the report not having landed, which is the other half
    /// of what `finish` promises.
    @Test func finishReturnsOnlyAfterASessionStillInFlightHasInsertedAndBeenReported() async throws {
        let gate = Gate()
        let rig = try await Rig(transcriber: {
            FakeTranscriber { _ in
                await gate.wait()
                return Transcript(typed: "a")
            }
        })
        rig.hold()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(!rig.reported.raised)
        gate.open()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["a"])
        #expect(rig.reported.raised)
    }

    /// The other half of the same contract, at the loop: `press(.ended)` puts the session
    /// on the queue before it returns, so a `finish` with nothing awaited between it and
    /// the key-up is still owed that session's wait. What this pins is that guarantee, not
    /// the window it closed - after submission became synchronous there is no window left
    /// here to reach, and a test that claimed to reproduce one would be claiming more than
    /// it does. [LAW:behavior-not-structure]
    @Test func finishRightAfterAKeyUpWaitsForThatPressWithNothingAwaitedInBetween() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.hold()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["a"])
        #expect(rig.reported.raised)
    }

    /// The session's own line, which the app's log reads. Where the words went is read off
    /// what was performed, so the app the input method says it reached is named, and not the
    /// one that happened to be in front at key-down.
    @Test func aSessionsLineNamesTheAppTheWordsReachedNotTheOneInFront() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.inputMethod.reaching(BundleID(rawValue: "com.apple.Safari"))
        rig.hold()
        #expect(try await rig.session().description.hasSuffix("1 insert into com.apple.Safari"))
    }

    /// Each press is heard expecting the vocabulary of the mode whose chord began it, and its
    /// report names that mode: two modes pressed in turn, each decode told its own terms.
    @Test func aPressOnAModesChordDecodesExpectingThatModesTerms() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig(hearing: engine)
        rig.hold(in: Self.notes)
        let first = await rig.pressReport()
        #expect(first.mode == Self.notes)
        _ = try first.outcome.get()
        rig.hold()
        #expect(await rig.pressReport().mode == Rig.dictation)
        #expect(engine.expected == [Self.notes.vocabulary, .empty])
    }

    /// A press whose engine refused the mode's vocabulary is reported in that mode, so the
    /// record says whose terms to cut.
    @Test func aFailedPressIsReportedInTheModeItBeganIn() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ throws(TranscriptionFailure) in throw .vocabulary(.tooLong(tokens: 300, limit: 224)) })
        rig.hold(in: Self.notes)
        let report = await rig.pressReport()
        #expect(report.mode == Self.notes)
        #expect(throws: Dictation.Failed.self) { try report.outcome.get() }
    }

    private static let notes = Mode(name: "notes", chord: KeyChord(modifiers: .rightCommand),
                                    vocabulary: Vocabulary([try! Vocabulary.Term("Brynleigh Fryslie"), try! Vocabulary.Term("Kubernetes")]))

    /// Nothing said is a session that performed nothing, and a destination it never had
    /// is left unsaid rather than rendered as an empty one.
    @Test func aSessionThatPerformedNothingNamesNoDestination() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "") })
        rig.hold()
        #expect(try await rig.session().description.hasSuffix("0 inserts"))
    }

    @Test func anEngineThatFailsIsReportedAndTheNextPressInserts() async throws {
        let failing = Mutex(true)
        let rig = try await Rig(hearing: FakeTranscriber { _ throws(TranscriptionFailure) in
            if failing.withLock({ $0 }) { throw .engine(NoEngine()) }
            return Transcript(typed: "a")
        })
        rig.hold()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(engineFailed(stopped.cause, with: NoEngine.self))
        #expect(stopped.landed == 0)
        #expect(failureLine(stopped) == "Your last dictation was not placed: NoEngine().")
        failing.withLock { $0 = false }
        rig.hold()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["a"])
    }

    /// An input method that refuses stops the session with what was done, and the next press
    /// lands the refused words with its first insert, ahead of its own.
    @Test func aRefusedInsertIsReportedAndTheNextPressCarriesItsWords() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        let stopped = try #require(await rig.report().failure as? PressStopped)
        #expect(stopped.cause as? InsertFailure == .refused(.noTextFieldHasFocus))
        #expect(stopped.landed == 0)
        #expect(failureLine(stopped) == "\(Refusal.noTextFieldHasFocus)")
        rig.inputMethod.refusing(nil)
        rig.hold(speaking: [4])
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["a b"])
        #expect(rig.hold.held == nil)
    }

    /// Every way an insert can fail leaves the panel saying so, and keeps every word it
    /// carried. Words at no cursor wait for one to take them. Words that may have landed -
    /// handed to an app that had not taken them, or sent with no answer - are not offered
    /// to a cursor, since that is the one way to type them twice, and stand until the person
    /// places them with one ask or dismisses them.
    @Test(arguments: failedInserts)
    func aFailedInsertHoldsEveryWordItCarried(failed: FailedInsert) async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "hello there") })
        rig.inputMethod.refusing(failed.failure)
        rig.hold()
        #expect(try #require(await rig.report().failure as? PressStopped).landed == 0)
        let kept: Held = failed.mayHaveLanded
            ? .unaccounted(part("hello there", "\(failed.failure)")) : .unplaced(part("hello there", "\(failed.failure)"))
        #expect(rig.hold.held == kept)
        #expect(rig.store.kept == kept)
        rig.inputMethod.refusing(nil)
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == (failed.mayHaveLanded ? [] : ["hello there"]))
        #expect(rig.hold.held == (failed.mayHaveLanded ? kept : nil))
        rig.dictation.insertHeld()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["hello there"])
        #expect(rig.hold.held == nil)
        #expect(rig.store.kept == nil)
    }

    /// Words that may have landed are let go of when the person dismisses them.
    @Test(arguments: failedInserts.filter(\.mayHaveLanded))
    func wordsThatMayHaveLandedAreDismissed(failed: FailedInsert) async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "hello there") })
        rig.inputMethod.refusing(failed.failure)
        rig.hold()
        _ = await rig.report()
        rig.hold.dismiss()
        rig.inputMethod.refusing(nil)
        rig.dictation.insertHeld()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held == nil)
        #expect(rig.store.kept == nil)
    }

    /// Words held, then words of a press whose insert carrying both may have landed, all stand.
    @Test func anInsertThatMayHaveLandedKeepsTheHeldWordsItCarried() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        let notYetTaken = NotYetTaken(characters: 3, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold(speaking: [4])
        _ = await rig.report()
        #expect(rig.hold.held == .unaccounted(part("a b", "\(notYetTaken)")))
    }

    /// An ask whose insert is refused leaves every word as words no cursor took, which the next
    /// cursor is offered.
    @Test func anAskThatIsRefusedLeavesTheWordsForTheNextCursor() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.dictation.insertHeld()
        try await rig.dictation.finish()
        #expect(rig.hold.held == .unplaced(part("a", "\(Refusal.noTextFieldHasFocus)")))
        rig.inputMethod.refusing(nil)
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["a"])
        #expect(rig.hold.held == nil)
    }

    /// An ask made while an insert of the held words is on its way is taken in its own turn:
    /// that insert's landing does not settle the words that may have landed, which it never
    /// carried, and until it is answered the store still says they may have been typed.
    @Test func anAskDuringAnInsertPlacesWhatThatInsertDidNotCarry() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold(speaking: [4])
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        rig.inputMethod.hold()
        rig.dictation.cursorArrived()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.dictation.insertHeld()
        #expect(rig.store.kept == .unaccounted(part("a b", "LowTalker ended while inserting held words, so they may have been typed")))
        rig.inputMethod.letGo()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == [" b", "a"])
        #expect(rig.hold.held == nil)
        #expect(rig.store.kept == nil)
    }

    /// An ask made as a press begins is let go, and words that may have landed still stand for
    /// one made once it ends.
    @Test func anAskAsAPressBeginsIsLetGo() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([4])
        rig.dictation.insertHeld()
        rig.keyUp()
        _ = try await rig.session()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == [" b"])
        #expect(rig.hold.held == .unaccounted(part("a", "\(notYetTaken)")))
        rig.dictation.insertHeld()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == [" b", "a"])
    }

    /// An ask vouches for the words that may have landed as the person saw them: an insert
    /// queued ahead of it whose own words may have landed folds them in, and the ask is let go
    /// rather than type those a second time.
    @Test func anAskIsLetGoWhenWhatMayHaveLandedChangesBeforeItsTurn() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold(speaking: [4])
        _ = await rig.report()
        rig.inputMethod.hold()
        rig.dictation.cursorArrived()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.dictation.insertHeld()
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.inputMethod.letGo()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held == .unaccounted(part("a b", "\(notYetTaken)")))
    }

    /// A second ask made before the first is answered vouches for what the first set out to
    /// insert, so when the first's words may have landed, the second is let go and inserts
    /// nothing, though the same words stand under the same warning.
    @Test func anAskMadeAgainBeforeTheFirstIsAnsweredIsLetGo() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.hold()
        rig.dictation.insertHeld()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.dictation.insertHeld()
        rig.inputMethod.letGo()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.asked == 2)
        #expect(rig.hold.held == .unaccounted(part("a", "\(notYetTaken)")))
    }

    /// An ask let go places nothing, though by its turn words a cursor is offered are held:
    /// two asks queued behind an insert vouch for the same words, the first takes them, and
    /// when its insert is refused the words it carried wait for a cursor.
    @Test func anAskLetGoPlacesNothing() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        rig.inputMethod.refusing(.notYetTaken(NotYetTaken(characters: 1, into: "com.apple.TextEdit")))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold(speaking: [4])
        _ = await rig.report()
        rig.inputMethod.hold()
        rig.dictation.cursorArrived()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.dictation.insertHeld()
        rig.dictation.insertHeld()
        rig.inputMethod.letGo()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.asked == 4)
        #expect(rig.hold.held == .unplaced(part("a b", "\(Refusal.noTextFieldHasFocus)")))
    }

    /// Held words the person dismisses while an insert carrying only them is on its way stay
    /// dismissed when its answer says they may have landed: nothing is held, and no warning
    /// stands over nothing.
    @Test func wordsDismissedDuringAnInsertThatMayHaveLandedStayDismissed() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.notYetTaken(NotYetTaken(characters: 1, into: "com.apple.TextEdit")))
        rig.inputMethod.hold()
        rig.dictation.cursorArrived()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.hold.dismiss()
        rig.inputMethod.letGo()
        try await rig.dictation.finish()
        #expect(rig.hold.held == nil)
        #expect(rig.shown.held.last == .some(nil))
        #expect(rig.store.kept == nil)
    }

    /// Nothing said is no part of what is held.
    @Test func blankWordsAreNoPartOfTheHold() {
        #expect(Held.Part(words: Transcript(words: []), warning: "w") == nil)
        #expect(Held.Part(words: Transcript(typed: " "), warning: "w") == nil)
    }

    /// A cursor that arrives while a press is open offers it nothing: the press places what
    /// is held ahead of its own words, into the app those go to.
    @Test func aCursorArrivingDuringAPressLeavesTheHeldWordsToIt() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.dictation.cursorArrived()
        rig.speak([4])
        rig.keyUp()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == ["a b"])
    }

    /// Words dismissed are let go of: a cursor arriving after is offered nothing.
    @Test func dismissedWordsAreNotOffered() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.hold.dismiss()
        rig.inputMethod.refusing(nil)
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.shown.held == [nil, .unplaced(part("a", "\(Refusal.noTextFieldHasFocus)")), nil])
        #expect(rig.store.kept == nil)
    }

    /// Words dismissed while an insert carrying them is on its way stay dismissed when that
    /// insert fails: only its own words are held.
    @Test func wordsDismissedDuringAFailingInsertStayDismissed() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.hold()
        rig.hold(speaking: [4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.inputMethod.holding == 1 })
        rig.hold.dismiss()
        rig.inputMethod.letGo()
        _ = await rig.report()
        #expect(rig.hold.held == .unplaced(part(" b", "\(Refusal.noTextFieldHasFocus)")))
    }

    /// Words that may have landed are not accounted for by a later insert that lands: the
    /// warning stands until the person dismisses it.
    @Test func aLaterLandingLeavesWordsThatMayHaveLandedUnaccounted() async throws {
        let engine = FakeTranscriber(confirming: { samples in
            Transcript(typed: samples.count >= 4 ? "hello there" : samples.count >= 2 ? "hello" : "")
        }) { _ in Transcript(typed: "hello there friend") }
        let rig = try await Rig(hearing: engine)
        let notYetTaken = NotYetTaken(characters: 5, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.hold.held != nil })
        rig.inputMethod.refusing(nil)
        rig.speak([3, 4])
        rig.keyUp()
        _ = try await rig.session()
        #expect(rig.inputMethod.inserted == [" there", " friend"])
        #expect(rig.hold.held == .unaccounted(part("hello", "\(notYetTaken)")))
    }

    /// A later failure whose words went nowhere is held beside a warning that stands, and
    /// when its words land the warning still stands.
    @Test func aWarningThatStandsOutlivesALaterRefusalAndItsLanding() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [1, 2, 3] ? "a" : " b") })
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        rig.inputMethod.refusing(.notYetTaken(notYetTaken))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold(speaking: [4])
        _ = await rig.report()
        #expect(rig.hold.held == .unplaced(part(" b", "\(Refusal.noTextFieldHasFocus)"), unaccounted: part("a", "\(notYetTaken)")))
        #expect(rig.hold.held?.warnings == ["\(notYetTaken)", "\(Refusal.noTextFieldHasFocus)"])
        #expect(rig.hold.held?.allWords == Transcript(typed: "a b"))
        rig.inputMethod.refusing(nil)
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == [" b"])
        #expect(rig.hold.held == .unaccounted(part("a", "\(notYetTaken)")))
    }

    /// Words held when the app ends are held again at its next launch, and offered to the
    /// cursor that arrives first.
    @Test func wordsHeldWhenTheAppEndsAreOfferedAfterItsNextLaunch() async throws {
        let store = FakeHeldStore()
        let before = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") }, keeping: store)
        before.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        before.hold()
        _ = await before.report()
        let held = Held.unplaced(part("a", "\(Refusal.noTextFieldHasFocus)"))
        #expect(store.kept == held)
        let after = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: " b") }, keeping: store)
        #expect(after.shown.held == [held])
        after.dictation.cursorArrived()
        try await after.dictation.finish()
        #expect(after.inputMethod.inserted == ["a"])
        #expect(store.kept == nil)
    }

    /// A store that cannot be read at launch holds nothing, offers nothing, and says why.
    @Test func anUnreadableStoreHoldsNothingAndSaysWhy() async throws {
        let store = FakeHeldStore(keeping: .unplaced(part("a", "\(Refusal.noTextFieldHasFocus)")))
        let unreadable = HeldUnreadable(why: "torn", kept: .movedTo("/kept.json"))
        store.unreadable = unreadable
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "b") }, keeping: store)
        #expect(rig.hold.held == nil)
        #expect(rig.hold.unrestored == unreadable)
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted.isEmpty)
    }

    /// A write that fails is told and leaves what is held as it was, until a write succeeds.
    @Test func aFailedWriteIsToldAndTheWordsStayHeld() async throws {
        let store = FakeHeldStore()
        store.failing = .lost(why: "disk full")
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") }, keeping: store)
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        let held = Held.unplaced(part("a", "\(Refusal.noTextFieldHasFocus)"))
        #expect(rig.hold.held == held)
        #expect(rig.hold.unkept == .lost(why: "disk full"))
        #expect(rig.shown.unkept.contains(.lost(why: "disk full")))
        store.failing = nil
        rig.hold.dismiss()
        #expect(rig.hold.unkept == nil)
        #expect(store.written.last == .some(nil))
    }

    /// Held words that land while the write saying so fails are not offered after the next launch.
    @Test func wordsThatLandedWhileTheWriteFailedAreNotOfferedAgain() async throws {
        let store = FakeHeldStore()
        let before = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") }, keeping: store)
        before.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        before.hold()
        _ = await before.report()
        store.failing = .lost(why: "disk full")
        before.inputMethod.refusing(nil)
        before.dictation.cursorArrived()
        try await before.dictation.finish()
        #expect(before.inputMethod.inserted == ["a"])
        let after = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "b") }, keeping: store)
        #expect(after.hold.held == nil)
    }

    /// Held words handed to an app that may yet take them while the write saying so fails are
    /// not offered after the next launch, which would be the one way to type them twice.
    @Test func wordsThatMayHaveLandedWhileTheWriteFailedAreNotOfferedAgain() async throws {
        let store = FakeHeldStore()
        let before = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") }, keeping: store)
        before.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        before.hold()
        _ = await before.report()
        store.failing = .lost(why: "disk full")
        let notYetTaken = NotYetTaken(characters: 1, into: "com.apple.TextEdit")
        before.inputMethod.refusing(.notYetTaken(notYetTaken))
        before.dictation.cursorArrived()
        try await before.dictation.finish()
        #expect(before.hold.held == .unaccounted(part("a", "\(notYetTaken)")))
        let after = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "b") }, keeping: store)
        #expect(after.hold.held?.words.words.isEmpty ?? true)
    }

    /// Held words on their way to an app when the app ends are not offered after its next
    /// launch, since they may have been typed, and that launch says so and keeps them for the
    /// person to place.
    @Test func wordsOnTheirWayWhenTheAppEndsAreNotOfferedAgain() async throws {
        let store = FakeHeldStore()
        let before = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") }, keeping: store)
        before.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        before.hold()
        _ = await before.report()
        before.inputMethod.refusing(nil)
        before.inputMethod.hold()
        before.dictation.cursorArrived()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { before.inputMethod.holding == 1 })
        let after = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "b") }, keeping: store)
        #expect(after.hold.held == .unaccounted(part("a", "LowTalker ended while inserting held words, so they may have been typed")))
        after.dictation.cursorArrived()
        try await after.dictation.finish()
        #expect(after.inputMethod.inserted.isEmpty)
        after.dictation.insertHeld()
        try await after.dictation.finish()
        #expect(after.inputMethod.inserted == ["a"])
        before.inputMethod.letGo()
        try await before.dictation.finish()
    }

    /// Held words an insert is refused for again, as they were before, are still kept once it
    /// is answered, not left as words that may have been typed.
    @Test func heldWordsRefusedAgainAreStillKept() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.dictation.cursorArrived()
        try await rig.dictation.finish()
        #expect(rig.store.kept == .unplaced(part("a", "\(Refusal.noTextFieldHasFocus)")))
    }

    /// A cursor that arrives while a press is open is offered what is held once that press
    /// ends, when the press placed nothing of its own. What a lapsed press heard is held
    /// behind what was, so the offer carries both.
    @Test func aCursorArrivingDuringAPressThatLapsesIsOfferedTheHeldWordsAfterIt() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { clip in Transcript(typed: clip.samples == [4, 5] ? " b" : "a") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        rig.inputMethod.refusing(nil)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([4, 5])
        rig.dictation.cursorArrived()
        rig.dictation.press(.ended(.lapsed))
        #expect(await rig.report().failure is PressLapsed)
        try await rig.dictation.finish()
        #expect(rig.inputMethod.inserted == ["a b"])
        #expect(rig.hold.held == nil)
    }

    /// A failed press is reported by its kind and with its cause in the clear: as readable in
    /// the log as a dictation that happened.
    @Test func aFailedPressIsReportedByKindWithItsCauseInTheClear() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ throws(TranscriptionFailure) in throw .engine(NoEngine()) })
        rig.hold()
        guard case .failed(let failed) = await rig.report() else { Issue.record("expected the press to fail"); return }
        #expect(failed.kind == "PressStopped")
        #expect(failed.failure.account == Account(facts: "0 words inserted before: NoEngine()"))
    }

    /// The hold is the app's, not the loop's: a loop rebuilt over a new config offers what
    /// the old one could not place.
    @Test func heldWordsOutliveTheLoopThatHeldThem() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.inputMethod.refusing(.refused(.noTextFieldHasFocus))
        rig.hold()
        _ = await rig.report()
        try await rig.dictation.finish()
        let rebuilt = Dictation(
            capture: rig.capture, transcriber: { FakeTranscriber { _ in Transcript(typed: "") } }, turns: rig.turns,
            executor: Executor(insertingThrough: rig.inputMethod), hold: rig.hold, frontmost: { Rig.textEdit },
            report: { _ in }, showing: { _ in })
        rig.inputMethod.refusing(nil)
        rebuilt.cursorArrived()
        try await rebuilt.finish()
        #expect(rig.inputMethod.inserted == ["a"])
    }

    /// A press cut short while the model it is heard by is still loading waits for it, as a
    /// released one does: what it heard is what the hold keeps, so it is reported once heard.
    @Test func aPressCutShortWhileTheEngineLoadsWaitsForItAndHoldsWhatItHeard() async throws {
        let gate = Gate()
        let rig = try await Rig { await gate.wait(); return FakeTranscriber { _ in Transcript(typed: "a") } }
        rig.lapse()
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { gate.waiting == 1 })
        #expect(!rig.reported.raised)
        gate.open()
        let lapsed = try #require(await rig.report().failure as? PressLapsed)
        #expect(lapsed.held == 1)
        #expect(rig.hold.held?.words == Transcript(typed: "a"))
    }

    /// The app quits, or is sent SIGTERM, mid-press: the hotkey comes down, which lapses the
    /// press, and the quit waits on `finish`. By the time it returns, what the press heard is
    /// in the store the next launch reads.
    @Test func aPressCutShortByAQuitLeavesItsWordsInTheStore() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.lapse(speaking: [1, 2, 3])
        try await rig.dictation.finish()
        #expect(rig.store.kept == .unplaced(part("a", "WARNING: The hotkey stopped listening during your dictation.")))
    }

    /// The chord was a typed key's modifier - Return pressed to send before letting go: the
    /// press inserts nothing more and is reported as what it was rather than as a failure,
    /// and everything it heard is held, from the whole of its audio.
    @Test func aPressUsedAsAModifierHoldsWhatItHeardAndIsNoFailure() async throws {
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples == [4, 5] ? " b" : "a") }
        let rig = try await Rig(hearing: engine)
        rig.usedAsModifier(speaking: [1, 2, 3])
        guard case .usedAsModifier(let landed, let held) = await rig.report() else { Issue.record("expected a press used as a modifier"); return }
        #expect(landed == 0)
        #expect(held == 1)
        #expect(engine.clips.first?.samples == [1, 2, 3])
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held == .unplaced(part("a", "WARNING: You typed a key while holding the dictation chord.")))
        rig.hold(speaking: [4, 5])
        #expect(try await rig.session().transcription.transcript.text == " b")
        #expect(rig.inputMethod.inserted == ["a b"])
    }

    /// A chord used as a modifier with nothing said into it is a typed key and nothing else:
    /// no failure, and nothing held.
    @Test func aChordUsedAsAModifierWithNothingSaidHoldsNothing() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ throws(TranscriptionFailure) in
            throw .nothingSpoken(peak: 0, quiet: Quiet(letGo: 0, room: nil, refusedAsRoom: 0, transients: .none))
        })
        rig.usedAsModifier(speaking: [0, 0, 0])
        guard case .usedAsModifier(let landed, let held) = await rig.report() else { Issue.record("expected a press used as a modifier"); return }
        #expect(landed == 0 && held == 0)
        #expect(rig.hold.held == nil)
    }

    /// [LAW:no-silent-failure] Two presses the speaker made identically, told apart by
    /// nothing but how listening stopped. The hotkey stops partway through the first, so
    /// what it captured runs to the stop and not to the release: it is reported as lapsed
    /// and held rather than inserted, because a fragment inserted into the user's editor
    /// arrives unmarked as a fragment and cannot be marked there. The second is released
    /// and inserts, carrying the held words ahead of its own.
    @Test func aPressTheHotkeyLapsedOutOfIsHeldAndTheNextPressCarriesIt() async throws {
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples == [4, 5] ? " b" : "a") }
        let rig = try await Rig(hearing: engine)

        rig.lapse(speaking: [1, 2, 3])
        let lapsed = try #require(await rig.report().failure as? PressLapsed)
        #expect("\(lapsed)" == "WARNING: The hotkey stopped listening during your dictation. Its 1 words are held.")
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held?.words == Transcript(typed: "a"))

        rig.hold(speaking: [4, 5])
        #expect(try await rig.session().transcription.transcript.text == " b")
        #expect(rig.inputMethod.inserted == ["a b"])
    }

    /// The speaker held the key for longer than the ring retains. The ring overwrote the
    /// first of what was said with the last of it, but the engine had already heard every
    /// buffer as it landed, so the press is whole and inserts.
    @Test func aPressLongerThanTheRingRetainsIsHeardWholeAndInserts() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig(hearing: engine, retaining: 0.5)
        let said = [Float](repeating: 1, count: AudioClip.sampleCount(for: 0.8))
        rig.hold(speaking: said)
        #expect(try await rig.session().transcription.transcript.text == "a")
        #expect(engine.clips.last?.samples == said)
        #expect(rig.inputMethod.inserted == ["a"])
    }

    /// [LAW:no-silent-failure] The input device changed in the middle of a press - AirPods
    /// connecting mid-sentence, the everyday case. macOS stops the engine and capture
    /// launches a new one on the new device, and the speech in between is not captured by
    /// either. What the ring holds is the words before the change butted straight against
    /// the words after it, with nothing in the samples marking the join: ring positions
    /// advance only on capture, so the stretch that was lost left nothing behind, not even
    /// a hole. The audio on both sides is heard, and what it reads is held beside the loss
    /// rather than inserted, because what a splice transcribes to is a sentence - just not
    /// the one that was said.
    @Test func aPressTheInputDeviceChangedDuringIsHeardAcrossTheGapAndHeld() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig(hearing: engine)

        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        rig.changeDevice()
        rig.speak([3, 4])
        rig.keyUp()

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.interrupted)
        #expect(press.lost.scrolledOff == 0)
        #expect(press.held == 1)
        #expect(engine.clips.first?.samples == [1, 2, 3, 4])
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held == .unplaced(part("a", "WARNING: Your microphone restarted while you were dictating.")))

        // The next press is whole: it opens a microphone of its own and reaches back over
        // nothing, so the seam is behind it however close to it the key went down.
        rig.hold(speaking: [5, 6])
        #expect(try await rig.session().transcription.transcript.text == "a")
        #expect(engine.clips.last?.samples == [5, 6])
    }

    /// A device change that really took time is still only a splice: the head of the press
    /// was captured, so what it lost is its middle and nothing else.
    ///
    /// The reconnect is what the other splice tests leave out. They stamp the audio either
    /// side of the change as if no time passed, and a press that loses a third of a second
    /// to AirPods is the everyday shape of one. The distinction matters because the two
    /// losses are different sentences: this press is spliced, and telling its speaker the
    /// microphone was not open for it would be false - it was open, on time, and heard the
    /// first word.
    @Test func aPressSplicedAcrossARealReconnectIsNotAlsoReportedAsUnopened() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig(hearing: engine)

        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        rig.changeDevice()
        // The outage itself: real time in which no engine is running, so nothing is
        // captured over it and the positions either side of it are adjacent.
        rig.wait(0.3)
        rig.speak([3, 4])
        rig.keyUp()

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.interrupted)
        #expect(!press.lost.unopened)
        #expect(press.lost.scrolledOff == 0)
        #expect(press.lost.description == "Your microphone restarted while you were dictating")
    }

    /// [LAW:no-silent-failure] There is no microphone to open - the device cannot feed the
    /// pipeline - so the press is refused at the key and reported. A loop that carried on
    /// would hand the engine the empty clip a shut microphone leaves behind, and an empty
    /// clip transcribes exactly like a quiet room.
    ///
    /// The press is made without speaking into it, because there is nothing to speak into:
    /// with the microphone opening per press, a capture with no working device has no
    /// engine at all rather than a failed one.
    @Test func aPressWithNoMicrophoneToOpenIsReportedNotHeardAsSilence() async throws {
        let engine = FakeTranscriber { _ in Transcript(typed: "a") }
        let rig = try await Rig(hearing: engine)
        rig.hardware.failingToLaunch = BadBuffer()
        rig.refusedHold()
        let failure = try #require(await rig.report().failure as? NoMicrophone)
        guard case .failed(let error) = failure else { Issue.record("expected the capture's failure, got \(failure)"); return }
        #expect(error is BadBuffer)
        #expect(engine.clips.isEmpty)

        // The device comes back, and the next press opens a microphone and inserts.
        rig.hardware.failingToLaunch = nil
        rig.hold(speaking: [1, 2])
        #expect(try await rig.session().transcription.transcript.text == "a")
        #expect(rig.inputMethod.inserted == ["a"])
    }

    // MARK: - what a press's microphone delivered

    /// [LAW:nothing-unseen] Every press's report carries what its microphone delivered, so a
    /// press that was heard says through which input, how much and how loud.
    @Test func aHeardPressReportsWhatItsMicrophoneDelivered() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.hold(speaking: [0.5, -0.25])
        let report = await rig.pressReport()
        #expect(try report.outcome.get().transcription.transcript.text == "a")
        #expect(report.capture == CapturedAudio.Reading(inputs: [FakeHardware.microphone], samples: 2, peak: 0.5, firstSample: .zero))
        #expect(report.microphone == "\"Fake Microphone\" (device 1, 48000 Hz, 1 channel) delivered 0.0 s (2 samples) peaking at -6.0 dBFS, the first 0 ms after the key went down")
    }

    /// The press the ticket was filed for: the microphone opened and delivered nothing, and
    /// the record says so beside the refusal, rather than leaving nothing to read.
    @Test func aPressWhoseMicrophoneDeliveredNothingReportsItWithTheLoss() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.refusedHold()
        let report = await rig.pressReport()
        let lost = try #require(report.outcome.failure as? SpeechLost)
        #expect(lost.lost.unopened)
        #expect(report.capture == CapturedAudio.Reading(inputs: [FakeHardware.microphone], samples: 0, peak: 0, firstSample: nil))
        #expect(report.microphone == "\"Fake Microphone\" (device 1, 48000 Hz, 1 channel) delivered nothing after the key went down")
    }

    /// A press refused before any microphone opened has no reading, and its record says that
    /// beside the reason it was refused.
    @Test func aPressRefusedBeforeItsMicrophoneOpenedReportsNoReading() async throws {
        let rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
        rig.hardware.failingToLaunch = BadBuffer()
        rig.refusedHold()
        let report = await rig.pressReport()
        #expect(report.outcome.failure is NoMicrophone)
        #expect(report.capture == nil)
        #expect(report.microphone == "no microphone opened for it")
    }

    /// [LAW:no-silent-failure] The engine failed under an open press - a driver going down
    /// mid-sentence, with no device change and nothing to recover onto before the key came
    /// up. The microphone was gone for the tail of the press, so what the ring holds ends
    /// somewhere inside the sentence, and a fragment that transcribes fluently is the one
    /// thing that must not be inserted: what was heard before the failure is held instead.
    ///
    /// This is the door the loop's own `.stopped`/`.failed` branches used to hold open.
    /// They are gone: a press that lost its microphone is held because its audio comes back
    /// partial, the same as any other loss, so the report rests entirely on capture marking
    /// it - which is what this press checks.
    @Test func aPressWhoseMicrophoneFailedMidHoldIsHeldInsteadOfInserted() async throws {
        let engine = FakeTranscriber { clip in Transcript(typed: clip.samples == [3, 4] ? " b" : "a") }
        let rig = try await Rig(hearing: engine)

        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1, 2])
        rig.hardware.live.onFailure(BadBuffer())
        rig.keyUp()

        let press = try #require(await rig.report().failure as? SpeechLost)
        #expect(press.lost.unopened)
        #expect(!press.lost.interrupted)
        #expect(press.held == 1)
        #expect(rig.inputMethod.inserted.isEmpty)
        #expect(rig.hold.held?.words == Transcript(typed: "a"))

        // The failed engine was let go with the press, so the next one opens a microphone
        // of its own rather than finding capture wedged on the engine that died.
        rig.hold(speaking: [3, 4])
        #expect(try await rig.session().transcription.transcript.text == " b")
        #expect(rig.inputMethod.inserted == ["a b"])
    }

    /// The status item's activity: listening from key-down, transcribing from key-up, and
    /// idle once the outcome is reported, never before it.
    @Test func aPressShowsListeningThenTranscribingThenIdleOnceReported() async throws {
        let gate = Gate()
        let rig = try await Rig(hearing: FakeTranscriber { _ in await gate.wait(); return Transcript(typed: "a") })
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: []))])
        rig.speak([1, 2, 3])
        rig.keyUp()
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: [])), .transcribing])
        gate.open()
        _ = try await rig.session()
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: [])), .transcribing, .idle])
    }

    /// While the key is down, what the press's passes read is shown as they read it, and a
    /// pass that rereads the same words, however it times them, shows nothing again.
    @Test func aPressShowsWhatItsPassesReadWhileTheKeyIsDown() async throws {
        let engine = FakeTranscriber(reading: { heard in
            heard.count < 2 ? Transcript(words: [])
                : Transcript(words: [.init(text: " hello", time: 0...Double(heard.count), confidence: 0.9)])
        }) { _ in Transcript(typed: "hello") }
        let rig = try await Rig(hearing: engine)
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        rig.speak([1])
        rig.speak([2])
        rig.speak([3])
        rig.speak([4])
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { engine.hearing == [1, 2, 3, 4] })
        #expect(try await holds(within: .seconds(10), askingEvery: .milliseconds(2)) { rig.shown.activities.last == .listening(heard: Transcript(typed: " hello")) })
        rig.keyUp()
        _ = try await rig.session()
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: [])), .listening(heard: Transcript(typed: " hello")), .transcribing, .idle])
    }

    /// A press refused its microphone is never shown as listening, and its failure, once
    /// reported, leaves the loop idle.
    @Test func aRefusedPressIsNeverShownListening() async throws {
        let rig = try await Rig(transcriber: { FakeTranscriber { _ in Transcript(typed: "a") } }) { () throws(FrontmostUnknown) in throw .noFrontmostApp }
        rig.refusedHold()
        #expect(await rig.report().failure is FrontmostUnknown)
        #expect(rig.shown.activities == [.transcribing, .idle])
    }

    /// A press made while an earlier one is still on its way is shown listening, and the
    /// loop stays transcribing until the last outcome is reported.
    @Test func thePressBeingSpokenIsShownOverOneStillOnItsWay() async throws {
        let gate = Gate()
        let rig = try await Rig(hearing: FakeTranscriber { _ in await gate.wait(); return Transcript(typed: "a") })
        rig.hold()
        rig.dictation.press(.began(Rig.dictation, at: rig.now))
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: [])), .transcribing, .listening(heard: Transcript(words: []))])
        rig.speak([4, 5])
        rig.keyUp()
        gate.open()
        _ = try await rig.session()
        _ = try await rig.session()
        #expect(rig.shown.activities == [.listening(heard: Transcript(words: [])), .transcribing, .listening(heard: Transcript(words: [])), .transcribing, .idle])
    }

    /// An activity logs without the words it carries, counting them as the transcript does.
    @Test func anActivityDescribesItselfWithoutTheWords() {
        #expect("\(Dictation.Activity.listening(heard: Transcript(typed: "hello there")))" == "listening, 2 words heard")
        #expect("\(Dictation.Activity.transcribing)" == "transcribing")
    }

    /// The icon is the press's while there is one and the engine's otherwise, except that a
    /// press ended before the engine is ready shows the wait it is in.

    @Test func theIconIsTheActivityOverTheEnginesReadiness() {
        let ready = EngineReadiness.ready(.default, after: .seconds(2))
        let preparing = EngineReadiness.preparing(.loading, since: .now)
        let failed = EngineReadiness.failed("no model")
        #expect(Dictation.Activity.idle.glyph(over: failed) == failed.statusGlyph())
        #expect(Dictation.Activity.idle.iconDescription(for: "L", over: failed) == failed.iconDescription(for: "L"))
        #expect(Dictation.Activity.listening(heard: Transcript(typed: "hi")).glyph(over: failed) == .symbol("waveform"))
        #expect(Dictation.Activity.listening(heard: Transcript(typed: "hi")).iconDescription(for: "L", over: preparing) == "L: listening")
        #expect(Dictation.Activity.transcribing.glyph(over: ready) == .symbol("text.cursor"))
        #expect(Dictation.Activity.transcribing.iconDescription(for: "L", over: ready) == "L: transcribing")
        #expect(Dictation.Activity.transcribing.glyph(over: preparing) == .symbol("hourglass"))
        #expect(Dictation.Activity.transcribing.iconDescription(for: "L", over: preparing) == "L: preparing the model")
        #expect(Dictation.Activity.transcribing.glyph(over: failed) == failed.statusGlyph())
    }
}
