import AVFoundation
import Dispatch
import Grants
import Insertion
import LowTalkerCore
import Synchronization

/// Hardware a test feeds: one engine per opening, its samples the test's to append.
@MainActor
final class FakeHardware: AudioHardware {
    /// A microphone readied and not open. Readying one takes no device and cannot fail,
    /// which is what lets capture rest with one in hand.
    final class Input: PreparedInput {
        private unowned let hardware: FakeHardware
        /// Fired by a test to say the device this was readied against went away or changed
        /// shape. It belongs to the readied input rather than to an engine because that is
        /// where the real one lives, and that is what lets a test reach the stretch where
        /// the microphone is readied and nothing is open.
        let onStale: @MainActor () -> Void

        init(_ hardware: FakeHardware, onStale: @escaping @MainActor () -> Void) {
            self.hardware = hardware
            self.onStale = onStale
        }

        func open(
            appending: @escaping @Sendable ([Float], HostTime) -> Void,
            onFailure: @escaping @MainActor (any Error) -> Void
        ) throws -> OpenedInput {
            OpenedInput(dispose: try hardware.openEngine(appending: appending, onFailure: onFailure), input: FakeHardware.microphone)
        }

        /// This hardware's default input never changes; nothing here watches it.
        var isOnTheDefaultInput: Bool { true }

        func waitUntilReadied() {}
    }

    final class Engine {
        let appending: @Sendable ([Float], HostTime) -> Void
        let onFailure: @MainActor (any Error) -> Void

        init(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) {
            self.appending = appending
            self.onFailure = onFailure
        }
    }

    /// The one device this hardware has.
    static let microphone = MicrophoneInput(device: 1, name: .success("Fake Microphone"), sampleRate: 48_000, channels: 1)

    private(set) var engines: [Engine] = []
    /// What a launch does, once set: throw, as a device that cannot feed the pipeline
    /// does. The microphone opens per press now, so this is the shape of a Mac with
    /// nothing to record with at the moment a key goes down.
    var failingToLaunch: (any Error)?

    /// The engine that is open, which a launch sets and its disposal gives back, so it is
    /// empty exactly when the microphone is shut.
    private var open: Engine?

    /// The engine capture is listening to now, and a replaced one never delivers again.
    /// Under `shut` there is one only while a press is open, so speaking between presses
    /// is a test describing a Mac that does not exist; under `open` the microphone is held
    /// across them, and speaking before a press is the look-back that mode is held for.
    var live: Engine {
        guard let engine = open else { preconditionFailure("nothing is capturing; the microphone opens for a press unless the resting mode holds it") }
        return engine
    }

    /// The microphone capture is holding readied, which each readying replaces. Watched for
    /// its whole life on a real Mac, so it is reachable here for its whole life too.
    private var latestReadied: Input?

    var readied: Input {
        guard let latestReadied else { preconditionFailure("nothing has readied a microphone; capture readies one when it starts") }
        return latestReadied
    }

    func prepareInput(onStale: @escaping @MainActor () -> Void) -> any PreparedInput {
        let input = Input(self, onStale: onStale)
        latestReadied = input
        return input
    }

    fileprivate func openEngine(appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) throws -> Disposal {
        if let failingToLaunch { throw failingToLaunch }
        let engine = Engine(appending: appending, onFailure: onFailure)
        engines.append(engine)
        open = engine
        // Only while it is still the one open: a disposal arriving after its replacement
        // launched would shut a microphone that is listening.
        return { [weak self] in if self?.open === engine { self?.open = nil } }
    }

    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal { {} }
}

struct Authorized: MicrophoneAuthority {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

/// An engine that answers however the test says, and keeps what it was given to
/// hear. One fake for every behavior - a scripted transcript, a refusal, a wait on a
/// gate - since the answer is a value. [LAW:composability]
final class FakeTranscriber: Transcriber {
    private let heard = Mutex<[AudioClip]>([])
    private let told = Mutex<[Vocabulary]>([])
    private let arrived = Mutex<[Float]>([])
    private let reading: @Sendable ([Float]) -> Transcript
    private let confirming: @Sendable ([Float]) -> Transcript
    private let repunctuating: @Sendable ([Float]) -> Int
    private let quiet: Quiet
    private let answer: @Sendable (AudioClip) async throws(TranscriptionFailure) -> Transcript

