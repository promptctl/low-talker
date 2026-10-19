import Foundation
import Grants
import Synchronization

/// Microphone capture whose engine lives for one session, or for the whole run when the
/// user has asked for that. `start` holds the grant and watches the input device, and
/// brings the microphone to what `MicrophoneAtRest` says it does between presses. Under
/// the default, `shut`, it opens nothing, so a Mac with low-talker running and nobody
/// dictating shows no microphone in the menu bar; `beginSession` opens the microphone,
/// `endSession` closes it, and between the two the ring fills as before: a session is
/// still two positions on the ring.
///
/// What that costs is the look-back. A session's pre-roll reaches back over audio the
/// microphone was already capturing, and one opened at key-down has none behind it, so
/// the pre-roll clamps to nothing and the utterance starts where the microphone did. A
/// prepared microphone's first sample lands well inside the gap between deciding to press
/// a key and beginning to say a word, so a press followed by speech loses nothing; a
/// press made *during* a word loses the part of it that was said before the key went
/// down, and no microphone can be opened in the past.
///
/// That holds only because the microphone is readied before the press rather than at it.
/// Reaching a microphone costs far more than opening one already reached, and a press
/// that paid both was losing a third of a second off every utterance - so `start` readies
/// one while the app is idle, which opens no device and lights nothing, and the press
/// pays only the opening. What a press is allowed to miss is `warmUpAllowance`; what
/// reaching and opening each cost, and how the microphone is reached at all, is
/// `HALInput`'s.
///
/// Readying a microphone that is only readied never holds the main actor, which is where this
/// class runs and where a device change is reported to it. A readying asked for here is under
/// way elsewhere when the call returns, so a run of notifications as a dock or an interface
/// comes up leaves the key-down handler free, and a readying replaced by a newer one before
/// its turn is never done. A press that comes for a microphone still being readied waits for
/// the rest of that readying and no more - see `PreparedInput`.
///
/// A change under an engine that has to run again - one `open` holds, a press's, or a failed
/// one a device appearing retries - does wait here, for the rest of its readying and the
/// launch. Waiting elsewhere would buy nothing: the device is dark until that launch whoever
/// makes it, and a key-down queued behind it carries its own moment, so it marks the ring
/// where it would have and hears its first sample no sooner.
///
/// `open` is the other side of that trade, and buying the look-back back is the whole of
/// what it does here: the engine started at `start` is never given up between presses, so
/// the ring is continuous and a press reaches back over real audio. Nothing in this file
/// decides which one is in force - `start` is told, and `rest` is the one place the answer
/// is read.
///
/// That argument covers the warm engine and nothing else, so the gap is measured rather
/// than assumed: `endSession` reads the stretch between the key going down and the first
/// sample anything captured, and a press missing more of it than `warmUpAllowance` comes
/// back partial instead of whole. Two things reach that door - the first press in a
/// process, which pays a cold launch, and a key-down the input method delivered late,
/// which pays whatever was ahead of it. Both are speech the speaker addressed to a shut
/// microphone, and a press that says so is one they can repeat; a sentence quietly
/// missing its front is not. [LAW:no-silent-failure]
///
/// The engine is disposable and the ring is not. A microphone is prepared against one
/// device and cannot be re-pointed at another, so a device change launches a new engine
/// by the same routine as opening one, and the ring, which lives here rather than in any
/// engine, carries across. What it carries across is spliced: no audio is captured
/// between the two engines, so the position the new one resumes at is kept and a session
/// that spans it is told its clip is not whole.
///
/// When the only input device is unplugged, the replacement cannot launch (there is
/// nothing to convert from) and capture is failed. A failed capture has no engine, so
/// the plug-back-in reaches it another way: the system default input device is watched
/// for the whole started period, and a change launches again wherever the engine is
/// failed - mid-press, or held at rest and dead. A shut one it leaves shut.
@MainActor
public final class AudioCapture {
    public enum State {
        case stopped
        /// Started, with no session open: the grant is held and the input device is
        /// watched, and the microphone is doing whatever the resting mode says.
        case listening
        /// A session is open, so the microphone is too.
        case running
        /// The engine stopped on its own, until a launch clears it - the input device
        /// changing, or the next press - or, under `shut`, a key-up closes it instead.
        case failed(any Error)
    }

    /// The gaps in capture since `start()`: how many, and how long without audio all
    /// together.
    public struct Outages: Sendable {
        public var count = 0
        public var total: Duration = .zero
    }

    /// An engine on the input device of its moment. The generation is what this engine's
    /// render callback carries with a failure, so a failure from a replaced engine is
    /// recognized as stale (a counter, because a replaced engine's address can be reused).
    private struct Live {
        let dispose: Disposal
        let generation: Int
        let input: MicrophoneInput
    }

    /// What the microphone is doing.
    private enum Engine {
        /// Nothing is running and macOS shows nothing.
        case shut
        case running(Live)
        /// The engine has been gone since `since`, and the input it was on is the `on`th one
        /// readied - which says whether the input held now is that one or one readied since.
        case failed(any Error, since: ContinuousClock.Instant, on: Int)
    }

