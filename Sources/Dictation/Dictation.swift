import Foundation
import Insertion
import LowTalkerCore
import Synchronization

/// The loop from a press of the hotkey to words at the cursor: key-down names the app in
/// front and opens the microphone, marking where the utterance begins on the ring, and the
/// engine starts hearing it as it is captured, committing words at the cursor as they are
/// confirmed; key-up ends it and closes the microphone again; and the rest of the transcript
/// is inserted while the next press can already begin.
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
    /// are reported as `PressLapsed` and `SpeechLost`. What is left is the press this
    /// type says it is: one the speaker ended, heard from every sample it covered.
    public struct Session: Sendable, CustomStringConvertible {
        public let context: Context
        public let transcription: Transcription
        /// What the engine had shown by the time the key came up.
        public let duringPress: DuringPress
        /// From the key coming up to the transcript: `keyUpDelivery`, then the engine's share.
        public let keyUpToTranscript: Duration
        /// From the key coming up to this loop being told it had: the input method's hop to
        /// the app and the main queue's wait behind it, which `keyUpToTranscript` includes.
        public let keyUpDelivery: Duration
        /// What the press's hold put off of the engine's served callers.
        public let displaced: EngineHold.Displaced
        public let performed: [Executor.Performed]

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
            return "heard \(transcription.transcript.words.count) words in a \(context.press) past \(String(format: "%.1f", quiet.letGo)) s of quiet (room \(room), \(String(format: "%.1f", quiet.refusedAsRoom)) s refused as room, \(quiet.transients.count) transient\(quiet.transients.count == 1 ? "" : "s") refused, the longest sounding \(String(format: "%.2f", quiet.transients.longest)) s) \(Int(keyUpToTranscript / .milliseconds(1))) ms after key-up (delivered \(Int(keyUpDelivery / .milliseconds(1))) ms after it; \(duringPress); \(displaced)), \(performed.count) insert\(performed.count == 1 ? "" : "s")\(destination)"
        }
    }

    /// One press, done: how it came out, and what its microphone delivered for it.
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
            /// The chord was a typed key's modifier, so nothing more of the press went in.
            /// `landed` is how many of its words were committed while the chord was down.
            case usedAsModifier(landed: Int)
            case failed(Failed)
        }

        /// The mode whose chord began the press, whatever came of it.
        public let mode: Mode
        public let outcome: Outcome
        /// Nil for a press refused before a microphone opened for it, which its outcome
        /// says the reason for.
        public let capture: CapturedAudio.Reading?

        /// What the microphone delivered, as the press's record says it.
        public var microphone: String {
            capture.map { "\($0)" } ?? "no microphone opened for it"
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
            let committed = firstCommit.map { "\(commits) commits of \(wordsCommitted) words, the first \(Int($0 / .milliseconds(1))) ms after key-down" } ?? "nothing committed before key-up"
            return "\(passes) passes during the press, \(repunctuated) repunctuating a settled word, \(words), \(committed)"
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

        /// What the press is heard through once its microphone is open: the decode, and the
        /// capture's reading of what the press's audio already lacks.
        struct Hearing {
            let decode: Task<Decoded, Never>
            let missing: @MainActor @Sendable () -> CapturedAudio.Loss?
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
            var repunctuated = 0
            var firstWords: Duration?
            /// Nil while the key is down.
            var ended: Ended?
            var confirmed: [Transcript.Word] = []
            /// The text the latest pass read, confirmed then tentative, without its timings:
            /// a pass that rereads the same words has read nothing new.
            var heard = Transcript(words: [])
            var cursor = ConfirmedCursor()
            /// False once the press stops committing.
            var committing = true
            /// Nil until the microphone is open, and for a press refused before it was.
            var hearing: Hearing?
            var performed: [Executor.Performed] = []
            var words = 0
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

        /// Everything the latest pass read.
        var heard: Transcript {
            state.withLock { $0.heard }
        }

        /// The microphone is open and the decode begun.
        func hearing(_ decode: Task<Decoded, Never>, missing: @escaping @MainActor @Sendable () -> CapturedAudio.Loss?) {
            state.withLock { $0.hearing = Hearing(decode: decode, missing: missing) }
        }

        func heard(_ partial: Partial) {
            let now = ContinuousClock.now
            state.withLock { state in
                state.passes += 1
                state.repunctuated = partial.repunctuated
                state.firstWords = state.firstWords ?? (partial.text.isEmpty ? nil : now - keyDown)
                state.confirmed = partial.confirmed.words
                state.heard = Transcript(typed: partial.text)
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
        /// commits: what is confirmed from then on reads a fragment, and key-up reports the
        /// loss with the words that landed before it. From key-up on, how the press ended
        /// says. [LAW:no-silent-failure] An insert that fails stops nothing: its words are
        /// held, and the next run carries them.
        @MainActor func take() -> Run? {
            let missing = state.withLock { state -> (@MainActor @Sendable () -> CapturedAudio.Loss?)? in
                switch state.ended {
                case nil: state.hearing?.missing
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
                let run = state.cursor.advance(through: state.committing ? state.confirmed : [])
                // [LAW:one-source-of-truth] Nothing said is the transcript's test, the one the
                // executor refuses an insert by.
                return run.isBlank ? nil : Run(words: run, since: since)
            }
        }

        /// What the transcript holds past every word already handed out as a run.
        func rest(of transcript: Transcript) -> Transcript {
            state.withLock { $0.cursor.advance(through: transcript.words) }
        }

        /// An insert landed at the cursor, carrying `placed.words`.
        func landed(_ placed: Placed) {
            state.withLock { state in
                if let performed = placed.performed { state.performed.append(performed) }
                state.words += placed.words
            }
        }

        /// The inserts that landed, and the words they carried.
        var landed: (performed: [Executor.Performed], words: Int) {
            state.withLock { ($0.performed, $0.words) }
        }

        /// Nothing more is committed for this press, whatever is confirmed after this, and its
        /// decode, which no one will read, stops: the engine goes back to whoever is waiting.
        func stop() {
            let decode = state.withLock { state in
                state.committing = false
                return state.hearing?.decode
            }
            decode?.cancel()
            wake.finish()
            read.finish()
        }

        /// The press is over, its key up or stopped: what the press showed while it was open.
        func ended(_ ended: Ended) -> DuringPress {
            state.withLock { state in
                state.ended = ended
                return DuringPress(passes: state.passes, repunctuated: state.repunctuated, firstWords: state.firstWords, commits: state.performed.count, wordsCommitted: state.words, firstCommit: state.performed.first?.acknowledged)
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
    }

    /// What key-down left for key-up: the mode its chord began it in, and the marks on the
    /// ring, the app in front, the decode already hearing the press and the commits already
    /// queued behind it, or the reason there was nothing to insert into.
    /// [LAW:types-are-the-program] One value rather than an optional session beside an
    /// optional app, so an end can never find half a beginning.
    /// [LAW:one-source-of-truth] Key-up reads the mode here, so the press is reported in the
    /// mode its decode was told.
    private enum Press {
        case up
        case down(Mode, Open)
        case refused(Mode, Failed)
    }

    private struct Open {
        let session: AudioCapture.StreamedSession
        let into: BundleID
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        /// What the latest failed insert of the commits was told, when none after it landed.
        let committing: Task<InsertFailure?, Never>
    }

    /// How a press that was heard ended.
    private enum Ending: Sendable {
        /// The key came up at `keyUp`, by its event's stamp, and this loop was told `delivery`
        /// after it.
        case released(Context, keyUp: ContinuousClock.Instant, delivery: Duration)
        case lapsed
        case usedAsModifier
        case lost(CapturedAudio.Loss)
    }

    /// A press that was heard, handed to the queue: how it ended, what it showed while it was
    /// open, its commits, and the decode that will say what was in it.
    private struct Heard: Sendable {
        let ending: Ending
        let duringPress: DuringPress
        let decode: Task<Decoded, Never>
        let streaming: Streaming
        let committing: Task<InsertFailure?, Never>
    }

    private let capture: AudioCapture
    private let transcriber: @Sendable @MainActor () async throws(EngineUnavailable) -> any Transcriber
    private let turns: EngineTurns
    private let executor: Executor
    private let hold: Hold
    private let frontmost: @Sendable @MainActor () throws(FrontmostUnknown) -> BundleID
    private let report: @Sendable @MainActor (Report) -> Void
    private let showing: @Sendable @MainActor (Activity) -> Void
    private var press: Press = .up
    /// What `showing` last heard.
    private var shown: Activity = .idle
    /// Presses ended and not yet reported.
    private var unreported = 0
    /// When a cursor last arrived while the open press was down, for the offer queued behind it.
    private var arrivedDuringPress: ContinuousClock.Instant?
    /// The decode of the latest press, which the next press's decode waits out before it
    /// takes the engine. Nil until the first press.
    private var latestDecode: Task<Decoded, Never>?
    private let sessions = SerialQueue()

    /// `transcriber` is awaited per session, so a press that comes while the model is
    /// still loading waits for it and inserts when it lands: loading is not a state
    /// this loop has. `hold` keeps the words no cursor took, and every insert carries them
    /// ahead of its own. `turns` is the engine's owner, which every press holds from key-down
    /// until its transcript is out, so served callers wait for the speaker rather than the
    /// speaker for them. [LAW:dataflow-not-control-flow] `report` hears every press's
    /// outcome and what its microphone delivered on the main actor, in the order the presses came. `showing` hears the loop's
    /// activity each time it changes: a press beginning or ending, a pass reading the open
    /// press, an outcome reported.
    public init(
        capture: AudioCapture,
        transcriber: @escaping @Sendable @MainActor () async throws(EngineUnavailable) -> any Transcriber,
        turns: EngineTurns,
        executor: Executor,
        hold: Hold,
        frontmost: @escaping @Sendable @MainActor () throws(FrontmostUnknown) -> BundleID = TargetApp.frontmost,
        report: @escaping @Sendable @MainActor (Report) -> Void,
        showing: @escaping @Sendable @MainActor (Activity) -> Void
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.turns = turns
        self.executor = executor
        self.hold = hold
        self.frontmost = frontmost
        self.report = report
        self.showing = showing
    }

    private var activity: Activity {
        if case .down(_, let open) = press { return .listening(heard: open.streaming.heard) }
        return unreported > 0 ? .transcribing : .idle
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

    /// Reports a press, and then shows that it is no longer on its way.
    private func settle(_ press: Report) {
        report(press)
        unreported -= 1
        show()
    }

    /// The hotkey's handler. The detector pairs every `began` with one `ended`, a lapse
    /// included, and this loop counts on that pairing rather than repairing it: a
    /// press out of order is a broken detector, not a session.
    public func press(_ transition: HotkeyDetector.Transition) {
        switch transition {
        case .began(let mode, let moment):
            guard case .up = press else { preconditionFailure("a press began while one was open; the detector pairs every began with an ended") }
            // First, so a served decode in flight is cancelled before the microphone opens,
            // and taken by every press, refused or not: a refused press lets go of it at once,
            // and a heard one when its decode stops. [LAW:dataflow-not-control-flow]
            let hold = turns.hold()
            let streaming = Streaming(since: moment)
            do throws(Failed) {
                // The app in front before the microphone, so a reading that throws cannot
                // leave a microphone open with no session to close it; it is one read of
                // the workspace, which the engine's start dwarfs. [LAW:no-ambient-temporal-coupling]
                let into: BundleID
                do throws(FrontmostUnknown) { into = try frontmost() } catch { throw Failed(error) }
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
                let decode = decode(session.audio, expecting: mode.vocabulary, into: streaming, releasing: hold)
                streaming.hearing(decode) { [capture] in capture.missing(from: session) }
                press = .down(mode, Open(session: session, into: into, decode: decode, streaming: streaming, committing: committing))
                // Each pass is shown on the main actor, where the press is read, until the
                // decode is over or the press stops.
                Task { for await _ in streaming.reads { show() } }
            } catch {
                // Nothing will be decoded, so the commits queued for it end at once.
                streaming.stop()
                hold.release()
                press = .refused(mode, error)
            }
            show()
        case .ended(let ending):
            let told = ContinuousClock.now
            // [LAW:one-source-of-truth] The key event's own stamp, as key-down's is: a key-up
            // told late is timed from where the key came up, by every figure timed from it.
            // A lapse had no key-up, and a chord used as a modifier inserts nothing to time
            // from one, so neither is given one.
            let released: (kind: PressKind, keyUp: ContinuousClock.Instant)? = switch ending {
            case .released(let kind, let moment): (kind, ContinuousClock.Instant(moment))
            case .lapsed, .usedAsModifier: nil
            }
            let open = press
            press = .up
            unreported += 1
            show()
            // What there is to hear, or the reason there is nothing. One value, so a
            // press that was refused at key-down and one that was heard leave here by
            // the same path: the failure is thrown inside the queued operation, which
            // is what makes it wait its turn instead of overtaking a session still
            // being inserted. [LAW:dataflow-not-control-flow]
            let mode: Mode
            let heard: Result<Heard, Failed>
            let delivered: CapturedAudio.Reading?
            switch open {
            case .up:
                preconditionFailure("a press ended that never began; the detector pairs every ended with a began")
            case .refused(let began, let error):
                mode = began
                heard = .failure(error)
                delivered = nil
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
                delivered = end.reading
                // How the press ended, read once. [LAW:no-silent-failure] A hotkey that
                // stopped and audio the capture could not stream whole each leave
                // something this loop must not report as an utterance, and a chord used as a
                // modifier leaves no utterance at all. Those are asked first: a press the
                // hotkey stopped during says so rather than describing the clip it left
                // behind, which was never the whole utterance anyway. A microphone that was
                // not there at all was refused at key-down, so it never reaches here.
                let ended: Ending = switch (ending, released, end.lost) {
                case (.usedAsModifier, _, _): .usedAsModifier
                case (_, nil, _): .lapsed
                case (_, let released?, nil): .released(Context(press: released.kind, frontmostApp: down.into), keyUp: released.keyUp, delivery: told - released.keyUp)
                case (_, _?, let lost?): .lost(lost)
                }
                // A press that will not be inserted commits nothing more and has no use for
                // the rest of its decode. What it already committed stays: the person watched
                // it arrive. Stopped here on the main actor, where every run is taken, so a
                // pass the ended audio lets the engine finish is never committed.
                switch ended {
                case .released: break
                case .lapsed, .usedAsModifier, .lost: down.streaming.stop()
                }
                heard = .success(Heard(ending: ended, duringPress: duringPress, decode: down.decode, streaming: down.streaming, committing: down.committing))
            }
            do throws(SerialQueueError) {
                // Handed over before key-up returns, so a `finish` that comes next
                // cannot miss this press. Reported from inside the operation, so the
                // queue that orders the inserts orders the telling of it too, and a
                // drain that waited for the one has waited for the other.
                // [LAW:no-ambient-temporal-coupling] [LAW:single-enforcer]
                try sessions.submit {
                    let outcome: Report.Outcome
                    do throws(Failed) {
                        outcome = try await self.hear(heard)
                    } catch {
                        outcome = .failed(error)
                    }
                    await self.settle(Report(mode: mode, outcome: outcome, capture: delivered))
                }
            } catch {
                // The operation reports its own outcome; only the queue's own refusal
                // to accept it reaches here, and then nothing will ever read the decode, so
                // it is stopped and lets go of the engine as it does. [LAW:no-silent-failure]
                if case .success(let heard) = heard { heard.decode.cancel() }
                settle(Report(mode: mode, outcome: .failed(Failed(error)), capture: delivered))
            }
            arrivedDuringPress.map(offer(since:))
            arrivedDuringPress = nil
        }
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
    private func decode(_ audio: AsyncStream<AudioClip>, expecting vocabulary: Vocabulary, into streaming: Streaming, releasing hold: EngineHold) -> Task<Decoded, Never> {
        let before = latestDecode
        let decode = Task { [transcriber] in
            _ = await before?.value
            let transcription = await Result { () async throws(Failed) in
                let engine: any Transcriber
                do throws(EngineUnavailable) { engine = try await transcriber() } catch { throw Failed(error) }
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
    private func commit(_ streaming: Streaming) async -> InsertFailure? {
        var unplaced: InsertFailure?
        for await _ in streaming.wakes {
            guard let run = streaming.take() else { continue }
            do throws(InsertFailure) {
                let placed = try await place(run.words, following: streaming.landed.performed.last, since: run.since)
                streaming.landed(placed)
                unplaced = placed.performed == nil ? unplaced : nil
            } catch {
                unplaced = error
            }
        }
        return unplaced
    }

    /// Inserts what is held, then `words`, as one insert. [LAW:single-enforcer] Every insert
    /// the loop makes passes through here, so held words land ahead of every word said after
    /// them, and a failed insert's words are held rather than lost. Throws as the executor does.
    private func place(_ words: Transcript, following last: Executor.Performed?, since: Executor.Since) async throws(InsertFailure) -> Placed {
        let offered = hold.offering(words)
        do throws(InsertFailure) {
            let performed = try await executor.insert(offered, following: last, since: since)
            // An insert of nothing is no proof a cursor takes words, so a warning stands.
            performed.map { _ in hold.landed() }
            return Placed(performed: performed, words: performed.map { _ in offered.words.count } ?? 0)
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
        case .up, .refused: offer(since: arrived)
        }
    }

    /// Offers what is held to the cursor in front.
    private func offer(since arrived: ContinuousClock.Instant) {
        do throws(SerialQueueError) {
            try sessions.submit {
                // A failure is the hold's to show, and `place` has told it.
                _ = try? await self.place(Transcript(words: []), following: nil, since: .cursorArrived(arrived))
            }
        } catch {
            // The queue refuses only a wait from inside itself, which the main actor is not.
            preconditionFailure("a cursor's arrival could not be queued: \(error)")
        }
    }

    /// Waits for the press's commits and its decode, then inserts what was heard
    /// and not yet committed. A press that will not be inserted is reported in its turn
    /// without waiting on its decode, which was told to stop and may still be waiting for
    /// the model to load.
    private func hear(_ heard: Result<Heard, Failed>) async throws(Failed) -> Report.Outcome {
        let heard = try heard.get()
        let unplaced = await heard.committing.value
        let landed = heard.streaming.landed
        // [LAW:no-silent-failure] Whatever stopped the press, the report says how many of its
        // words are already at the cursor.
        func stopped(_ cause: any Accounted) -> Failed { Failed(PressStopped(landed: landed.words, cause: cause)) }
        let context: Context
        let keyUp: ContinuousClock.Instant
        let delivery: Duration
        switch (heard.ending, unplaced) {
        case (.released(let released, let up, let late), _): (context, keyUp, delivery) = (released, up, late)
        // [LAW:no-silent-failure] The report names what left the press's words unplaced
        // first: a refused commit came before whatever the key-up found.
        case (.lapsed, let unplaced?), (.usedAsModifier, let unplaced?), (.lost, let unplaced?): throw stopped(unplaced)
        case (.lapsed, nil): throw Failed(PressLapsed(landed: landed.words))
        case (.usedAsModifier, nil): return .usedAsModifier(landed: landed.words)
        case (.lost(let lost), nil): throw Failed(SpeechLost(lost: lost, landed: landed.words))
        }
        let decoded = await heard.decode.value
        let transcription: Transcription
        switch decoded.transcription {
        case .success(let decodedTranscription): transcription = decodedTranscription
        case .failure(let failed): throw stopped(failed.failure)
        }
        let placed: Placed
        do throws(InsertFailure) {
            placed = try await place(heard.streaming.rest(of: transcription.transcript), following: landed.performed.last, since: .keyUp(keyUp))
        } catch { throw stopped(error) }
        // A rest of nothing leaves what the commits could not place where it was.
        if placed.performed == nil, let unplaced { throw stopped(unplaced) }
        return .session(Session(context: context, transcription: transcription, duringPress: heard.duringPress, keyUpToTranscript: decoded.at - keyUp, keyUpDelivery: delivery, displaced: decoded.displaced, performed: landed.performed + [placed.performed].compactMap { $0 }))
    }
}

/// A press the hotkey stopped hearing partway through, reported instead of inserted.
///
/// The hotkey stopped while the key was down - the app rebuilding its loop, or quitting -
/// so what was captured runs from the press to the stop rather than to the release, and
/// whether the speaker had even finished is unknown.
///
/// [LAW:no-silent-failure] Nothing more is inserted once it stops. Half a sentence inserted
/// at the end arrives unmarked as half, and it cannot be marked: the destination is the
/// user's editor, not this app's, and once the words are in it nothing here can say which
/// ones were missing. Words committed while the press was open stay, and this says how
/// many: the person watched them arrive, so they are not unmarked. A press that says it
/// was cut off is a thing they can act on by saying the rest again.
public struct PressLapsed: WordFree {
    /// The words committed before it stopped.
    public let landed: Int

    public var description: String { "WARNING: The hotkey stopped listening during your dictation. \(ignored(after: landed))" }
}

/// A press whose audio the capture could not hand over whole, reported instead of inserted.
///
/// Every door leaves the same thing in the user's editor, which is why they arrive here
/// as one failure rather than several. Which doors there are is `CapturedAudio.Loss`'s to
/// say, and `lost` carries the ones this press took. [LAW:one-source-of-truth]
///
/// [LAW:no-silent-failure] Nothing more is inserted once it is known, for the reason
/// `PressLapsed` gives: what a fragment transcribes to is a sentence, just not the one
/// that was said. Words committed while the press was open stay, and this says how many.
public struct SpeechLost: WordFree {
    public let lost: CapturedAudio.Loss
    /// The words committed before it was known.
    public let landed: Int

    public var description: String { "WARNING: \(lost). \(ignored(after: landed))" }
}

/// A press that stopped after it began: an insert refused, the engine failed, or what was
/// left at key-up would not go in. The words before it are at the cursor, and the ones an
/// insert failed on are held until a cursor takes them. [LAW:no-silent-failure]
///
/// Its description is the person's, and carries any words its cause read; the log reads its
/// account.
public struct PressStopped: Accounted {
    /// The words committed before it stopped.
    public let landed: Int
    public let cause: any Accounted

    public var description: String { "\(cause)" + insertedBefore(landed) }
    /// What it left at the cursor, which is a count, and then the cause's account.
    public var account: Account {
        Account(facts: "\(landed) words inserted before: \(cause.account.facts)", dictated: cause.account.dictated)
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

        /// Which failure it is, by its type's name.
        public var kind: String { String(describing: type(of: failure)) }
    }
}

/// What the menu tells the person who dictated about a press that failed: what stopped it,
/// in full, since only they read it, and how many of their words it left at the cursor.
/// A failure written as fact then consequence opens with WARNING and carries its own framing;
/// any other is a bare technical line, so it is told what it is and ended as a sentence.
public func failureLine(_ failure: any Accounted) -> String {
    let root = "\((failure as? PressStopped)?.cause ?? failure)"
    let landed = (failure as? PressStopped)?.landed ?? 0
    let framed = root.hasPrefix("WARNING:") ? root : "Your last dictation \(landed == 0 ? "was not placed" : "stopped"): \(root)."
    return framed + insertedBefore(landed)
}

/// How many of a press's words reached the cursor before what stopped it, when any did.
private func insertedBefore(_ landed: Int) -> String {
    landed == 0 ? "" : " \(landed) words of your dictation were inserted before it; the rest were not."
}

/// What became of a press's words, after however many had landed.
private func ignored(after landed: Int) -> String {
    landed == 0 ? "Your dictation was ignored." : "The \(landed) words already inserted stay; the rest of your dictation was ignored."
}
