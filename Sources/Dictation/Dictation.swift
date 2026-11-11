import Foundation
import GrammaticalNumber
import Insertion
import LowTalkerCore
import Synchronization

/// The loop from a press of the hotkey to words at the cursor: key-down opens the microphone,
/// marking where the utterance begins on the ring, and the engine starts hearing it as it is
/// captured, committing words at the cursor as they are confirmed; key-up ends it and closes
/// the microphone again; and the rest of the transcript is inserted while the next press can
/// already begin.
///
/// [LAW:decomposition] Presses in, sessions out. The microphone, the engine and the
/// input method are values it is given, so the whole loop runs in a test
/// against a fake of each and the app's delegate only hands over the real ones. The
/// hotkey is not among them: it is fed `press`, and what starts it is not this loop's
/// concern. [LAW:composability]
///
/// [LAW:no-ambient-temporal-coupling] The engine hears each press after the press before
/// it, and each press's commits and its session are inserted on one serial queue, so two
/// presses in quick succession insert in the order they were spoken and never interleave,
/// however long the engine takes on either. Key-down and key-up reach this from the main queue, as the hotkey
/// hands them on.
///
/// With the microphone shut at rest, audio before the engine launches does not exist, so
/// a later launch is a longer head the microphone was not open for, and `beginSession`
/// reports that head. Held open at rest there is nothing to launch and the press is a mark
/// on a ring that is already turning. A press carries the moment its key went down and the
/// ring is read from there, so nothing already recorded is lost by arriving late. Sessions
/// are inserted on this same actor, so the insert awaits the input method's answer rather
/// than holding the actor for it: a press made in the middle of an insert is marked on the
/// ring when it is made.
@MainActor
public final class Dictation {
    /// One press the speaker ended, done: where it went, what was heard, how long after
    /// key-up, and what was inserted. An utterance with nothing said in it is a session
    /// that performed nothing, not a failure.
    ///
    /// [LAW:types-are-the-program] A press the hotkey stopped during never reaches one of
    /// these, and neither does one whose audio the ring could not hand over whole; those
    /// are reported as stopped by `PressLapsed` and `SpeechLost`. What is left is the press this
    /// type says it is: one the speaker ended, heard from every sample it covered.
    public struct Session: Sendable, CustomStringConvertible {
        public let press: PressKind
        public let transcription: Transcription
        /// From the key coming up to the transcript: `keyUpDelivery`, then the engine's share.
        public let keyUpToTranscript: Duration
        /// From the key coming up to this loop being told it had: the input method's hop to
        /// the app and the main queue's wait behind it, which `keyUpToTranscript` includes.
        public let keyUpDelivery: Duration
        /// What the press's hold put off of the engine's served callers.
        public let displaced: EngineHold.Displaced
        public let performed: [Executor.Performed]
        /// The words in its inserts that may have landed, which stand in the hold.
        public let standing: Int

        /// The session in numbers, without the words: they are what the user
        /// dictated, and each surface decides for itself whether to show them.
        /// [LAW:one-source-of-truth] The app's log line is this, and
        /// where the words went is read off what was performed rather than off the app
        /// that happened to be in front at key-down: the person may have moved before the
        /// first words were ready. Every insert after the first goes only to the app the first
        /// went to, so the first names the one app all of them went to.
        public var description: String {
            let destination = performed.first.map { " into \($0.into.rawValue)" } ?? ""
            let quiet = transcription.quiet
            let room = quiet.room.map { String(format: "%.1f dBFS", 20 * log10($0)) } ?? "none heard"
            return "heard \(counted(transcription.transcript.words.count, "word", "words")) in a \(press) past \(String(format: "%.1f", quiet.letGo)) s of quiet (room \(room), \(String(format: "%.1f", quiet.refusedAsRoom)) s refused as room, \(counted(quiet.transients.count, "transient", "transients")) refused, the longest sounding \(String(format: "%.2f", quiet.transients.longest)) s) \(Int(keyUpToTranscript / .milliseconds(1))) ms after key-up (delivered \(Int(keyUpDelivery / .milliseconds(1))) ms after it; \(displaced)), \(counted(performed.count, "insert", "inserts"))\(destination), \(counted(standing, "word that may have been inserted", "words that may have been inserted"))"
        }
    }

    /// One press, done: how it came out, what it showed while the key was down, and what its
    /// microphone delivered for it.
    ///
    /// [LAW:nothing-unseen] Every press reaches `report` as one of these, in the order the
    /// presses came, whether it was inserted, refused, heard nothing, or was never dictation:
    /// the record of a press that captured nothing says which input it was, how much arrived
    /// and how loud, so the record alone says why.
    public struct Report: Sendable {
        /// How a press came out.
        ///
        /// [LAW:types-are-the-program] A press that was never dictation is neither a session
        /// nor a failure: nothing went wrong, and nobody is told anything went wrong.
        public enum Outcome: Sendable {
            case session(Session)
            /// The chord was a typed key's modifier, so the press was never dictation and
            /// nothing heard past its inserts is held or shown. `landed` is how many of its words were committed
            /// while the chord was down, `standing` how many are in its inserts that may have
            /// landed, and `discarded` how many heard after them were dropped.
            case usedAsModifier(landed: Int, standing: Int, discarded: Int)
            /// The person threw the press away with Escape: what it put at the cursor was taken
            /// back and nothing of it is held, offered or shown. A press whose words could not all
            /// be taken back is `failed` instead, as `CancelLeftWords`.
            case cancelled(Cancelled)
            case failed(Failed)
        }

        /// The mode whose chord began the press, whatever came of it.
        public let mode: Mode
        public let outcome: Outcome
        /// Nil for a press refused before a microphone opened for it, which its outcome
        /// says the reason for.
        public let opened: Opened?

        /// A press the microphone opened for: what it showed while the key was down, the passes
        /// the engine failed to read once its decode was over, none when it read every one, and
        /// what the microphone delivered for it.
        public struct Opened: Sendable {
            public let duringPress: DuringPress
            public let unread: Partial.Unread?
            public let capture: CapturedAudio.Reading
        }

        /// What the microphone delivered, as the press's record says it.
        public var microphone: String {
            opened.map { "\($0.capture)" } ?? "no microphone opened for it"
        }

        /// [LAW:nothing-unseen] What the press's line says however the press came out: what it
        /// showed while the key was down, the passes the engine failed to read, so a press that
        /// failed counts them as one inserted does, and what its microphone delivered. A failure
        /// is told by its facts alone: a reading's failure can carry the words.
        public var record: String {
            let microphone = "microphone: \(self.microphone)"
            return opened.map { opened in
                let unread = opened.unread.map { "\(counted($0.passes, "pass", "passes")) the engine failed to read, the latest as \($0.latest.account.facts)" } ?? "0 passes the engine failed to read"
                return "\(opened.duringPress), \(unread); \(microphone)"
            } ?? microphone
        }
    }

    /// What a press showed while the key was still down: the passes its decode had run, how
    /// long after the key went down the first of them read any words, and the confirmed
    /// words already committed at the cursor.
    public struct DuringPress: Sendable, CustomStringConvertible {
        public let passes: Int
        /// Passes that changed the punctuation of a word two passes had agreed on.
        public let repunctuated: Int
        /// [LAW:types-are-the-program] Absent when no pass before key-up read a word,
        /// which a short tap or a slow engine leaves - not a zero, which would say the
        /// words were there at once.
        public let firstWords: Duration?
        /// The inserts acknowledged before key-up, and the words they carried.
        public let commits: Int
        public let wordsCommitted: Int
        /// Absent when nothing was committed before key-up, for the reason `firstWords` is.
        public let firstCommit: Duration?