    /// [LAW:types-are-the-program] The grant, the default-input watch and the resting mode
    /// exist exactly between `start()` and `stop()`, whatever the microphone is doing, so
    /// they live beside the engine rather than in optionals every reader would have to
    /// reconcile.
    private struct Started {
        let watch: Disposal
        let grant: MicrophoneGrant
        /// What the microphone does whenever no session is open. Changed only by
        /// `rest(as:)`, and read only by `rest()`, so a change reaches the device at the next
        /// moment no session is open and never cuts one short.
        var atRest: MicrophoneAtRest
        var engine: Engine
        /// The microphone this run of capture opens, readied but not open. Held across
        /// presses because that is the whole of what makes `shut` affordable: what it
        /// cost to ready is spent once, while nobody is dictating, and a press pays only
        /// what it costs to open a microphone already reached.
        ///
        /// Replaced rather than re-pointed when the input device changes, because an
        /// input is prepared against one device. [LAW:one-source-of-truth] `AudioCapture`
        /// is the one place that learns the device changed, so it is the one place that
        /// decides a prepared input has gone stale.
        var prepared: any PreparedInput
        /// Whether a press is in flight. The engine's own state answered this while the
        /// microphone's lifetime was one session's; a resting mode that holds the engine
        /// across presses takes that reading away, so the fact is kept rather than
        /// inferred from a microphone that is now open for two different reasons.
        /// [FRAMING:representation]
        var sessionIsOpen = false
    }

    private enum Phase {
        case stopped
        case started(Started)
    }

    /// The samples and where their positions sit in time. [LAW:no-ambient-temporal-coupling]
    /// One value under one lock: a position read off the timeline and a slice taken
    /// from the ring must not straddle a buffer that arrived between them.
    private struct Stream: Sendable {
        var ring: AudioRing
        var timeline: AudioTimeline
        /// The first position the engine now feeding the ring will write to. Everything
        /// before it was captured by an engine that has since stopped - a previous
        /// session's, or this one's before the input device changed under it - with a
        /// stretch of speech missing in between: nothing is captured while no engine is
        /// running, and positions advance only on capture, so the audio on either side
        /// of the break is spliced together with no seam in the samples to find it by.
        var continuousSince = 0
        /// The generation whose buffers this stream is the audio of. Whatever the input has
        /// not finished handing over when `dispose()` begins still arrives, closing the input
        /// hands over the rest, and all of it belongs to a press the speaker has already let
        /// go of; appending it would move the positions the next press begins from. Read on the input's delivery thread, which
        /// does not ask the main actor, so the answer lives here beside the samples it admits.
        /// [LAW:no-ambient-temporal-coupling]
        var accepting: Int?
        /// What has arrived since the open session began.
        var arrivals = Arrivals()
        /// Where the open session's audio goes as it lands, once something has asked for
        /// it with `stream(_:)`. Beside the ring and under its lock, so a buffer reaches
        /// the ring and the feed together or neither.
        var feed: AsyncStream<AudioClip>.Continuation?
    }

    /// What the ring cannot say about the open session's audio: when it began arriving and
    /// through which inputs. [LAW:nothing-unseen] A press that heard nothing and one that
    /// heard a quiet room end with the same empty transcript, and these and the ring are what
    /// tell them apart.
    private struct Arrivals: Sendable {
        /// When the first sample delivered since the open session began was captured, and
        /// nothing once it is set: it dates that session's head, so a later engine's
        /// buffers must not re-date it. A microphone opened for the press is dated by the
        /// first sample it captures, which is after the key; one the resting mode was
        /// already holding is dated by a sample captured at or before the key, since its
        /// buffers were already running, and `AudioSession.unheard` answers zero for
        /// those, as for one whose key landed among samples it had already delivered, which
        /// is dated by the key. Empty means nothing has been delivered since the session began, which is
        /// a microphone that never opened for it at all - and which a held microphone can
        /// arrive at too, by dying quietly rather than by opening late.
        var first: HostTime?
        /// The inputs the session is heard through, in the order they opened: the one held
        /// open when it began or the one opened for it, then any a device change opened
        /// under it.
        var inputs: [MicrophoneInput] = []
    }

    /// The stream behind a lock, shared between the input's delivery thread and the main
    /// actor. Never CoreAudio's IO thread: the main actor holds this while it copies a whole
    /// session out at key-up, and a render that waited for it would miss its deadline.
    private final class Shared: Sendable {
        let stream: Mutex<Stream>
        init(_ stream: Stream) { self.stream = Mutex(stream) }
    }

    private let hardware: any AudioHardware
    private let shared: Shared
    /// Told every device report and what was done about it, including the ones that changed
    /// nothing. A device going away is answered here with no press to throw to and no
    /// session to mark, so this is the only place a recovery - or a recovery that did not
    /// come - leaves a trace. [LAW:nothing-unseen]
    private let reporting: @MainActor (DeviceReport) -> Void
    private var phase: Phase = .stopped
    private var generation = 0
    /// Microphones readied since this capture was made. What the staleness callback of each
    /// readied input carries, for the reason an engine's generation is carried: the watch
    /// behind it lives as long as the input does, a notification already posted when that
    /// input was let go still arrives, and the input it speaks about is not the one a press
    /// would open any more. Never reset - `start()` resets what it counts, and a counter that
    /// went back to zero would let the previous run's stragglers match.
    private var preparations = 0
    /// Running engines `replaceEngine` swapped in place since `start()`: the device
    /// changed, capture stayed running, and nothing failed. Not a claim that no audio was
    /// lost to them - the audio on either side of each one is spliced, which is what a
    /// session's `CapturedAudio` says and this count does not.
    public private(set) var deviceChanges = 0
    public private(set) var outages = Outages()

    nonisolated public static let defaultRetention: TimeInterval = 60

    /// How long the microphone may take to open after the key went down before the press
    /// is treated as having missed speech rather than as having warmed up.
    ///
    /// This is the number the epic traded the look-back for, so it is written down rather
    /// than tuned. What it is compared against is the whole stretch from the key going
    /// down to the first sample anything captured, which is everything opening a
    /// microphone costs and not only the last call of it - the distinction this number
    /// was once measured on the wrong side of, when a figure taken from after the engine
    /// was built was read as what a press pays.
    ///
    /// Generous, so a microphone that is slow to open on a loaded Mac still yields a press
    /// rather than a refusal. Past it the press is refused and says so, since a clip
    /// missing its head transcribes to a fluent sentence with the first word gone.
    /// [LAW:no-silent-failure]
    nonisolated public static let warmUpAllowance: TimeInterval = 2