    /// `reading` is what a pass makes of the audio so far and `confirming` the words two
    /// passes have agreed on, which the answer has to begin with, and `repunctuating` how
    /// many passes so far changed a settled word's punctuation; one pass runs per clip as
    /// it arrives, and reads and confirms nothing unless a test says otherwise. Every answer
    /// is told with `quiet`, none unless a test says otherwise.
    init(
        reading: @escaping @Sendable ([Float]) -> Transcript = { _ in Transcript(typed: "") },
        confirming: @escaping @Sendable ([Float]) -> Transcript = { _ in Transcript(typed: "") },
        repunctuating: @escaping @Sendable ([Float]) -> Int = { _ in 0 },
        quiet: Quiet = Quiet(letGo: 0, room: nil, refusedAsRoom: 0, transients: .none),
        _ answer: @escaping @Sendable (AudioClip) async throws(TranscriptionFailure) -> Transcript
    ) {
        self.reading = reading
        self.confirming = confirming
        self.repunctuating = repunctuating
        self.quiet = quiet
        self.answer = answer
    }

    /// Every utterance so far, each as the one clip its audio added up to.
    var clips: [AudioClip] { heard.withLock { $0 } }
    /// What each utterance so far was heard expecting, in the order they were begun.
    var expected: [Vocabulary] { told.withLock { $0 } }
    /// The audio of the utterance being heard, as far as it has arrived and been read.
    var hearing: [Float] { arrived.withLock { $0 } }

    func transcribe(_ audio: some AsyncSequence<AudioClip, Never> & Sendable, expecting vocabulary: Vocabulary, partial: @escaping @Sendable (Partial) -> Void) async throws(TranscriptionFailure) -> Transcription {
        told.withLock { $0.append(vocabulary) }
        var samples: [Float] = []
        for await clip in audio {
            samples += clip.samples
            partial(Partial(confirmed: confirming(samples), tentative: reading(samples), repunctuated: repunctuating(samples)))
            arrived.withLock { $0 = samples }
        }
        let clip = AudioClip(samples: samples)
        heard.withLock { $0.append(clip) }
        return Transcription(transcript: try await answer(clip), quiet: quiet)
    }
}

/// An input method that records every text it put at the cursor, answers that it reached
/// the app it is told, refuses an insert bound to another app as the real one does, and
/// refuses or holds an insert when a test says so. One fake for every
/// behavior, since each is a value. [LAW:composability]
///
/// Asked on a thread of the executor's choosing: `Inserter`'s awaited overload puts the
/// blocking call on a thread of its own, which is also what lets a held insert block here
/// without holding the main actor.
final class FakeInputMethod: Inserter, Sendable {
    private struct State {
        var inserted: [String] = []
        var into = "com.apple.TextEdit"
        var refusal: InsertFailure?
        var gate: DispatchSemaphore?
        var holding = 0
    }

    private let state = Mutex(State())

    /// Every text put at the cursor, in order. A held insert is not in it until it is let go.
    var inserted: [String] { state.withLock { $0.inserted } }
    /// How many inserts are held at the gate now.
    var holding: Int { state.withLock { $0.holding } }

    /// The app the next inserts say they reached.
    func reaching(_ app: BundleID) { state.withLock { $0.into = app.rawValue } }
    /// Every insert from now on is refused with `refusal`, or none is when it is nil.
    func refusing(_ refusal: InsertFailure?) { state.withLock { $0.refusal = refusal } }
    /// Every insert from now on waits until `letGo`, the way a real one waits for the app to
    /// answer - held at a gate rather than for a duration. [LAW:no-ambient-temporal-coupling]
    func hold() { state.withLock { $0.gate = DispatchSemaphore(value: 0) } }
    /// Lets the held insert through, and holds none after it.
    func letGo() {
        let gate = state.withLock { state in
            defer { state.gate = nil }
            return state.gate
        }
        gate?.signal()
    }

    func insert(_ text: String, into destination: Destination) throws(InsertFailure) -> Inserted {
        if let gate = state.withLock({ $0.gate }) {
            state.withLock { $0.holding += 1 }
            gate.wait()
            state.withLock { $0.holding -= 1 }
        }
        return try state.withLock { state throws(InsertFailure) in
            if let refusal = state.refusal { throw refusal }
            guard destination.admits(state.into) else { throw .refused(.dictationIsInAnotherApp) }
            state.inserted.append(text)
            return Inserted(characters: text.count, into: state.into)
        }
    }
}