        public var description: String {
            let words = firstWords.map { "first words \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "no words before key-up"
            let committed = firstCommit.map { "\(counted(commits, "commit", "commits")) of \(counted(wordsCommitted, "word", "words")), the first \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "nothing committed before key-up"
            return "\(counted(passes, "pass", "passes")) during the press, \(repunctuated) repunctuating a settled word, \(words), \(committed)"
        }
    }

    /// One press as its decode unfolds: the partials counted as they come, the confirmed
    /// words handed out as runs to commit while the press is open, and what landed.
    ///
    /// What the press showed is read once, at key-up: a pass or a commit that ends after it
    /// changes nothing that is read again.
    private final class Streaming: Sendable {
        /// The confirmed words not yet handed out.
        struct Run {
            let words: Transcript
            let since: Executor.Since
        }

        /// How the press ended. [LAW:types-are-the-program] A lapse ends the press with no
        /// key-up, and a chord that was a typed key's modifier with nothing to time from one,
        /// so "over" and "when the key came up" are not one optional.
        enum Ended {
            case up(ContinuousClock.Instant)
            /// Over, committing nothing more: a lapse, or a chord used as a modifier.
            case stopped
        }

        private struct State {
            var passes = 0
            /// What the latest pass read, nothing before the first.
            var partial = Partial(confirmed: Transcript(words: []), tentative: Transcript(words: []), repunctuated: 0, unread: nil)
            var firstWords: Duration?
            /// Nil while the key is down.
            var ended: Ended?
            var cursor = ConfirmedCursor()
            /// False once the press stops committing.
            var committing = true
            /// The capture's reading of what the press's audio already lacks: nil until the
            /// microphone is open, and for a press refused before it was.
            var missing: (@MainActor @Sendable () -> CapturedAudio.Loss?)?
            var performed: [Executor.Performed] = []
            var words = 0
            var provenance = Provenance()
        }

        /// What the press knows of its own words, from facts recorded as each insert is made, so
        /// that cancelling it can take back exactly what it put at the cursor and let go exactly
        /// what it failed to put there, and nothing a person said before it began.
        ///
        /// [LAW:one-source-of-truth] Counts read off the hold and the inserts, never comparisons of
        /// words or text: two words that read the same are not the same word, and a count is what
        /// the hold said at the moment. Only this press's loop adds to the hold's offered part
        /// while the press is open, and dismissal and landing remove the whole part, so the offered
        /// part is `pre` earlier words then `own` of this press's that failed, or nothing.
        struct Provenance: Sendable {
            /// The offered part when the press's turn began: earlier dictation a failed insert held.
            var preexisting: Held.Part?
            /// How many of the offered words are still that earlier dictation.
            var pre = 0
            /// How many of the offered words are this press's own, failed without landing.
            var own = 0
            /// The press's own words that landed, as the text the field holds, and how many.
            var landedText = ""
            var landedWords = 0
            /// Earlier words an insert of the press carried into the field: delivered, not the press's.
            var earlierWordsLanded = 0
            /// Words in inserts that may have landed, the press's own and the earlier ones they
            /// carried: the hold stands them, as it does for any such insert.
            var standingWords = 0

            /// What the hold would keep of its offered part if the press were cancelled now.
            var keeping: Held.Part? { pre > 0 ? preexisting : nil }

            /// `run` of the press's words are at no cursor, and the hold now offers `offered`. When
            /// the offered part is not what the press knew of it and those, the person dismissed it
            /// meanwhile, and the hold rebuilt it of the press's words alone.
            mutating func held(_ run: Int, offered: Int) {
                if offered == pre + own + run {
                    own += run
                } else {
                    pre = 0
                    own = offered
                }
            }

            /// How many of the `offered` words the hold offers are the press's own: `own` while the
            /// offered part is the `pre` earlier words and those, and every one once a dismissal or a
            /// landing removed that part, since only the press's loop adds to it while it is open.
            /// Earlier words no insert of the press carried are no part of its account.
            func ownOffered(of offered: Int) -> Int { offered == pre + own ? own : offered }
        }

        /// [LAW:one-source-of-truth] The key event's own stamp, on the clock every insert is
        /// timed by: a key-down told late is timed from where the key went down, by every
        /// line that times from it.
        private let keyDown: ContinuousClock.Instant
        private let state: Mutex<State>
        private let wake: AsyncStream<Void>.Continuation
        /// A wake for each pass, which may or may not have confirmed more words; ends when no
        /// more can come. The newest is all that is kept, since each run takes every word
        /// confirmed so far.
        let wakes: AsyncStream<Void>
        private let read: AsyncStream<Void>.Continuation
        /// A wake for each pass, for whoever shows what the press has read; ends with `wakes`.
        let reads: AsyncStream<Void>

        init(since keyDown: HostTime) {
            self.keyDown = ContinuousClock.Instant(keyDown)
            state = Mutex(State())
            (wakes, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            (reads, read) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        /// Everything the latest pass read, confirmed then tentative.
        var reading: Transcript {
            state.withLock { $0.partial.reading }
        }

        /// The passes the engine failed to read so far. Unlike what the press showed, read when
        /// asked: a pass the key came up during is a pass the decode ran for the press.
        var unread: Partial.Unread? {
            state.withLock { $0.partial.unread }
        }

        /// The text the latest pass read, without its timings: a pass that rereads the same
        /// words has read nothing new.
        var heard: Transcript {
            Transcript(typed: state.withLock { $0.partial.text })
        }

        /// The microphone is open, and `missing` reads what its audio already lacks.
        func hearing(missing: @escaping @MainActor @Sendable () -> CapturedAudio.Loss?) {
            state.withLock { $0.missing = missing }
        }

        func heard(_ partial: Partial) {
            let now = ContinuousClock.now
            state.withLock { state in
                state.passes += 1
                state.firstWords = state.firstWords ?? (partial.text.isEmpty ? nil : now - keyDown)
                state.partial = partial
            }
            wake.yield()
            read.yield()
        }

        /// The decode is over: nothing more is confirmed. What the transcript adds past the
        /// confirmed words is `rest`'s.
        func decoded() {
            wake.finish()
            read.finish()
        }

        /// The words confirmed since the last run, which are now this run's, or no run when
        /// nothing was said in them. [LAW:types-are-the-program] A pass need not confirm
        /// anything, and a wake can find its words already taken by the run before it; neither
        /// is a run, so the words held for the next run are never inserted on their own.
        ///
        /// While the key is down, audio the capture already knows is missing stops the
        /// commits: what is confirmed from then on reads a fragment, which is still heard and
        /// held at key-up with the loss beside it. From key-up on, how the press ended says.
        /// [LAW:no-silent-failure] An insert that fails stops nothing: its words are held, and
        /// the next run carries them.
        @MainActor func take() -> Run? {
            let missing = state.withLock { state -> (@MainActor @Sendable () -> CapturedAudio.Loss?)? in
                switch state.ended {
                case nil: state.missing
                case .up, .stopped: nil
                }
            }
            if let missing, missing() != nil { stop() }
            return state.withLock { state in
                // A stopped press commits nothing more, so the key-down it is timed from is moot.
                let since: Executor.Since = switch state.ended {
                case .up(let keyUp): .keyUp(keyUp)
                case nil, .stopped: .keyDown(keyDown)
                }
                // A stopped press takes no words, so it has no run.
                let run = state.cursor.advance(through: state.committing ? state.partial.confirmed.words : [])
                // [LAW:one-source-of-truth] Nothing said is the transcript's test, the one the
                // executor refuses an insert by.
                return run.isBlank ? nil : Run(words: run, since: since)
            }
        }

        /// What the transcript holds past every word already handed out as a run.
        func rest(of transcript: Transcript) -> Transcript {
            state.withLock { $0.cursor.advance(through: transcript.words) }
        }

        /// The press's turn on the queue begins, with `preexisting` the part the hold offers: whatever
        /// earlier presses left held, which every insert of the press carries ahead of its own.
        func began(offering preexisting: Held.Part?) {
            state.withLock { state in
                state.provenance.preexisting = preexisting
                state.provenance.pre = preexisting?.words.words.count ?? 0
            }
        }

        /// An insert is about to be made with `carried` words offered by the hold, read in the same
        /// step: the earlier words still held are what is left of `pre`, and the rest are the press's
        /// own. A hold that offers nothing means the earlier words were dismissed or landed.
        func sending(carried: Int) {
            state.withLock { state in
                state.provenance.pre = min(state.provenance.pre, carried)
                state.provenance.own = carried - state.provenance.pre
            }
        }

        /// An insert landed at the cursor, carrying `placed.words`. What it carried ahead of the
        /// press's own words, the `pre` earlier ones, is delivered earlier dictation, and the rest is
        /// the press's, which is what it would take back. Everything the hold offered has landed.
        func landed(_ placed: Placed) {
            state.withLock { state in
                if let performed = placed.performed {
                    state.performed.append(performed)
                    let earlier = min(state.provenance.pre, placed.offered.words.count)
                    let own = placed.offered.words.dropFirst(earlier)
                    state.provenance.landedText += own.map(\.text).joined()
                    state.provenance.landedWords += own.count
                    state.provenance.earlierWordsLanded += earlier
                    state.provenance.pre = 0
                    state.provenance.own = 0
                }
                state.words += placed.words
            }
        }

        /// An insert of `run` words failed. When it cannot have landed its words are in the hold
        /// beside what it carried, and the count the hold offers now, `offered`, is read in the same
        /// step: it says whether the person dismissed what the insert carried while it was in the
        /// air, which the hold then rebuilt its offered part without. When it may have landed they
        /// stand, and the offered part is whatever the hold made of it.
        func failed(run: Int, mayHaveLanded: Bool, offered: Int) {
            state.withLock { state in
                if mayHaveLanded {
                    // The insert covers everything it carried, so the words held before it stand too.
                    state.provenance.standingWords += state.provenance.pre + state.provenance.own + run
                    state.provenance.pre = 0
                    state.provenance.own = 0
                } else {
                    state.provenance.held(run, offered: offered)
                }
            }
        }

        /// `run` words the press heard and never sent are held, and the hold now offers `offered`.
        func heldBack(run: Int, offered: Int) {
            state.withLock { $0.provenance.held(run, offered: offered) }
        }

        /// What this press knows of its own words.
        var provenance: Provenance {
            state.withLock { $0.provenance }
        }

        /// The inserts that landed, and the words they carried.
        var landed: (performed: [Executor.Performed], words: Int) {
            state.withLock { ($0.performed, $0.words) }
        }

        /// Nothing more is committed for this press, whatever is confirmed after this. Its
        /// decode goes on to the end of its audio, and each pass is still shown: what it hears
        /// past the commits is held. [LAW:no-silent-failure]
        func stop() {
            state.withLock { $0.committing = false }
            wake.finish()
        }

        /// The press is over, its key up or stopped: what the press showed while it was open.
        func ended(_ ended: Ended) -> DuringPress {
            state.withLock { state in
                state.ended = ended
                return DuringPress(passes: state.passes, repunctuated: state.partial.repunctuated, firstWords: state.firstWords, commits: state.performed.count, wordsCommitted: state.words, firstCommit: state.performed.first?.acknowledged)
            }
        }
    }

    /// A press's decode, begun at key-down: the transcription it came to, when, and what the
    /// press's hold put off. The hold is let go inside it the moment the transcription is out,
    /// so served callers wait for this press's engine and not for an earlier press's insert.
    private struct Decoded: Sendable {
        let transcription: Result<Transcription, Failed>
        let at: ContinuousClock.Instant
        let displaced: EngineHold.Displaced
    }

    /// One insert the loop made: what was done, and how many words it carried, the held
    /// ones included.
    private struct Placed: Sendable {
        let performed: Executor.Performed?
        let words: Int
        /// What the insert carried: the hold's offered words, then the press's own.
        let offered: Transcript
    }

    /// What key-down left for key-up: the mode its chord began it in, and the marks on the
    /// ring, the decode already hearing the press and the commits already queued behind it, or
    /// the reason nothing is hearing it: a press refused, or a chord blocked, which was no
    /// press at all.
    /// [LAW:types-are-the-program] One value, so an end can never find half a beginning.
    /// [LAW:one-source-of-truth] Key-up reads the mode here, so the press is reported in the
    /// mode its decode was told.
    private enum Press {
        case up
        case down(Mode, Open)
        case refused(Mode, Failed)
        case blocked(Mode)
    }

    private struct Open {
        let session: AudioCapture.StreamedSession
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        /// What the latest failed insert of the commits was told, when none after it landed.
        let committing: Task<InsertFailure?, Never>
    }

    /// How a press that was heard ended. [LAW:types-are-the-program] Where the words past its
    /// commits go is the one thing an ending decides: the cursor, the hold, or nowhere.
    private enum Ending: Sendable {
        /// The key came up at `keyUp`, by its event's stamp, and this loop was told `delivery`
        /// after it.
        case released(PressKind, keyUp: ContinuousClock.Instant, delivery: Duration)
        case cut(Cut)
        /// A key was typed while the chord was down, so the chord was that key's modifier and
        /// the person was typing, not dictating. Nothing past the commits is inserted, held, or
        /// shown: the person is not told anything about a keyboard they are using as intended.
        case usedAsModifier
        /// The person threw the press away with Escape. What it put at the cursor is taken back,
        /// what no cursor took is let go, and nothing is held, offered, or shown of it.
        case cancelled
    }

    /// Why a press's words past its commits are held rather than inserted. Each leaves the
    /// person something to see before the next insert carries the words: a press the hotkey
    /// stopped during, or audio with a stretch of the speech missing. [LAW:no-silent-failure]
    /// Words inserted at once would be in the person's editor before anything could say what
    /// they are.
    private enum Cut: Sendable {
        case lapsed
        case lost(CapturedAudio.Loss)

        /// What stopped the press, which the hold tells beside the words and the report tells
        /// beside what became of them.
        var cause: any WordFree {
            switch self {
            case .lapsed: PressLapsed()
            case .lost(let lost): SpeechLost(lost: lost)
            }
        }
    }

    /// A press the microphone opened for, until it is reported: what it showed while the key
    /// was down and what the microphone delivered, read then, and its streaming, which says
    /// what the decode failed to read once the decode is over.
    private struct Opening: Sendable {
        let duringPress: DuringPress
        let capture: CapturedAudio.Reading
        let streaming: Streaming

        var opened: Report.Opened {
            Report.Opened(duringPress: duringPress, unread: streaming.unread, capture: capture)
        }
    }

    /// What key-up hands the queue: a press that was heard, or the outcome of one nothing heard.
    private enum Pending: Sendable {
        case heard(Heard)
        case unheard(Report.Outcome)
    }

    /// A press that was heard, handed to the queue: how it ended, its commits, and the decode
    /// that will say what was in it.
    private struct Heard: Sendable {
        let ending: Ending
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        let committing: Task<InsertFailure?, Never>
    }

    private let capture: AudioCapture
    /// The engine a press decodes on, once it is resident: a press made while the model
    /// still loads waits here, and is inserted when it lands.
    public typealias Engine = @Sendable () async throws(EngineUnavailable) -> any Transcriber

    private let engine: @MainActor () throws(EngineUnavailable) -> Engine
    private let turns: EngineTurns
    private let executor: Executor
    private let hold: Hold
    private let report: @Sendable @MainActor (Report) -> Void
    private let showing: @Sendable @MainActor (Activity) -> Void
    private var press: Press = .up
    /// What `showing` last heard.
    private var shown: Activity = .idle
    /// Presses heard, ended, and not yet reported. A press nothing heard has nothing to
    /// transcribe, so it is not counted and shows no panel on its way out.
    private var unreported = 0
    /// When a cursor last arrived while the open press was down, for the offer queued behind it.
    private var arrivedDuringPress: ContinuousClock.Instant?
    /// Whether the person asked for the dismissed words back while the open press was down,
    /// for the bring-back queued behind it.
    private var broughtBackDuringPress = false
    /// The decode of the latest press, which the next press's decode waits out before it
    /// takes the engine. Nil until the first press.
    private var latestDecode: Task<Decoded, Never>?
    /// The loop's one turn: every commit, insert, offer and bring-back runs on it, and so does
    /// the hand-off of words read from kept speech, which is why it is given and not made here.
    private nonisolated let sessions: SerialQueue
    private let recovery: Recovery

    /// `engine` is asked at each key-down, before the microphone opens: it throws when no
    /// engine can hear the press, and the press is refused before anything is said into it.
    /// Otherwise it hands back the wait for the engine, so loading is not a state this loop
    /// has. `hold` keeps the words no cursor took, and every insert carries them
    /// ahead of its own. `turns` is the engine's owner, which every press holds from key-down
    /// until its transcript is out, so served callers wait for the speaker rather than the
    /// speaker for them. [LAW:dataflow-not-control-flow] `report` hears every press's
    /// outcome and what its microphone delivered on the main actor, in the order the presses came. `showing` hears the loop's
    /// activity each time it changes: a press beginning or ending, a pass reading the open
    /// press, an outcome reported. `sessions` is the loop's turn, shared with `recovery`, which
    /// keeps the speech of a press whose engine failed under it and hands the words it is read
    /// into to `hold` in that turn.
    public init(
        capture: AudioCapture,
        engine: @escaping @MainActor () throws(EngineUnavailable) -> Engine,
        turns: EngineTurns,
        executor: Executor,
        hold: Hold,
        sessions: SerialQueue,
        recovery: Recovery,
        report: @escaping @Sendable @MainActor (Report) -> Void,
        showing: @escaping @Sendable @MainActor (Activity) -> Void
    ) {
        self.capture = capture
        self.engine = engine
        self.turns = turns
        self.executor = executor
        self.hold = hold
        self.sessions = sessions
        self.recovery = recovery
        self.report = report
        self.showing = showing
    }

    /// [LAW:one-source-of-truth] Read off the open press, so a refused one is shown for as long
    /// as it is open, which a tap ends as its chord comes up, and the person learns it before speaking into it.
    private var activity: Activity {
        switch press {
        case .down(_, let open): .listening(heard: open.streaming.heard)
        case .refused(_, let failed): .refused(why: failed.failure.account.facts)
        // A chord pressed over another held modifier is that modifier's own use, Shift and
        // Right Option for a special character, not dictation: it shows no panel, and once up
        // it names nothing in the menu either. [LAW:comments-carry-meaning]
        case .up, .blocked: unreported > 0 ? .transcribing : .idle
        }
    }

    /// Tells `showing` the activity when it differs from what it last heard. Every change
    /// passes through here, so a pass that read nothing new, or that read a press no longer
    /// open, shows nothing twice. [LAW:single-enforcer]
    private func show() {
        let now = activity
        guard now != shown else { return }
        shown = now
        showing(now)
    }

    /// Reports a press, and then shows that a heard one is no longer on its way. Whether a
    /// microphone opened is the report's own to say — `opened` is nil for a press that heard
    /// nothing — so the count still on its way is read from the report, not passed beside it.
    /// [LAW:one-source-of-truth]
    private func settle(_ press: Report) {
        report(press)
        if press.opened != nil { unreported -= 1 }
        show()
    }

    /// The hotkey's handler. The detector pairs every `began` or `blocked` with one `ended`, a
    /// lapse included, and this loop counts on that pairing rather than repairing it: a
    /// press out of order is a broken detector, not a session.
    ///
    /// Answers a refusal when the press that began was refused at key-down, so the hotkey does
    /// not latch a tap that nothing listens to. Every other transition answers nil.
    @discardableResult
    public func press(_ transition: HotkeyDetector.Transition) -> PressRefusal? {
        var refusal: PressRefusal?
        switch transition {
        case .began(let mode, let moment):
            guard case .up = press else { preconditionFailure("a press began while one was open; the detector pairs every began with an ended") }
            // First, so a served decode in flight is cancelled before the microphone opens,
            // and taken by every press, refused or not: a refused press lets go of it at once,
            // and a heard one when its decode stops. [LAW:dataflow-not-control-flow]
            let hold = turns.hold()
            let streaming = Streaming(since: moment)
            do throws(Failed) {
                // The engine before the microphone, so a press nothing can hear is refused
                // before the person speaks into it. [LAW:no-silent-failure]
                let hearing: Engine
                do throws(EngineUnavailable) { hearing = try engine() } catch { throw Failed(error) }
                // Queued before the microphone opens, so the one failure left after it is
                // none: the commits take their turn behind every session before this press,
                // and the session after it takes its turn behind them.
                let committing: Task<InsertFailure?, Never>
                do throws(SerialQueueError) { committing = try sessions.submit { await self.commit(streaming) } } catch { throw Failed(error) }
                // The mark comes from the event's own stamp, so a key-down told late
                // marks the ring where the key went down. What it reaches
                // back over is the resting mode's to say: nothing behind a microphone that
                // opens here, and the look-back behind one held open since `start()`.
                let session: AudioCapture.StreamedSession
                do throws(NoMicrophone) { session = capture.stream(try capture.beginSession(at: moment)) } catch { throw Failed(error) }
                let decode = decode(session.audio, on: hearing, expecting: mode.vocabulary, into: streaming, releasing: hold)
                streaming.hearing { [capture] in capture.missing(from: session) }
                press = .down(mode, Open(session: session, decode: decode, streaming: streaming, committing: committing))
                // Each pass is shown on the main actor, where the press is read, until the
                // decode is over or the press stops.
                Task { for await _ in streaming.reads { show() } }
            } catch {
                // Nothing will be decoded, so the commits queued for it end at once.
                streaming.stop()
                hold.release()
                press = .refused(mode, error)
                refusal = PressRefusal()
            }
            show()
        case .blocked(let mode, _):
            guard case .up = press else { preconditionFailure("a chord was blocked while a press was open; the detector pairs every began with an ended") }
            // No microphone and no turn of the engine: nothing is listening, so nothing is
            // taken from a served caller for it. The detector logs the blocked chord; nothing
            // in the app shows it. [LAW:no-silent-failure]
            press = .blocked(mode)
            show()
        case .ended(let ending):
            let told = ContinuousClock.now
            // [LAW:one-source-of-truth] The key event's own stamp, as key-down's is: a key-up
            // told late is timed from where the key came up, by every figure timed from it.
            // A lapse had no key-up, and a chord used as a modifier inserts nothing to time
            // from one, so neither is given one.
            let released: (kind: PressKind, keyUp: ContinuousClock.Instant)? = switch ending {
            case .released(let kind, let moment): (kind, ContinuousClock.Instant(moment))
            case .lapsed, .usedAsModifier, .cancelled: nil
            }
            let open = press
            press = .up
            if case .down = open { unreported += 1 }
            show()
            // What there is to hear, or what came of a press nothing heard. One value, so a
            // press that was refused at key-down and one that was heard leave here by
            // the same path: the outcome is told inside the queued operation, which
            // is what makes it wait its turn instead of overtaking a session still
            // being inserted. [LAW:dataflow-not-control-flow]
            let mode: Mode
            let pending: Pending
            let opening: Opening?
            switch open {
            case .up:
                preconditionFailure("a press ended that never began; the detector pairs every ended with a began")
            case .refused(let began, let error):
                // The microphone or the engine failed whatever the chord turned out to be.
                mode = began
                pending = .unheard(.failed(error))
                opening = nil
            case .blocked(let began):
                // A chord pressed over another held modifier was the modifier's own use, Shift
                // and Right Option for a special character, not dictation: it opened no
                // microphone and heard nothing, so it is never a failure, whether or not a key
                // was typed under it. [LAW:types-are-the-program] A press that was never
                // dictation is neither a session nor a failure. [LAW:dataflow-not-control-flow]
                // One outcome, not a fork on whether a key landed.
                mode = began
                pending = .unheard(.usedAsModifier(landed: 0, standing: 0, discarded: 0))
                opening = nil
            case .down(let began, let down):
                mode = began
                // Read before the session ends, so it holds only what the press showed
                // while it was open.
                let duringPress = down.streaming.ended(released.map { .up($0.keyUp) } ?? .stopped)
                // The marks are closed and the microphone with them, however the press
                // ended, so a session left open cannot carry its beginning into the next
                // press's clip and cannot leave the device held after the key came up.
                // Its audio ends here too, which is what lets the decode finish.
                let end = capture.endSession(down.session)
                opening = Opening(duringPress: duringPress, capture: end.reading, streaming: down.streaming)
                // How the press ended, read once. [LAW:no-silent-failure] A hotkey that
                // stopped and audio the capture could not stream whole each cut the press
                // short, and a chord used as a modifier ends it as no dictation at all. Those
                // are asked first: a press the hotkey stopped during says so rather than
                // describing the clip it left behind, which was never the whole utterance
                // anyway. A microphone that was not there at all was refused at key-down, so
                // it never reaches here.
                let ended: Ending = switch (ending, released, end.lost) {
                case (.cancelled, _, _): .cancelled
                case (.usedAsModifier, _, _): .usedAsModifier
                case (_, nil, _): .cut(.lapsed)
                case (_, let released?, nil): .released(released.kind, keyUp: released.keyUp, delivery: told - released.keyUp)
                case (_, _?, let lost?): .cut(.lost(lost))
                }
                // A press cut short commits nothing more, and its decode hears it to the end of
                // its audio for the hold. What it already committed stays: the person watched
                // it arrive. Stopped here on the main actor, where every run is taken, so a
                // pass the ended audio lets the engine finish is never committed.
                switch ended {
                case .released: break
                case .cut, .usedAsModifier, .cancelled: down.streaming.stop()
                }
                pending = .heard(Heard(ending: ended, decode: down.decode, streaming: down.streaming, committing: down.committing))
            }
            do throws(SerialQueueError) {
                // Handed over before key-up returns, so a `finish` that comes next
                // cannot miss this press. Reported from inside the operation, so the
                // queue that orders the inserts orders the telling of it too, and a
                // drain that waited for the one has waited for the other.
                // [LAW:no-ambient-temporal-coupling] [LAW:single-enforcer]
                try sessions.submit {
                    let outcome: Report.Outcome
                    switch pending {
                    case .heard(let heard):
                        do throws(Failed) { outcome = try await self.hear(heard) } catch { outcome = .failed(error) }
                    case .unheard(let unheard): outcome = unheard
                    }
                    await self.settle(Report(mode: mode, outcome: outcome, opened: opening?.opened))
                }
            } catch {
                // The operation reports its own outcome; only the queue's own refusal
                // to accept it reaches here, and then nothing will ever read the decode, so
                // it is stopped and lets go of the engine as it does. [LAW:no-silent-failure]
                if case .heard(let heard) = pending { heard.decode.cancel() }
                settle(Report(mode: mode, outcome: .failed(Failed(error)), opened: opening?.opened))
            }
            arrivedDuringPress.map { offer(since: .cursorArrived($0)) }
            arrivedDuringPress = nil
            if broughtBackDuringPress { bringBack() }
            broughtBackDuringPress = false
        }
        return refusal
    }

    /// Returns once every session already begun has been inserted and reported.
    ///
    /// [LAW:no-ambient-temporal-coupling] A process that exits while a session is in flight
    /// loses words the speaker has already said. This is what a surface awaits before it
    /// goes, and the wait is on the sessions themselves rather than on a grace period long
    /// enough to probably cover them.
    public func finish() async throws(SerialQueueError) {
        try await sessions.drain()
    }

    /// Whether words are owed to a cursor: a press is open, or one that ended has inserts not yet
    /// acknowledged. A press puts its commits on the sessions queue at key-down and everything
    /// it inserts after goes behind them, so open, decoding and inserting are one fact, the
    /// queue's, readable from any thread. [LAW:one-source-of-truth]
    public nonisolated var owes: Bool { sessions.isBusy }

    /// Says when everything owed has settled, once a Return has `steered` the press: `landed` when
    /// every word the loop accepted reached a cursor, `notLanded` when some are held for want of
    /// one, or when the chord is still down and the press with it, so nothing would settle for as
    /// long as it takes the chord to come up and a keyboard held for that long is held for nothing.
    ///
    /// [LAW:no-ambient-temporal-coupling] The hotkey's delivery of a press it just ended is on
    /// the main queue ahead of this wait, so the wait is queued after the press's tail and not
    /// before it. The verdict is read off the hold, the one record of words that reached no cursor,
    /// so it cannot disagree with what the panel shows. [LAW:one-source-of-truth]
    public func settled(after steered: HotkeyDetector.Steered) async -> Settlement {
        switch steered {
        case .chordDown:
            return .notLanded
        case .ended, .nothingOpen:
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            do throws(SerialQueueError) { try await sessions.drain() } catch {
                // Draining from the main actor, which no operation runs on, cannot be a wait on itself.
                preconditionFailure("the loop's queue could not be drained from the main actor: \(error)")
            }
            return hold.held == nil ? .landed : .notLanded
        }
    }

    /// Hears the press while it is still going on: the session's audio is handed to the
    /// engine as it is captured, told to expect `vocabulary`, each pass is shown to
    /// `streaming`, and the transcript is what the engine makes of it once the key comes up
    /// and the audio ends.
    /// [LAW:one-type-per-behavior] A held press and a toggled one are heard the same way;
    /// how the press was made is the context's to say.
    ///
    /// [LAW:no-ambient-temporal-coupling] It takes the engine once the press before it has
    /// its transcript, so a press made while the last one's final pass is still to run
    /// cannot put its own passes ahead of it; its audio waits on the stream meanwhile.
    ///
    /// The hold ends with the transcript, whatever became of it: the insert that follows is
    /// not the engine's, and served callers wait for this press and no longer.
    ///
    /// [LAW:no-silent-failure] An engine that fails while the press waits on it leaves the press's
    /// audio unheard, which is all that is left of what was said: it is read to the end of the
    /// press and handed back in the failure as `PressUnheard`, for `hear` to keep, and not dropped
    /// with the stream. The hold is let go first, since there is no engine to serve anyone with.
    private func decode(_ audio: AsyncStream<AudioClip>, on hearing: @escaping Engine, expecting vocabulary: Vocabulary, into streaming: Streaming, releasing hold: EngineHold) -> Task<Decoded, Never> {
        let before = latestDecode
        let decode = Task {
            _ = await before?.value
            let engine: any Transcriber
            do throws(EngineUnavailable) { engine = try await hearing() } catch {
                let displaced = hold.release()
                var samples: [Float] = []
                for await clip in audio { samples += clip.samples }
                streaming.decoded()
                let unheard = PressUnheard(cause: error, speech: UnheardSpeech(said: .now, vocabulary: vocabulary.terms.map(\.text), samples: samples))
                return Decoded(transcription: .failure(Failed(unheard)), at: .now, displaced: displaced)
            }
            let transcription = await Result { () async throws(Failed) in
                do throws(TranscriptionFailure) {
                    return try await engine.transcribe(audio, expecting: vocabulary) { streaming.heard($0) }
                } catch { throw Failed(error) }
            }
            streaming.decoded()
            return Decoded(transcription: transcription, at: .now, displaced: hold.release())
        }
        latestDecode = decode
        return decode
    }

    /// Commits a press's confirmed words as they come, each run as one insert, until its
    /// decode is over or the press stops committing. Runs in the press's turn on the
    /// queue, so the words land after every press before it and before every press after it.
    ///
    /// [LAW:no-silent-failure] An insert that fails leaves its words held and the press
    /// listening, and what it was told is what this returns, unless a later insert landed.
    /// Words that one could not account for stay the hold's to warn of.
    ///
    /// Every count the press keeps of which offered words are its own is read from the hold in the
    /// same step as the insert it is about, with no suspension between: that is what lets a
    /// cancelled press tell its words from earlier dictation without comparing any.
    private func commit(_ streaming: Streaming) async -> InsertFailure? {
        var unplaced: InsertFailure?
        streaming.began(offering: hold.held?.offered)
        for await _ in streaming.wakes {
            guard let run = streaming.take() else { continue }
            do throws(InsertFailure) {
                let placed = try await place(run.words, for: streaming, since: run.since)
                unplaced = placed.performed == nil ? unplaced : nil
            } catch {
                unplaced = error
            }
        }
        return unplaced
    }

    /// Places `words` for the press `streaming` hears, and counts what became of them.
    /// [LAW:single-enforcer] Every insert a press makes passes here, its commits and what key-up
    /// leaves alike, so its counts of words landed and words that may have landed are of all of them.
    private func place(_ words: Transcript, for streaming: Streaming, since: Executor.Since) async throws(InsertFailure) -> Placed {
        streaming.sending(carried: hold.offeredWords)
        do throws(InsertFailure) {
            let placed = try await place(words, following: streaming.landed.performed.last, since: since)
            streaming.landed(placed)
            return placed
        } catch {
            streaming.failed(run: words.words.count, mayHaveLanded: error.wordsMayHaveLanded, offered: hold.offeredWords)
            throw error
        }
    }

    /// Inserts what is held, then `words`, as one insert. [LAW:single-enforcer] Every insert
    /// the loop makes passes through here, so held words land ahead of every word said after
    /// them, and a failed insert's words are held rather than lost. Throws as the executor does.
    private func place(_ words: Transcript, following last: Executor.Performed?, since: Executor.Since) async throws(InsertFailure) -> Placed {
        let offered = hold.sending(words)
        do throws(InsertFailure) {
            let performed = try await executor.insert(offered, following: last, since: since)
            // An insert of nothing is no proof a cursor takes words, so a warning stands.
            performed.map { _ in hold.landed() }
            return Placed(performed: performed, words: performed.map { _ in offered.words.count } ?? 0, offered: offered)
        } catch {
            hold.failed(words, with: error)
            throw error
        }
    }

    /// A cursor was given focus, and what is held is offered to it, in its turn on the queue.
    /// An open press has its commits on the queue and not yet what key-up inserts, so an offer
    /// queued now could land between them: one that arrives then is queued behind the press's
    /// key-up, whose own insert carries what is held, so the offer is for a press that ends
    /// placing nothing. It is for words held when the cursor arrived: the cursor a person
    /// moves to mid-press arrives before the words refused there for it, and those are not
    /// typed into the app they moved to unless a cursor arrives after they are held.
    public func cursorArrived() {
        let arrived = ContinuousClock.now
        switch press {
        case .down: arrivedDuringPress = hold.held.map { _ in arrived } ?? arrivedDuringPress
        case .up, .refused, .blocked: offer(since: .cursorArrived(arrived))
        }
    }

    /// The person asked for every held word at the cursor in front, saying the words that may
    /// have landed, as they stood when they asked, were not typed. The panel offers it only
    /// once a press is closed: one made as a press begins is let go, and the panel offers
    /// Insert again once the press is over.
    public func insertHeld() {
        let asked = ContinuousClock.now
        let vouched = hold.standingGeneration
        switch press {
        case .down: Executor.log.notice("an ask to insert the held words came as a press began and was let go")
        case .up, .refused, .blocked:
            queue("an ask to insert the held words") {
                // [LAW:no-ambient-temporal-coupling] Taken in its own turn, once every insert
                // queued before it is answered, so none of those settles words it never carried
                // or leaves the store offering words on their way.
                guard await self.hold.asked(vouching: vouched) else {
                    return Executor.log.notice("an ask to insert the held words was let go: what may have landed was set anew before its turn")
                }
                // A failure is the hold's to show, and `place` has told it.
                _ = try? await self.place(Transcript(words: []), following: nil, since: .asked(asked))
            }
        }
    }

    /// The person asked for the words they dismissed last back. A press's inserts carry what is
    /// held ahead of their own words, so words brought back amid them would land amid what it
    /// heard: they come back in their turn on the queue, after every press before. One asked
    /// while a press is down is queued at its key-up, since queued now it would take its turn
    /// between the press's commits and its key-up insert.
    public func bringBackDismissed() {
        switch press {
        case .down: broughtBackDuringPress = true
        case .up, .refused, .blocked: bringBack()
        }
    }

    private func bringBack() {
        queue("bringing back the dismissed words") { await self.hold.bringBack() }
    }

    /// Offers what is held to the cursor in front.
    private func offer(since: Executor.Since) {
        queue("an offer of the held words, for \(since.key.rawValue)") {
            // A failure is the hold's to show, and `place` has told it.
            _ = try? await self.place(Transcript(words: []), following: nil, since: since)
        }
    }

    /// Runs `operation` in its turn on the queue.
    private func queue(_ what: String, _ operation: @escaping @Sendable () async -> Void) {
        do throws(SerialQueueError) {
            try sessions.submit(operation)
        } catch {
            // The queue refuses only a wait from inside itself, which the main actor is not.
            preconditionFailure("\(what) could not be queued: \(error)")
        }
    }

    /// What a decode heard past the commits `streaming` made: the transcript's rest, or what the
    /// passes during the press read when the decode failed.
    private func words(past streaming: Streaming, in decoded: Decoded) -> Transcript {
        switch decoded.transcription {
        case .success(let transcription): streaming.rest(of: transcription.transcript)
        case .failure: streaming.rest(of: streaming.reading)
        }
    }

    /// Throws a cancelled press away, as soon as its commits have drained.
    ///
    /// What it put at the cursor is taken back by one request through the executor, never through
    /// `place`, which would carry held words into it. What no cursor took of its own words is let
    /// go from the hold, whether or not the take-back happened, since a cancel discards what is not
    /// in the field. What was said past the commits is dropped, as for a chord that was a typed
    /// key's modifier. Words an insert may have landed stand with the hold's warning, and earlier
    /// dictation that landed with the press's first insert stays in the field: the report counts
    /// both, and a person's dismissal is theirs.
    ///
    /// [LAW:no-silent-failure] A take-back that did not happen is a failure saying how many words
    /// stay at the cursor, and it is never retried: a second one could remove words that are not
    /// this dictation's.
    private func cancel(_ heard: Heard) async throws(Failed) -> Report.Outcome {
        let own = heard.streaming.provenance
        var couldNot: (app: BundleID, cause: InsertFailure)?
        if let last = heard.streaming.landed.performed.last {
            do throws(InsertFailure) { try await executor.takeBack(own.landedText, from: last) } catch { couldNot = (last.into, error) }
        }
        let forgotten = hold.forget(own: own.own, keeping: own.keeping)
        // The engine's turn passes on only when the decode ends, so it is waited out, and what it
        // heard past the commits is counted as dropped.
        let dropped = words(past: heard.streaming, in: await heard.decode.value)
        let cancelled = Cancelled(
            takenBack: couldNot == nil ? own.landedWords : 0, earlierWordsLanded: own.earlierWordsLanded,
            forgotten: forgotten ? own.own : 0, dismissed: forgotten ? 0 : own.own,
            standing: own.standingWords, discarded: dropped.isBlank ? 0 : dropped.words.count)
        if let couldNot {
            throw Failed(CancelLeftWords(left: own.landedWords, app: couldNot.app, cause: couldNot.cause, cancelled: cancelled))
        }
        return .cancelled(cancelled)
    }

    /// A failure that left the press's audio unheard, once that audio is kept, and any other
    /// failure as it was. What the press says is what became of the audio: kept to be read when
    /// an engine lands, or lost, with the reason, since a keep that failed is no keep.
    /// [LAW:no-silent-failure]
    private func keeping(_ failure: any Accounted) -> any Accounted {
        guard let unheard = failure as? PressUnheard else { return failure }
        do throws(UnheardFault) {
            try recovery.keep(unheard.speech)
            return AudioKept(cause: unheard.cause, seconds: unheard.speech.seconds, trouble: nil)
        } catch {
            return AudioKept(cause: unheard.cause, seconds: unheard.speech.seconds, trouble: error)
        }
    }

    /// Waits for the press's commits and its decode, then places what was heard and not yet
    /// committed: at the cursor for a press the speaker released, in the hold for one cut
    /// short, and nowhere for a chord that was a typed key's modifier. Every press waits for
    /// its decode, the model's load included, rather than cancelling it: the engine's turn
    /// passes on only when the decode ends, and a modifier press's report counts its words.
    private func hear(_ heard: Heard) async throws(Failed) -> Report.Outcome {
        let unplaced = await heard.committing.value
        // A cancelled press takes its words back as soon as its commits have drained, which is
        // when it is cancelled and not after a decode that may be loading a model.
        if case .cancelled = heard.ending { return try await cancel(heard) }
        let decoded = await heard.decode.value
        // [LAW:no-silent-failure] Whatever stopped the press, the report says how many of its
        // words are already at the cursor, how many may be, and how many the hold offers.
        func stopped(_ cause: PressStopped.Cause) -> Failed {
            Failed(PressStopped(landed: heard.streaming.landed.words, standing: heard.streaming.provenance.standingWords, held: heard.streaming.provenance.ownOffered(of: hold.offeredWords), cause: cause))
        }
        // [LAW:single-enforcer] What the press heard and never sent is held here, and counted as
        // its own. A press that heard nothing more leaves the hold's warning on the words it
        // already holds, which that warning is about.
        func holdBack(_ rest: Transcript, warning: String) {
            if rest.isBlank { return }
            hold.heldBack(rest, warning: warning)
            heard.streaming.heldBack(run: rest.words.count, offered: hold.offeredWords)
        }
        switch heard.ending {
        case .released(let press, let keyUp, let delivery):
            let transcription: Transcription
            switch decoded.transcription {
            case .success(let decodedTranscription): transcription = decodedTranscription
            case .failure(let failed):
                // [LAW:no-silent-failure] The decode failed, and what the passes during the hold
                // read past the commits is held, the words said after them missing.
                let rest = heard.streaming.rest(of: heard.streaming.reading)
                holdBack(rest, warning: PressStopped.readingFailed)
                // The audio is kept whether or not a commit was refused.
                throw stopped(.reading(keeping(failed.failure), after: unplaced))
            }
            let placed: Placed
            do throws(InsertFailure) {
                placed = try await place(heard.streaming.rest(of: transcription.transcript), for: heard.streaming, since: .keyUp(keyUp))
            } catch { throw stopped(.insert(error)) }
            // A rest of nothing leaves what the commits could not place where it was.
            if placed.performed == nil, let unplaced { throw stopped(.insert(unplaced)) }
            return .session(Session(press: press, transcription: transcription, keyUpToTranscript: decoded.at - keyUp, keyUpDelivery: delivery, displaced: decoded.displaced, performed: heard.streaming.landed.performed, standing: heard.streaming.provenance.standingWords))
        case .usedAsModifier:
            // [LAW:types-are-the-program] The person was typing, so what the microphone heard
            // is not theirs to be shown and not theirs to be warned of: it is dropped, and the
            // report counts it. [LAW:nothing-unseen] A refused commit still names itself, since
            // words it carried are at no cursor whatever the chord turned out to be.
            let dropped = words(past: heard.streaming, in: decoded)
            let discarded = dropped.isBlank ? 0 : dropped.words.count
            if let unplaced { throw stopped(.insert(unplaced)) }
            return .usedAsModifier(landed: heard.streaming.landed.words, standing: heard.streaming.provenance.standingWords, discarded: discarded)
        case .cancelled:
            // Taken above, before the decode was waited on; this is the same answer, never a trap.
            return try await cancel(heard)
        case .cut(let cut):
            // What the decode heard past the commits, and what kept it from reading them: a failed
            // decode leaves what the passes during the hold read. Nothing spoken is nothing more
            // to hold rather than a failure.
            let rest = words(past: heard.streaming, in: decoded)
            let unread: (any Accounted)?
            switch decoded.transcription {
            case .success: unread = nil
            case .failure(let failed):
                if case .nothingSpoken? = failed.failure as? TranscriptionFailure { unread = nil } else { unread = keeping(failed.failure) }
            }
            // Words a failed decode leaves are told as missing what was said after them, beside the cut.
            holdBack(rest, warning: unread == nil ? "\(cut.cause)" : "\(cut.cause) \(PressStopped.readingFailed)")
            throw stopped(.cut(cut.cause, after: unplaced, unread: unread))
        }
    }
}

/// What became of a cancelled press's words, by count and never by the words: each ended in
/// exactly one place. [LAW:nothing-unseen]
public struct Cancelled: Sendable, Equatable, CustomStringConvertible {
    /// Its own words that had landed, taken back out of the field.
    public let takenBack: Int
    /// Earlier dictation its first insert carried into the field: delivered, not this press's, so it stays.
    public let earlierWordsLanded: Int
    /// Its own words no cursor took, let go from the hold.
    public let forgotten: Int
    /// Its own words no cursor took that the person dismissed before cancelling: theirs, so they stay dismissed.
    public let dismissed: Int
    /// Words in inserts that may have landed, its own and the earlier ones they carried: they stand in the hold with its warning.
    public let standing: Int
    /// What was said past the commits, dropped.
    public let discarded: Int

    public init(takenBack: Int, earlierWordsLanded: Int, forgotten: Int, dismissed: Int, standing: Int, discarded: Int) {
        self.takenBack = takenBack
        self.earlierWordsLanded = earlierWordsLanded
        self.forgotten = forgotten
        self.dismissed = dismissed
        self.standing = standing
        self.discarded = discarded
    }

    public var description: String {
        "\(counted(takenBack, "word", "words")) taken back, \(counted(forgotten, "held word", "held words")) let go, \(discarded) heard after the commits dropped; "
            + "\(counted(earlierWordsLanded, "earlier word delivered with its first insert stays", "earlier words delivered with its first insert stay")), "
            + "\(counted(dismissed, "dismissed word stays dismissed", "dismissed words stay dismissed")), "
            + "\(counted(standing, "word that may have landed stands", "words that may have landed stand"))"
    }
}

/// A cancelled press whose words at the cursor could not be taken back: the app in front would not
/// give them back, they are no longer where they were left, or the answer never came. Its other
/// words were still dealt with, as `cancelled` says.
///
/// [LAW:no-silent-failure] Says how many words stay, in which app, and why, and that nothing more
/// was done.
public struct CancelLeftWords: WordFree {
    /// The press's own words that landed, which the take-back was to remove.
    public let left: Int
    public let app: BundleID
    public let cause: InsertFailure
    public let cancelled: Cancelled

    public var description: String {
        let stay = cause.wordsMayHaveLanded
            ? "\(left) of its words may have been taken back, or may still be"
            : counted(left, "of its words is still", "of its words are still")
        return "WARNING: You cancelled a dictation, but \(stay) in \(app.rawValue), and nothing more was done. \(cause.reason) (\(cancelled))"
    }
}

/// A press the hotkey stopped hearing partway through, its words past the commits held
/// rather than inserted.
///
/// The hotkey stopped while the key was down - the app rebuilding its loop, or quitting -
/// so what was captured runs from the press to the stop rather than to the release, and
/// whether the speaker had even finished is unknown.
///
/// [LAW:no-silent-failure] Nothing more is inserted once it stops. Half a sentence inserted
/// at the end arrives unmarked as half, and it cannot be marked: the destination is the
/// user's editor, not this app's, and once the words are in it nothing here can say which
/// ones were missing. So what was heard is held, shown beside this, and the next insert
/// carries it unless the person lets it go first. Words committed while the press was open
/// stay: the person watched them arrive, so they are not unmarked. The press it stopped,
/// `PressStopped`, says what became of each word. [LAW:one-source-of-truth]
public struct PressLapsed: WordFree {
    public var description: String { "WARNING: The hotkey stopped listening during your dictation." }
}

/// A press whose audio the capture could not hand over whole, its words past the commits
/// held rather than inserted.
///
/// Every door leaves the same thing in the user's editor, which is why they arrive here
/// as one failure rather than several. Which doors there are is `CapturedAudio.Loss`'s to
/// say, and `lost` carries the ones this press took. [LAW:one-source-of-truth]
///
/// [LAW:no-silent-failure] The audio on both sides of a gap is heard, and nothing more is
/// inserted once the gap is known, for the reason `PressLapsed` gives: what a fragment
/// transcribes to is a sentence, just not the one that was said. It is held beside the
/// loss. Words committed while the press was open stay, and the press it stopped,
/// `PressStopped`, says what became of each word.
public struct SpeechLost: WordFree {
    public let lost: CapturedAudio.Loss

    public var description: String { "WARNING: \(lost)." }
}

/// A press the engine failed under while it waited on the model's load, which left its audio
/// unheard. Carries the speech to `hear`, which keeps it; reported only as `AudioKept`.
struct PressUnheard: WordFree {
    let cause: EngineUnavailable
    let speech: UnheardSpeech

    var description: String { "\(cause), so \(Int(speech.seconds.rounded())) s of speech went unheard" }
}

/// What became of the audio of a press the engine failed under: kept, to be read into held words
/// once the model has loaded, or lost because it could not be kept.
///
/// Word-free: it is a count of seconds and the load's own reason, and the engine read none of the
/// audio.
public struct AudioKept: WordFree {
    public let cause: EngineUnavailable
    public let seconds: TimeInterval
    /// Why it could not be kept, when it could not.
    public let trouble: UnheardFault?

    public var description: String {
        let said = "\(Int(seconds.rounded())) s"
        return switch trouble {
        case nil: "WARNING: The model failed to load (\(cause)), so nothing could hear what you said. The \(said) of it is kept, and will be held as words once the model has loaded."
        case let trouble?: "WARNING: The model failed to load (\(cause)), so nothing could hear what you said, and the \(said) of it could not be kept (\(trouble)), so it is lost."
        }
    }
}

/// A press that stopped after it began: an insert refused, the engine failed, the hotkey
/// stopped, the audio came apart, or what was left at key-up would not go in. The words before
/// it are at the cursor, those in inserts that may have landed stand, and the rest the hold
/// offers until a cursor takes them. [LAW:no-silent-failure]
/// [LAW:one-source-of-truth] The one account of a stopped press's words: whatever stopped it,
/// they are told here and nowhere else.
///
/// Its description is the person's, and carries any words its cause read; the log reads its
/// account.
public struct PressStopped: Accounted {
    /// The words committed before it stopped.
    public let landed: Int
    /// The words in its inserts that may have landed, which stand in the hold.
    public let standing: Int
    /// Its words the hold offers when it stopped: earlier ones no insert of it carried are told
    /// by the press that left them.
    public let held: Int
    public let cause: Cause

    /// What stopped it, and what came before it that the person must also be told.
    /// [LAW:types-are-the-program] Each ending carries the causes it can have, in the order the
    /// press met them: a commit refused during the hold, the ending, and a reading the decode
    /// then failed. [LAW:no-silent-failure] Each tells what the others cannot.
    public enum Cause: Sendable {
        /// An insert left its words held: key-up's, which carried what any refused commit left,
        /// so its failure is the one told, as in the hold, or a commit's that nothing after carried.
        case insert(InsertFailure)
        /// The decode failed at key-up.
        case reading(any Accounted, after: InsertFailure?)
        /// The hotkey stopped or the audio came apart, so what was said after it was not heard,
        /// and the decode may then have failed to read what was.
        case cut(any WordFree, after: InsertFailure?, unread: (any Accounted)?)
    }

    /// Each cause, in the order the press met them.
    public var causes: [any Accounted] { (insert.map { [$0] } ?? []) + ending }

    /// What ended it, after any insert that left its words held.
    private var ending: [any Accounted] {
        switch cause {
        case .insert: []
        case .reading(let reading, _): [reading]
        case .cut(let cut, _, let unread): unread.map { [cut, $0] } ?? [cut]
        }
    }

    /// What the hold shows beside the words the passes during the hold read, when the decode failed.
    static let readingFailed = "WARNING: The engine failed before it finished reading your dictation, so words said after its earlier readings are missing."

    /// What stopped it, one sentence for each cause. [LAW:one-source-of-truth] Once any of its
    /// words are or may be at a cursor, an insert's fate would be a second account of them, so the
    /// press tells them and the insert its reason. The hold's warning can be a later one, a cut's
    /// or a failed reading's, so the press tells the remedy beside the words it offers. Until then,
    /// an insert's fate is the account: none of the press's words is at a cursor, and the fate says
    /// that and how the hold offers them again, which a cut or a failed reading holding more words
    /// after it leaves true, so what ended it is told as having stopped it, not as a second fate.
    var stoppedBy: String {
        let insert = insert.map { reached ? "WARNING: \($0.reason)" : "\($0)" }
        let ending = ending.map { framed("\($0)", fateTold: reached || insert != nil) }
        return ((insert.map { [$0] } ?? []) + ending).joined(separator: " ")
    }

    /// The insert that left its words held, when one did.
    var insert: InsertFailure? {
        switch cause {
        case .insert(let insert): insert
        case .reading(_, let unplaced), .cut(_, let unplaced, _): unplaced
        }
    }

    /// Whether any of its words are or may be at a cursor.
    var reached: Bool { landed + standing > 0 }

    /// What became of its words: one account of each, those neither inserted nor held, unread or
    /// let go, last. An insert that stopped it before any reached a cursor tells their fate
    /// instead.
    var told: String {
        guard reached || insert == nil else { return "" }
        let offered = insert?.remedy.map { (one: "word is held; \($0) and it is offered again.", many: "words are held; \($0) and they are offered again.") }
            ?? (one: "word is held.", many: "words are held.")
        let fates = [
            (landed, "word of your dictation was inserted before it.", "words of your dictation were inserted before it."),
            (standing, "word may have been inserted; do not dictate it again.", "words may have been inserted; do not dictate them again."),
            (held, offered.one, offered.many),
        ]
        let each = fates.filter { $0.0 > 0 }.map { " \(counted($0.0, $0.1, $0.2))" }
        return each.isEmpty ? " No words of this dictation were inserted or held." : each.joined() + " No others were inserted or held."
    }

    public var description: String { stoppedBy + told }
    /// What it left at the cursor, which is counts, and then each cause's account, the words any
    /// carries kept apart as the facts are.
    public var account: Account {
        let accounts = causes.map(\.account)
        let dictated = accounts.compactMap(\.dictated)
        return Account(
            facts: "\(counted(landed, "word", "words")) inserted, \(standing) that may have been, \(held) held, before: \(accounts.map(\.facts).joined(separator: "; "))",
            dictated: dictated.isEmpty ? nil : dictated.joined(separator: "; "))
    }
}

extension Dictation {
    /// A press that failed, as the loop reports it.
    ///
    /// [LAW:types-are-the-program] Made only from an `Accounted`, so every failure the loop
    /// can report has declared which part of its account is words dictated before it compiles.
    public struct Failed: Error {
        public let failure: any Accounted

        public init(_ failure: any Accounted) { self.failure = failure }

        /// Which failure it is, by its type's name; a stopped press's names what stopped it too, as
        /// `PressStopped(InsertFailure, PressLapsed)`, so the log tells one cause from another.
        /// [LAW:nothing-unseen]
        public var kind: String { Self.kind(of: failure) }

        private static func kind(of failure: any Accounted) -> String {
            let name = String(describing: type(of: failure))
            return (failure as? PressStopped).map { "\(name)(\($0.causes.map(kind(of:)).joined(separator: ", ")))" } ?? name
        }
    }
}

/// What the menu tells the person who dictated about a press that failed: what stopped it,
/// in full, since only they read it, and what became of their words.
public func failureLine(_ failure: any Accounted) -> String {
    (failure as? PressStopped)?.description ?? framed("\(failure)", fateTold: false)
}

/// One cause, as a sentence the person reads: one that opens with WARNING already is, and a bare
/// technical line is told what it is: what stopped the press, where what became of its words is
/// told beside it, and otherwise why they were not placed.
private func framed(_ cause: String, fateTold: Bool) -> String {
    cause.hasPrefix("WARNING:") ? cause : "Your last dictation \(fateTold ? "stopped" : "was not placed"): \(cause)."
}