    /// `origin` is when the first sample is expected: nothing has been captured yet,
    /// so the timeline starts on that prediction and the first buffer corrects it.
    public init(
        retaining duration: TimeInterval = defaultRetention,
        hardware: any AudioHardware = SystemAudioHardware(),
        startingAt origin: HostTime = .now,
        reporting: @escaping @MainActor (DeviceReport) -> Void
    ) {
        self.hardware = hardware
        self.reporting = reporting
        shared = Shared(Stream(ring: AudioRing(retaining: duration), timeline: AudioTimeline(startingAt: origin)))
    }

    public var state: State {
        switch phase {
        case .stopped: .stopped
        case .started(let started):
            switch started.engine {
            case .failed(let error, _, _): .failed(error)
            // A running engine is a press's while one is in flight and the resting mode's
            // the rest of the time. `running` names the press, not the microphone: which
            // of the two is holding the device open is what `atRest` says.
            case .shut, .running: started.sessionIsOpen ? .running : .listening
            }
        }
    }

    /// What the microphone does between presses for the run of capture that is started,
    /// and nothing at all when none is. Read from here rather than from the config, so a
    /// reader is told what capture is doing rather than what a file asked for.
    /// [LAW:one-source-of-truth]
    public var atRest: MicrophoneAtRest? {
        guard case .started(let started) = phase else { return nil }
        return started.atRest
    }

    /// What to tell the user their microphone is doing, in one sentence.
    ///
    /// The resting mode alone cannot say it. That is what was asked for, and an engine
    /// that died while nobody was pressing anything leaves it asked for and untrue - so a
    /// surface reading the mode alone reports a live device for as long as the app runs.
    /// [FRAMING:representation] The mode is the map and the engine is the territory, and
    /// this is the one place they are read together.
    ///
    /// It matters most where the failure is quietest. Under `shut` the next press
    /// relaunches a dead engine and the user learns within one hold; under `open` nobody
    /// presses for hours, and this is the only surface that could say the device is gone.
    /// [LAW:no-silent-failure]
    public var doing: Doing {
        guard case .started(let started) = phase else { return .notCaptured }
        switch started.engine {
        case .shut, .running: return .keeping(started.atRest)
        case .failed(let error, _, _): return .stopped(started.atRest, error)
        }
    }

    /// What `doing` reads, which says itself as the sentence.
    public enum Doing: CustomStringConvertible {
        case notCaptured
        /// Doing what the resting mode asks.
        case keeping(MicrophoneAtRest)
        /// Asked to keep to the resting mode, and the device stopped, for this reason.
        case stopped(MicrophoneAtRest, any Error)

        public var description: String {
            switch self {
            case .notCaptured: "not being captured"
            case .keeping(let atRest): "\(atRest)"
            case .stopped(let atRest, let error): "\(atRest), but it stopped: \(error)"
            }
        }
    }

    /// Takes the microphone for a session - opening one, or using the one the resting mode
    /// is already holding - and marks where the session begins: the position capture had
    /// reached when `moment` passed, with the pre-roll it will reach back over.
    ///
    /// Throws when there is no microphone to open - capture is not started, or the input
    /// device cannot feed the pipeline - so a press with nothing behind it is refused at
    /// the key rather than yielding an empty clip a transcriber would call a quiet room.
    /// [LAW:no-silent-failure]
    ///
    /// [LAW:one-source-of-truth] The moment is the one the event that began the session
    /// was stamped with, not the one this is called at, so a handler that ran late still
    /// marks the ring where the key went down. It names a position within this run of
    /// capture and nowhere else: a moment later than the newest sample marks the newest
    /// sample, since a session cannot begin in audio that has not been captured, and a
    /// moment earlier than the engine's first sample marks that first sample, since the
    /// audio before it is some earlier press's and belongs to no part of this one. Where
    /// the microphone opens for the session both clamps land on the same position, and the
    /// session begins where the microphone did; where the resting mode has held it open
    /// since `start()`, this run of capture reaches back that far and so may the pre-roll.
    ///
    /// What the forward clamp moves the mark past is not thrown away with it: the moment
    /// rides along on the session, and `endSession` reports the distance between them as
    /// the head the microphone was shut for. A key-down that reached here late addresses
    /// speech no engine can be started in time for, and a press that quietly began after
    /// the words it was pressed for is the one failure this whole path exists to refuse.
    /// [LAW:no-silent-failure]
    public func beginSession(at moment: HostTime, preRoll: TimeInterval = AudioSession.defaultPreRoll) throws(NoMicrophone) -> AudioSession {
        guard case .started(var started) = phase else { throw NoMicrophone.stopped }
        guard !started.sessionIsOpen else {
            preconditionFailure("a session began while one was open; a press is one session")
        }
        // Cleared before any input opens, so the first buffer delivered after the key
        // is the one that dates this session's head. Cleared here and not in `launch()`
        // because a mid-session replacement launches too, and its first buffer dates its
        // own audio rather than the moment this session's microphone opened. A microphone
        // held open is the input the session is heard through from its first sample; one
        // opened for it is added by the launch that opens it.
        let held: [MicrophoneInput] = if case .running(let live) = started.engine { [live.input] } else { [] }
        shared.stream.withLock { $0.arrivals = Arrivals(inputs: held) }
        switch started.engine {
        // Held open by the resting mode, and left alone: relaunching splices the ring, and
        // the audio it would splice off is exactly the look-back this mode is held open to
        // keep. The clearing above is right for a held microphone too, and dating the head
        // by the key instead would be wrong. Its buffers run continuously, so the first to
        // arrive after the key was captured at or before the key went down and the head
        // reads as heard; and a press a held engine delivers nothing for leaves this empty
        // and is reported unopened, exactly as a press whose own microphone never opened
        // is. Dating by the key would answer zero either way and take that door off a mode
        // that runs for hours. [LAW:no-silent-failure]
        case .running:
            break
        // Opened for this press.
        case .shut:
            do {
                started.engine = .running(try launch(on: started.prepared))
            } catch {
                // What failed may have been the device going away, and the input prepared
                // against it cannot open the one that replaced it. Readying another costs
                // no device and leaves the next press something that can open, where
                // keeping this one would refuse every press until capture is restarted.
                // The engine stays shut: recording a failure here is what the case below
                // exists not to do, because a failed engine left behind lets the next
                // device change hold open a microphone `shut` asked to keep closed.
                ready(&started)
                phase = .started(started)
                throw NoMicrophone.failed(error)
            }
        // A press is a reason to try the device again, and the alternative is a resting
        // microphone that stays dead until one is replugged. Recorded either way, which
        // `shut` above deliberately does not do: leaving a failed engine behind there
        // would let the next device change reach `recover()` with no session open and
        // hold the microphone a config asked to keep closed.
        case .failed(_, let since, let failedOn):
            do {
                try retry(&started, failedOn: failedOn, since: since)
            } catch {
                phase = .started(started)
                throw NoMicrophone.failed(error)
            }
        }
        started.sessionIsOpen = true
        phase = .started(started)
        return shared.stream.withLock { stream in
            // One floor for the mark and for what the mark reaches back over: the
            // position this run of capture began at. [LAW:one-source-of-truth]
            let opened = stream.continuousSince
            let session = AudioSession(
                beginningAt: min(max(stream.timeline.position(at: moment), opened), stream.ring.end),
                at: moment,
                preRoll: preRoll,
                notReachingBefore: opened
            )
            // A key that lands among samples already delivered - a held microphone, and a
            // handler that ran after its buffers - has its head among them, captured from
            // the key on. [LAW:one-source-of-truth] The session's first sample is the one at
            // its begin mark, whichever lock it landed under.
            stream.arrivals.first = stream.arrivals.first ?? (session.begin < stream.ring.end ? moment : nil)
            return session
        }
    }

    /// Marks where `session` ends, yields its audio, and gives the microphone back to its
    /// resting state - which closes it unless the user asked for it to be held: the
    /// pre-roll, then everything captured since it began, and whether that is all of it.
    /// The end mark, the slice and what the slice is missing are taken under one lock, so
    /// a buffer arriving in between cannot separate them.
    ///
    /// [LAW:parse-dont-validate] This is the border a press's audio crosses, and it is
    /// the last place any of the losses can be seen: the ring clamps a range it cannot
    /// fill and hands back a shorter clip, a break between two engines leaves no mark in
    /// the samples at all, and a microphone that never opened leaves no samples to mark.
    /// So what crosses is a `CapturedAudio`, which cannot be read as whole unless it is.
    public func endSession(_ session: AudioSession) -> CapturedAudio {
        end(session, scrolledOff: { ring, range in ring.scrolledOff(from: range) }) { stream, range, lost in
            let clip = stream.ring.clip(in: range)
            return lost.map { .partial(clip, lost: $0) } ?? .whole(clip)
        }
    }

    /// Ends a session whose audio was streamed: what was missing from it, and what the
    /// microphone delivered for it. No clip, because the stream already handed every sample
    /// over. [LAW:types-are-the-program] The ring scrolling past a streamed session loses
    /// nothing, since each buffer reached the stream as it landed; only what the ring had
    /// dropped before the stream began is missing.
    public func endSession(_ streamed: StreamedSession) -> StreamedSession.Ending {
        end(streamed.session, scrolledOff: { _, _ in streamed.missed }) { stream, _, lost in
            // [LAW:one-source-of-truth] Positions advance only on capture, so the session's
            // own stretch of them is what it was delivered: the clip its transcriber heard,
            // less the pre-roll. Read once here rather than counted as each buffer lands.
            let own = streamed.session.begin..<stream.ring.end
            return StreamedSession.Ending(lost: lost, reading: CapturedAudio.Reading(
                inputs: stream.arrivals.inputs,
                samples: own.count,
                peak: stream.ring.clip(in: own).peak,
                firstSample: stream.arrivals.first.map(streamed.session.unheard(since:))
            ))
        }
    }

    /// The end both kinds of session share: the end mark, the losses and what is delivered
    /// are taken under one lock, the feed finished with them, and the microphone given back.
    private func end<Delivered>(
        _ session: AudioSession,
        scrolledOff: (AudioRing, Range<Int>) -> Int,
        deliver: (Stream, Range<Int>, CapturedAudio.Loss?) -> Delivered
    ) -> Delivered {
        let open = isOpen
        let delivered = shared.stream.withLock { stream -> Delivered in
            let range = session.range(endingAt: stream.ring.end)
            let lost = Self.loss(of: session, in: stream, scrolledOff: scrolledOff(stream.ring, range), open: open, ended: true)
            stream.feed?.finish()
            stream.feed = nil
            return deliver(stream, range, lost)
        }
        rest()
        return delivered
    }

    /// What a streamed session still open is already known to be missing, or nil while all
    /// of it has streamed so far. A head the ring dropped, a microphone that opened late and
    /// a break in capture are each known the moment they happen and never heal, so what this
    /// reads, `endSession` reads too; it can only learn more by then.
    public func missing(from streamed: StreamedSession) -> CapturedAudio.Loss? {
        guard case .started(let started) = phase, started.sessionIsOpen else {
            preconditionFailure("a session's losses were asked for with no session open; its end is what says them")
        }
        let open = isOpen
        return shared.stream.withLock { Self.loss(of: streamed.session, in: $0, scrolledOff: streamed.missed, open: open, ended: false) }
    }

    /// What `session` lacks as `stream` stands, read under its lock. [LAW:one-source-of-truth]
    /// The reading the end of a session and an open one's `missing` share.
    private static func loss(of session: AudioSession, in stream: Stream, scrolledOff: Int, open: Bool, ended: Bool) -> CapturedAudio.Loss? {
        // Where the session's own audio starts among the positions that exist: the pre-roll
        // may reach back before the first sample ever captured, and audio that never existed
        // was not lost.
        let began = session.range(endingAt: stream.ring.end).clamped(to: 0..<stream.ring.end).lowerBound
        // How long the session waited for its microphone, and a wait that never ended for
        // one nothing was ever delivered for - a hold shorter than the engine took to start,
        // or one whose engine never started. That is the same sentence about the whole press
        // that lateness is about its head, so it is the same reading rather than one of its
        // own. [LAW:one-source-of-truth] A session still open that nothing has reached yet
        // has missed nothing yet: what it is waiting for may still come in time.
        let openedLate = stream.arrivals.first
            .map { session.unheard(since: $0) > .seconds(warmUpAllowance) } ?? ended
        return CapturedAudio.Loss(
            scrolledOff: scrolledOff,
            interrupted: began < stream.continuousSince,
            // Two readings of one fact - the microphone was not open for part of this
            // session. It opened so long after the key went down that the stretch in
            // between is speech rather than warm-up, which takes the head; or it was gone
            // by the time the key came up, or is gone now, which takes the tail.
            unopened: openedLate || !open
        )
    }

    /// An open session whose audio is streamed as it is captured, ended by
    /// `endSession(_: StreamedSession)`.
    public struct StreamedSession: Sendable {
        fileprivate let session: AudioSession
        /// What the ring already holds of the session, then each buffer as it lands,
        /// finished when the session ends.
        public let audio: AsyncStream<AudioClip>
        /// Samples of the session the ring had dropped before the stream began.
        fileprivate let missed: Int

        /// How a streamed session ended: what it is missing, or nil when the stream carried
        /// all of it, and what the microphone delivered for it.
        public struct Ending: Sendable {
            public let lost: CapturedAudio.Loss?
            public let reading: CapturedAudio.Reading
        }
    }

    /// Streams the open session's audio as it is captured. A decoder fed this hears the press
    /// while it is still going on. [LAW:one-source-of-truth] The ring is read and the feed
    /// attached under one lock, so no buffer lands between the two to be missed or heard twice.
    ///
    /// Whether what was heard is whole is still the end's to say: a stream cannot know it was
    /// spliced or began late, and the loss its end returns does.
    public func stream(_ session: AudioSession) -> StreamedSession {
        guard case .started(let started) = phase, started.sessionIsOpen else {
            preconditionFailure("a session's audio was asked for with no session open; nothing would ever finish it")
        }
        let (audio, feed) = AsyncStream<AudioClip>.makeStream()
        let missed = shared.stream.withLock { stream in
            precondition(stream.feed == nil, "a session's audio is handed out once")
            let range = session.range(endingAt: stream.ring.end)
            feed.yield(stream.ring.clip(in: range))
            stream.feed = feed
            return stream.ring.scrolledOff(from: range)
        }
        return StreamedSession(session: session, audio: audio, missed: missed)
    }

    /// Holds the grant, watches the input device, and brings the microphone to its resting
    /// state. The grant is the proof the user allowed it: without one, macOS lets an engine
    /// run and hands it silence, which nothing downstream could tell from a quiet room.
    ///
    /// Under `shut`, which is what the app runs on when no config file asks for anything
    /// else, no engine launches here: the microphone opens when a session does, which is
    /// what keeps the menu-bar indicator a record of use rather than of uptime. Under
    /// `open` the engine launched here is the one every press speaks into, and an
    /// indicator lit for the life of the process is what the user asked for by writing it
    /// down. A launch that fails leaves capture started and failed rather than throwing:
    /// the device watch is up by then, so a microphone that appears later is picked up the
    /// same way one that disappears mid-press is.
    public func start(_ grant: MicrophoneGrant, atRest: MicrophoneAtRest) throws {
        stop()
        deviceChanges = 0
        outages = Outages()
        phase = .started(Started(
            watch: try hardware.watchDefaultInput { [weak self] in self?.recover() },
            grant: grant,
            atRest: atRest,
            engine: .shut,
            // Readying starts here rather than at the first press, which is the point: this is
            // the moment the app has time to spare, and a press is the moment it has
            // none. No device is opened by it, so a Mac nobody has dictated to still
            // shows no microphone.
            prepared: readiedInput()
        ))
        rest()
    }

    /// What the microphone does between presses from now on, for capture that is started.
    /// With no session open the microphone goes there at once; with one open, the key-up that
    /// ends it takes it there, so a saved config never cuts a recording short.
    public func rest(as atRest: MicrophoneAtRest) {
        guard case .started(var started) = phase, started.atRest != atRest else { return }
        started.atRest = atRest
        phase = .started(started)
        if !started.sessionIsOpen { rest() }
    }

    /// Waits for the microphone a press would open to finish being readied.
    ///
    /// `start` returns with readying still under way, which is right for a device change and
    /// not for a caller about to let presses in: the first press would pay what is left of a
    /// cold readying, which is the first-press refusal `start` readies to prevent. So a caller
    /// that installs a hotkey, or presses itself, waits here first. What readying came to is
    /// the press's to report, and capture that is not started has nothing being readied.
    /// [LAW:no-ambient-temporal-coupling]
    public func waitUntilReadied() {
        guard case .started(let started) = phase else { return }
        started.prepared.waitUntilReadied()
    }

    public func stop() {
        if case .started(let started) = phase {
            if case .running(let live) = started.engine { dispose(live) }
            started.watch()
        }
        phase = .stopped
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    deinit { MainActor.assumeIsolated { stop() } }

    private var isOpen: Bool {
        guard case .started(let started) = phase, case .running = started.engine else { return false }
        return true
    }

    /// Retires an engine: the stream stops accepting what it delivers, and then its input
    /// closes. Every path that lets an engine go comes through here, because one that
    /// retired an engine without telling the stream would leave a render already under way
    /// a buffer's reach into the audio the next press begins from. [LAW:single-enforcer]
    ///
    /// [LAW:no-ambient-temporal-coupling] The order is the whole of it. Closing the input
    /// first leaves a window in which a buffer already on its way can take the lock
    /// before the clearing does, read the generation it was formed for, and be admitted -
    /// so the guard would hold only as often as it won a race. Clearing first closes it
    /// from both sides: nothing sets `accepting` again until the next `launch()`, so a
    /// straggler is refused however its render interleaves with the close.
    private func dispose(_ live: Live) {
        shared.stream.withLock { $0.accepting = nil }
        live.dispose()
    }

    /// Readies a microphone against whatever the default input is now.
    private func ready(_ started: inout Started) {
        started.prepared = readiedInput()
    }

    /// A microphone readied against whatever the default input is now, wired so that the
    /// device it ends up bound to going away or changing shape arrives at `inputWentStale`.
    ///
    /// [LAW:one-source-of-truth] The one place a preparation is wired, so the two moments one
    /// is made - starting capture, and replacing a stale one - cannot disagree about what
    /// watches it.
    private func readiedInput() -> any PreparedInput {
        preparations += 1
        let preparation = preparations
        return hardware.prepareInput { [weak self] in self?.inputWentStale(from: preparation) }
    }

    /// Lets the press go and brings the microphone to what it does while no session is
    /// open.
    ///
    /// [LAW:single-enforcer] The one place the resting mode is read. `start()` and the
    /// key-up that ends a press are the two moments no session is open, and both arrive
    /// here, so neither can leave the microphone in a state the other would not have left
    /// it in - which is what makes "the device is closed unless the file says otherwise" a
    /// property of one function rather than an agreement between two.
    private func rest() {
        guard case .started(var started) = phase else { return }
        started.sessionIsOpen = false
        // The default input may have changed under the press that just ended, and answering
        // that was put off to here rather than cutting the recording. Done before the resting
        // mode is read, so what the mode does next it does with the new device: `shut` holds a
        // microphone readied against it, and `open` launches on it rather than relaunching
        // on the one the press was holding.
        //
        // [LAW:no-ambient-temporal-coupling] Asked of the input rather than of anything the
        // notification left behind. The watch fires once per change, and CoreAudio can deliver
        // it before or after the bound device's own report that readies a replacement mid-press
        // - so a record of what was owed could be written after the debt was paid, and this
        // key-up would then tear down a microphone already on the right device. Whether the
        // input is on the default is true or false whichever report came first.
        //
        // Only a running engine is given up. The press's engine can have died between the
        // change and here, and that engine's outage is still open: taking it to `.shut`
        // would drop the reason and the moment it began, and `open` would relaunch over the
        // top of a gap nothing had booked. Readying is the half that is owed either way -
        // skip it for a failed engine and the next press opens the device that stopped
        // being the default, which is the whole of what this defers. [LAW:no-silent-failure]
        let owed = !started.prepared.isOnTheDefaultInput
        // Readied, unless the resting mode below launches on the new default.
        var answer = DeviceReport.Answer.readied
        if owed {
            if case .running(let live) = started.engine {
                dispose(live)
                started.engine = .shut
            }
            ready(&started)
        }
        switch started.atRest {
        case .shut:
            if case .running(let live) = started.engine { dispose(live) }
            started.engine = .shut
        case .open:
            switch started.engine {
            // Already open, and kept open across the key-up: the ring stays continuous, so
            // the next press's pre-roll has audio to reach back over. A failed one waits
            // on the device watch exactly as it does mid-press.
            case .running, .failed:
                break
            case .shut:
                do { started.engine = .running(try launch(on: started.prepared)) }
                catch { started.engine = .failed(error, since: .now, on: preparations) }
                answer = .launched(Self.outcome(of: started.engine))
            }
        }
        phase = .started(started)
        // The answer `leftForTheKeyUp` promised, given now. [LAW:nothing-unseen]
        if owed { reporting(DeviceReport(cause: .pressEndedOffTheDefault, answer: answer)) }
    }

    /// Books the end of a gap in capture. [LAW:single-enforcer] A device that came back is
    /// the same event whether the watch noticed it or a press did, so both arrive here and
    /// the count cannot depend on which of the two got there first.
    private func closeOutage(since: ContinuousClock.Instant) {
        outages.count += 1
        outages.total += .now - since
    }

    private func launch(on prepared: any PreparedInput) throws -> Live {
        let shared = shared
        generation += 1
        let generation = generation
        // Everything the engine about to launch captures lands from here on, and
        // everything already in the ring came from one that stopped. Marked before the
        // launch rather than after it: the new engine delivers on its own thread, and a
        // buffer that landed before the mark was taken would move the mark past audio
        // the break had already cost, so a session begun after the break would be told
        // it spanned one. [LAW:no-ambient-temporal-coupling]
        let resuming = shared.stream.withLock { stream -> Int in
            let previous = stream.continuousSince
            stream.continuousSince = stream.ring.end
            stream.accepting = generation
            return previous
        }
        do {
            let opened = try prepared.open(
                appending: { samples, time in
                    shared.stream.withLock {
                        // Resolved by generation rather than trusted by arrival, as the
                        // other two callbacks already are: a buffer from an engine that has
                        // been disposed is a let-go press's audio, and the ring it would
                        // land in is where the next press begins.
                        guard $0.accepting == generation else { return }
                        // The buffer's first sample takes the position the ring is at, and
                        // that is the sample its stamp dates.
                        $0.timeline.mark($0.ring.end, at: time)
                        $0.arrivals.first = $0.arrivals.first ?? time
                        $0.ring.append(samples)
                        $0.feed?.yield(AudioClip(samples: samples))
                    }
                },
                onFailure: { [weak self] error in self?.fail(error, from: generation) }
            )
            shared.stream.withLock { $0.arrivals.inputs.append(opened.input) }
            return Live(dispose: opened.dispose, generation: generation, input: opened.input)
        } catch {
            // Nothing took over, so nothing resumed: no input opened and no buffer
            // can have landed. A mark left standing forward of the last engine's audio
            // would tell the session that ends here it was spliced where capture in fact
            // simply stopped, which is a different sentence and a false one.
            // [FRAMING:representation]
            shared.stream.withLock { $0.continuousSince = resuming }
            throw error
        }
    }

    /// The device changed under a running engine: macOS already stopped it, and it never
    /// delivers again.
    ///
    /// Takes the engine to give up rather than a generation to find one by. Both callers have
    /// just matched one from the phase they are holding, and the callback that had to be
    /// resolved by generation - the engine's own configuration change - is the readied
    /// input's now and arrives at `inputWentStale`. [LAW:polishing-by-subtraction]
    private func replaceEngine(_ started: inout Started, _ live: Live) {
        dispose(live)
        do {
            // The device this was prepared against is not the one to open any more: it went
            // away, or it stopped being the default while nothing was recording it.
            ready(&started)
            started.engine = .running(try launch(on: started.prepared))
            deviceChanges += 1
        } catch {
            started.engine = .failed(error, since: .now, on: preparations)
        }
    }

    /// The device a readied microphone is bound to went away or changed shape. It can happen
    /// at any point in that microphone's life and not only while a press holds it open, which
    /// is the whole of why the watch behind this belongs to the input - see
    /// `AudioHardware.prepareInput`. Either way the input is no longer one to open, so both
    /// arms of this end in a fresh one.
    ///
    /// A running engine is replaced here and now, where `recover()` may leave a press
    /// recording: the device under that one is still the device it was opened on, and this is
    /// the case where it is not. macOS has already stopped the engine and it never delivers
    /// again, so a press left on it would record its remaining seconds into silence - a new
    /// engine on the device that replaced it salvages the rest of the utterance, and the
    /// splice is what the session reports. [LAW:no-silent-failure]
    ///
    /// A microphone that is merely readied has nothing to give up, so it is simply readied
    /// again - which opens no device, and is what closes the resting stretch this whole
    /// change is about.
    private func inputWentStale(from preparation: Int) {
        // Not the microphone a press would open any more, so nothing it says is about one.
        // A notification posted before its input was let go can arrive after, and acting on
        // it would give up an engine running healthily on the input that replaced it.
        guard case .started(var started) = phase, preparation == preparations else {
            reporting(DeviceReport(cause: .boundDeviceChanged, answer: .outdated))
            return
        }
        let answer: DeviceReport.Answer
        switch started.engine {
        case .running(let live):
            replaceEngine(&started, live)
            answer = .launched(Self.outcome(of: started.engine))
        // A failed engine is left failed: it is not this device's turn again until a press
        // or the default-input watch says so, and the input readied here is the one either
        // of them retries on - see `retry`.
        case .shut, .failed:
            ready(&started)
            answer = .readied
        }
        phase = .started(started)
        reporting(DeviceReport(cause: .boundDeviceChanged, answer: answer))
    }

    /// The default input device changed - which device a press should open, not anything
    /// about the one it is open on. That is the whole difference from `inputWentStale`: the
    /// bound device is still alive and still the shape it was, so a press on it is left
    /// recording and only the *next* one owes anything. A failed engine has no device to
    /// stay on, so this is also how one reaches a device that appeared; a launch that fails
    /// again (the device that appeared cannot feed the pipeline either) extends the same
    /// outage.
    ///
    /// A shut microphone is not woken by this. Nobody is holding the key, so nobody is
    /// dictating, and a device appearing is not a reason to start listening to it. What a
    /// shut microphone does do is ready itself against the device that is now the default:
    /// preparing opens nothing and lights no indicator, and skipping it left the next press
    /// launching on an input bound to a device that had stopped being the default - which a
    /// press has no way to notice and no way to recover from, because the `shut` branch of
    /// `beginSession` deliberately records no failure.
    private func recover() {
        guard case .started(var started) = phase else {
            reporting(DeviceReport(cause: .defaultInputChanged, answer: .outdated))
            return
        }
        let answer: DeviceReport.Answer
        switch started.engine {
        // Already answered: the bound device's own report reached here first and readied an
        // input on the new default. A second answer would give up a microphone on the right
        // device for an identical one, and under `open` would splice the look-back to do it.
        // A failed engine is not asked, because a default-input change is also how one tries
        // a device again. [LAW:no-ambient-temporal-coupling]
        case .shut where started.prepared.isOnTheDefaultInput, .running where started.prepared.isOnTheDefaultInput:
            answer = .alreadyOnIt
        // A running engine owns the input it was launched on: the disposal it holds is weak,
        // so `prepared` is the only strong reference to the open input and replacing it under
        // a live press would deinit the device out from under it. That is also the right
        // answer on its own terms - a switch of the default input is not a reason to cut the
        // recording the speaker is in the middle of making - and nothing is forgotten by
        // leaving it, because `rest()`, the moment "no session is open" becomes true, asks the
        // input whether it is still on the default.
        case .running where started.sessionIsOpen:
            answer = .leftForTheKeyUp
        // With no session open there is nothing to cut, and the engine is replaced on the new
        // default the same way a device that went away replaces it.
        case .running(let live):
            replaceEngine(&started, live)
            answer = .launched(Self.outcome(of: started.engine))
        case .shut:
            ready(&started)
            answer = .readied
        // What a retry that failed again came to is the engine it leaves failed, which is
        // what the status surface reads and what the report carries; there is no press here
        // to throw it to.
        case .failed(_, let since, let failedOn):
            try? retry(&started, failedOn: failedOn, since: since)
            answer = .launched(Self.outcome(of: started.engine))
        }
        phase = .started(started)
        reporting(DeviceReport(cause: .defaultInputChanged, answer: answer))
    }

    /// What a launch came to, read off the engine it left, by every path that launches on a
    /// device report rather than each saying it separately. [LAW:one-source-of-truth]
    private static func outcome(of engine: Engine) -> Result<Void, any Error> {
        switch engine {
        case .running: .success(())
        case .failed(let error, _, _): .failure(error)
        case .shut: preconditionFailure("a launch left no engine and no failure")
        }
    }

    /// Tries a failed engine again, from a press or from the device watch. [LAW:single-enforcer]
    /// Both are the same retry, so they cannot come to disagree about what it readies or how
    /// the outage it ends is booked.
    ///
    /// The input a failure happened on is readied again first: what failed may have been the
    /// device going away, and an input prepared against that one cannot open the one that
    /// replaced it. An input readied since the failure has failed nothing - a device report
    /// readies one while the engine is down - and replacing it too would make the retry wait
    /// for two readyings back to back, the one already under way, which cannot be taken back,
    /// and its replacement. It is kept unless it is for a device that is no longer the default.
    ///
    /// A retry that fails again leaves the gap running from where it began, carrying the
    /// newest reason: it started no new gap, and the reason it is dead now is the one the
    /// status surface has to show. [LAW:no-silent-failure]
    private func retry(_ started: inout Started, failedOn preparation: Int, since: ContinuousClock.Instant) throws {
        do {
            if preparation == preparations || !started.prepared.isOnTheDefaultInput {
                ready(&started)
            }
            started.engine = .running(try launch(on: started.prepared))
            closeOutage(since: since)
        } catch {
            started.engine = .failed(error, since: since, on: preparations)
            throw error
        }
    }

    /// A failure from an engine a device change has since replaced is stale: the
    /// engine it came from is gone and the one running is healthy.
    ///
    /// [LAW:no-ambient-temporal-coupling] The render callback's failure arrives
    /// asynchronously, so the engine it is about is resolved by generation rather than
    /// trusted by arrival - a replaced engine's late failure would otherwise fail the one
    /// that took over from it.
    private func fail(_ error: any Error, from generation: Int) {
        guard case .started(var started) = phase,
              case .running(let live) = started.engine,
              live.generation == generation else { return }
        dispose(live)
        started.engine = .failed(error, since: .now, on: preparations)
        phase = .started(started)
    }
}

/// One report from CoreAudio about the microphone's device, and what capture did about it.
public struct DeviceReport: CustomStringConvertible {
    public enum Cause: String {
        /// The system default input moved to another device.
        case defaultInputChanged = "the default input changed"
        /// The device a readied microphone is bound to went away or changed shape.
        case boundDeviceChanged = "the microphone's device went away or changed shape"
        /// A press ended on a device that stopped being the default while it recorded.
        case pressEndedOffTheDefault = "a press ended on an input that is no longer the default"
    }

    public enum Answer: CustomStringConvertible {
        /// The report is about a microphone already let go, so it spoke for nothing.
        case outdated
        /// A press is recording on a device that is still there; its key-up readies the new one.
        case leftForTheKeyUp
        /// The other report of the same change got here first.
        case alreadyOnIt
        /// A microphone was readied on the device that is now the default, and none was opened.
        case readied
        /// An engine was launched on the device that is now the default, and this is what it
        /// came to: running, or failed with the reason.
        case launched(Result<Void, any Error>)

        public var description: String {
            switch self {
            case .outdated: "nothing: it was about a microphone already let go"
            case .leftForTheKeyUp: "left the press recording; its key-up readies the new default"
            case .alreadyOnIt: "nothing: the microphone was already on the new default"
            case .readied: "readied a microphone on the default input"
            case .launched(.success): "relaunched the microphone on the default input"
            case .launched(.failure(let error)): "could not relaunch the microphone: \(error)"
            }
        }
    }

    public let cause: Cause
    public let answer: Answer

    public var description: String { "\(cause.rawValue); \(answer)" }
}

/// A press with no microphone behind it, refused at the key rather than heard.
public enum NoMicrophone: Error, CustomStringConvertible {
    /// Capture was never started, or has been stopped.
    case stopped
    /// The microphone could not be opened for this session.
    case failed(any Error)

    public var description: String {
        switch self {
        case .stopped: "WARNING: The microphone is not being captured. Your dictation was ignored."
        case .failed(let error): "WARNING: The microphone could not be opened: \(error). Your dictation was ignored."
        }
    }
}
