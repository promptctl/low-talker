import AVFoundation
import Grants
import LowTalkerCore
import Testing

private struct NoDevice: Error, Equatable {}
private struct BadBuffer: Error, Equatable {}

/// Hardware a test controls: each opening takes the next scripted outcome, every engine's
/// and every readied input's callbacks are the test's to fire, and the default input device
/// changes when the test says so.
///
/// Readying a microphone and opening one are counted apart, because the difference is
/// what keeps `shut` affordable and a test that could not see it could not hold the
/// difference in place.
@MainActor
private final class FakeHardware: AudioHardware {
    /// A microphone readied and not open: opening it is what takes the next scripted
    /// outcome, so preparing one costs a test nothing and proves nothing was opened.
    final class Input: PreparedInput {
        private unowned let hardware: FakeHardware
        /// Which readying this one came from, counting from one. A prepared input is
        /// bound to the device that was default when it was readied, so this is the only
        /// thing a test can say "the press opened the microphone readied against the new
        /// device" with - a count of readyings says one happened, not which one was used.
        let readying: Int
        /// The device that was the default when this was readied, which is the device a real
        /// input binds to.
        let device: Int
        /// Fired by a test to say the device this was readied against went away or changed
        /// shape. It belongs to the readied input rather than to an engine because that is
        /// where the real one lives, and that is what lets a test reach the stretch where the
        /// microphone is readied and nothing is open - the stretch nothing could reach while
        /// this was a parameter of `open`.
        let onStale: @MainActor () -> Void

        /// Whether readying has finished: at once, unless the hardware holds readying back,
        /// and then when the test calls `finishReadying()`.
        private(set) var isReadied: Bool
        /// Whoever is waiting for readying to finish.
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// How many waits are waiting for readying to finish, which is how a test sees a wait
        /// reach this input.
        var waiters: Int { waiting.count }

        init(_ hardware: FakeHardware, readying: Int, onStale: @escaping @MainActor () -> Void) {
            self.hardware = hardware
            self.readying = readying
            device = hardware.defaultInput
            isReadied = !hardware.holdsReadying
            self.onStale = onStale
        }

        func finishReadying() {
            isReadied = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func open(
            appending: @escaping @Sendable ([Float], HostTime) -> Void,
            onFailure: @escaping @MainActor (any Error) -> Void
        ) throws -> OpenedInput {
            OpenedInput(dispose: try hardware.open(on: self, appending: appending, onFailure: onFailure), input: microphone)
        }

        /// The device this is bound to, as an open says it.
        var microphone: MicrophoneInput {
            MicrophoneInput(device: AudioObjectID(device), name: .success("Device \(device)"), sampleRate: 48_000, channels: 1)
        }

        var isOnTheDefaultInput: Bool { device == hardware.defaultInput }

        func waitUntilReadied() async {
            if isReadied { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    final class Engine {
        /// The readied microphone this engine was opened on. Held rather than copied from, so
        /// `engine.input.onStale()` is how a test says the device under a running engine
        /// changed and the two cannot come apart. [LAW:one-source-of-truth]
        let input: Input
        let appending: @Sendable ([Float], HostTime) -> Void
        let onFailure: @MainActor (any Error) -> Void
        var disposed = false

        /// Which readying this engine was opened on, read off that input.
        var readying: Int { input.readying }

        init(input: Input, appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) {
            self.input = input
            self.appending = appending
            self.onFailure = onFailure
        }
    }

    /// What each opening does, in order: an error to throw, or nil to succeed. An
    /// opening past the end of the script succeeds.
    private var launches: [(any Error)?]
    /// What `watchDefaultInput` does: an error to throw, or nil to watch.
    private let watch: (any Error)?
    private(set) var engines: [Engine] = []
    private(set) var onDefaultInputChange: (@MainActor () -> Void)?
    private(set) var watchDisposals = 0
    /// Every microphone readied, in the order they were readied. Kept rather than counted,
    /// because a readied input is watched for its whole life and a test that could only
    /// count them could not reach one that was never opened.
    private(set) var inputs: [Input] = []
    /// Which device is the system default input. Moved apart from the notification that
    /// announces it, because CoreAudio delivers that notification in no fixed order against
    /// the bound device's own reports, and a test has to be able to land either one first.
    private(set) var defaultInput = 1

    /// How many microphones have been readied. Never a device: the count exists so a
    /// test can say that resting readied one and opened nothing.
    var prepared: Int { inputs.count }

    /// Whether a microphone readied here stays readying until the test finishes it, which is
    /// how a test reaches the stretch a slow input spends being reached.
    let holdsReadying: Bool

    init(launches: [(any Error)?] = [], watch: (any Error)? = nil, holdsReadying: Bool = false) {
        self.launches = launches
        self.watch = watch
        self.holdsReadying = holdsReadying
    }

    func prepareInput(onStale: @escaping @MainActor () -> Void) -> any PreparedInput {
        let input = Input(self, readying: inputs.count + 1, onStale: onStale)
        inputs.append(input)
        return input
    }

    fileprivate func open(on input: Input, appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) throws -> Disposal {
        if let error = launches.isEmpty ? nil : launches.removeFirst() { throw error }
        let engine = Engine(input: input, appending: appending, onFailure: onFailure)
        engines.append(engine)
        return { engine.disposed = true }
    }

    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let watch { throw watch }
        onDefaultInputChange = onChange
        return { [self] in
            onDefaultInputChange = nil
            watchDisposals += 1
        }
    }

    var isWatching: Bool { onDefaultInputChange != nil }

    /// The system default input device changed, and the watch was told.
    func changeDefaultInput() throws {
        moveDefaultInput()
        try announceDefaultInput()
    }

    /// Another device became the default input, and the notification saying so has not
    /// landed yet.
    func moveDefaultInput() { defaultInput += 1 }

    /// The notification that the default input changed lands.
    func announceDefaultInput() throws {
        let onChange = try #require(onDefaultInputChange, "nothing is watching the default input")
        onChange()
    }
}

extension AudioCapture {
    /// A capture whose device reports no test here reads; the ones that read them say so.
    convenience init(retaining duration: TimeInterval = defaultRetention, hardware: any AudioHardware, startingAt origin: HostTime = .now) {
        self.init(retaining: duration, hardware: hardware, startingAt: origin, reporting: { _ in })
    }
}

/// The order the two reports of one unplug land in. Unplugging the default input moves the
/// default and kills the device the microphone is bound to, and CoreAudio orders neither
/// report against the other.
enum UnplugReports: CaseIterable, Sendable {
    case defaultFirst
    case deviceFirst
}

private struct Authorized: MicrophoneAuthority {
    func status() -> AVAuthorizationStatus { .authorized }
    func requestAccess() async -> Bool { true }
}

@MainActor
@Suite struct AudioCaptureTests {
    private let grant = try! MicrophonePermission(authority: Authorized()).current.grant()
    /// Where every capture in this suite starts its timeline; any moment would do.
    private let origin = HostTime(uptime: .zero)

    /// The moment the sample at position `count` is captured, at the pipeline rate.
    private func after(_ count: Int) -> HostTime { origin + .seconds(AudioClip.duration(for: count)) }

    private func isRunning(_ capture: AudioCapture) -> Bool {
        if case .running = capture.state { return true }
        return false
    }

    /// Lets what is queued on the main actor run until `holds` is true, and fails if it never is.
    private func untilItHolds(_ holds: () -> Bool) async throws {
        for _ in 0..<1000 where !holds() { await Task.yield() }
        try #require(holds())
    }

    private func isListening(_ capture: AudioCapture) -> Bool {
        if case .listening = capture.state { return true }
        return false
    }

    private func failure<E: Error & Equatable>(of capture: AudioCapture, as: E.Type) -> E? {
        if case .failed(let error) = capture.state { return error as? E }
        return nil
    }

    /// The loss a partial capture is expected to carry. A `Loss` refuses to be nothing,
    /// so an expectation of one is spelled out here and the test reads as an equality.
    private func loss(scrolledOff: Int = 0, interrupted: Bool = false, unopened: Bool = false) throws -> CapturedAudio.Loss {
        try #require(CapturedAudio.Loss(scrolledOff: scrolledOff, interrupted: interrupted, unopened: unopened))
    }

    /// A capture that is started and listening, with a session open on it. Shut at rest
    /// unless a test says otherwise, which is how the app runs when no config file asks
    /// for anything else. Every test that needs audio needs one.
    private func opened(_ capture: AudioCapture, atRest: MicrophoneAtRest = .shut, at moment: HostTime? = nil, preRoll: TimeInterval = 0) async throws -> AudioSession {
        try await capture.start(grant, atRest: atRest)
        return try capture.beginSession(at: moment ?? origin, preRoll: preRoll)
    }

    /// The whole point of the epic, and the default a Mac with no config file gets: a
    /// started capture holds the grant and watches the input device, and opens no
    /// microphone at all. macOS shows a microphone for an engine that is running, so an app
    /// that starts one at launch is an app the menu bar says is listening all day.
    ///
    /// It readies one, and that is the other half of the sentence: readying takes no device
    /// and lights nothing, so doing it here - while nobody is dictating - is what leaves a
    /// press paying only what opening costs.
    @Test func startReadiesAMicrophoneOpensNoneAndWatchesTheDefaultInput() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try await capture.start(grant, atRest: .shut)
        #expect(isListening(capture))
        #expect(hardware.prepared == 1)
        #expect(hardware.engines.isEmpty)
        #expect(hardware.isWatching)
    }

    /// Start comes back only once the microphone a press would open is readied, and suspends
    /// rather than holding the main actor until then: this suite runs on the main actor, and
    /// reads capture while a start is still waiting. A microphone held open is launched only
    /// after readying, so the launch never waits on it.
    @Test func startWaitsForReadyingWithoutHoldingTheMainActorAndOnlyThenHoldsTheMicrophone() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let capture = AudioCapture(hardware: hardware)
        let starting = Task { try await capture.start(grant, atRest: .open) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }
        #expect(hardware.engines.isEmpty)
        hardware.inputs[0].finishReadying()
        try await starting.value
        #expect(hardware.engines.map(\.readying) == [1])
        #expect(!hardware.engines[0].disposed)
    }

    /// A device change while start waits readies another microphone, and start waits for that
    /// one in turn: the one it replaced being reached says nothing about the one a press would
    /// open.
    @Test func aDeviceChangeWhileStartWaitsIsWaitedOnInTurn() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let capture = AudioCapture(hardware: hardware)
        let starting = Task { try await capture.start(grant, atRest: .open) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }
        try hardware.changeDefaultInput()
        hardware.inputs[0].finishReadying()
        try await untilItHolds { hardware.inputs.count == 2 && hardware.inputs[1].waiters == 1 }
        #expect(hardware.engines.isEmpty)
        hardware.inputs[1].finishReadying()
        try await starting.value
        #expect(hardware.engines.map(\.readying) == [2])
    }

    /// A stop while start waits, which is what a quit during the come-up does, leaves nothing
    /// to start: start comes back with capture stopped and no microphone held, though the
    /// config asked for one.
    @Test func aStopWhileStartWaitsLeavesCaptureStoppedAndHoldsNothing() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let capture = AudioCapture(hardware: hardware)
        let starting = Task { try await capture.start(grant, atRest: .open) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }
        capture.stop()
        hardware.inputs[0].finishReadying()
        try await starting.value
        #expect(hardware.engines.isEmpty)
        if case .stopped = capture.state {} else { Issue.record("a start stopped while it waited should leave capture stopped") }
    }

    /// What readying early buys, and the one reading that would notice it being given back:
    /// a press opens the microphone the rest already readied rather than readying another,
    /// so it pays only what opening costs. A press that readied its own would pay both,
    /// which is over the allowance and came back refused on every hold.
    @Test func aPressOpensTheMicrophoneTheRestReadiedRatherThanReadyingAnother() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try await opened(capture)
        #expect(hardware.prepared == 1)
        #expect(hardware.engines.count == 1)
        hardware.engines[0].appending([1, 2], origin)
        _ = capture.endSession(first)

        // The key-up gives the device back and keeps the preparation, so the press after it
        // opens at the prepared price too.
        let second = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(hardware.prepared == 1)
        #expect(hardware.engines.count == 2)
        _ = capture.endSession(second)
    }

    @Test func beginningASessionOpensTheMicrophoneAndEndingItShutsIt() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 1)
        hardware.engines[0].appending([1, 2, 3], origin)
        _ = capture.endSession(session)
        #expect(isListening(capture))
        #expect(hardware.engines[0].disposed)
    }

    /// Press after press, each opens its own engine and gives it back. The ring is the
    /// one thing that carries across.
    @Test func eachSessionGetsItsOwnEngine() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try await opened(capture)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(first) == .whole(AudioClip(samples: [1, 2])))

        let second = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(hardware.engines.count == 2)
        hardware.engines[1].appending([3, 4], after(2))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [3, 4])))
        #expect(hardware.engines[1].disposed)
    }

    @Test func whatTheEngineCapturesIsWhatTheRingHolds() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1, 2, 3], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3])))
    }

    /// A session begins where the microphone opened, however early the key it came from
    /// was stamped. The mark is still taken from the event's own moment - the pre-roll is
    /// what covers a key pressed after speech began, and reaching back is that mark's job
    /// while an engine is already running - but an engine opened for this session has
    /// captured nothing for the mark to reach into, so it lands on the position its first
    /// sample will take. That is the whole of what a per-press microphone costs, and it
    /// is here rather than hidden in an empty clip.
    @Test func aSessionBeginsWhereTheMicrophoneOpenedHoweverEarlyTheKeyWas() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try await opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        _ = capture.endSession(first)

        // A key stamped back among the first session's samples, which is as far back as a
        // late-delivered key-down could ever point.
        let session = try capture.beginSession(at: after(1), preRoll: 0)
        #expect(session.begin == 4)
        hardware.engines[1].appending([5, 6], after(4))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [5, 6])))
    }

    /// The key went down between two buffers, so the moment is later than anything
    /// captured. A session cannot begin in audio that does not exist yet: it begins at
    /// the newest sample and holds what comes after. With the microphone opening for the
    /// session this is every session - an engine that has just started has captured
    /// nothing, so the mark lands on the position its first sample will take.
    @Test func aSessionBegunAfterTheNewestSampleBeginsAtTheNewestSample() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture, at: after(9))
        hardware.engines[0].appending([3], after(2))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [3])))
    }

    /// A hold longer than the ring retains: the first of what was said was overwritten by
    /// the last of it before the key came up. What comes back is the tail, and it says how
    /// much of the head is gone rather than passing for the whole utterance.
    @Test func aSessionWhoseHeadTheRingDroppedSaysHowMuchIsGone() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(retaining: AudioClip.duration(for: 4), hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4, 5, 6], origin)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [3, 4, 5, 6]), lost: loss(scrolledOff: 2)))
    }

    /// A press that opens its own microphone has nothing to reach back over: the pre-roll
    /// clamps to the moment the engine started, and audio that was never captured was not
    /// lost. This is the ordinary state of every press once the microphone opens per
    /// session, and it is what the epic traded the look-back for.
    @Test func aPreRollHasNothingToReachBackOverWhenTheMicrophoneJustOpened() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture, preRoll: AudioSession.defaultPreRoll)
        #expect(session.preRoll == 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The pre-roll never reaches across the moment the microphone opened, so a press
    /// cannot pick up the tail of the press before it: those words were said a minute ago
    /// and belong to no part of this utterance.
    @Test func aPreRollDoesNotReachIntoAnEarlierSessionsAudio() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let first = try await opened(capture)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        _ = capture.endSession(first)

        let second = try capture.beginSession(at: after(4), preRoll: AudioSession.defaultPreRoll)
        #expect(second.preRoll == 0)
        hardware.engines[1].appending([5, 6], after(4))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [5, 6])))
    }

    // MARK: - the microphone held at rest

    /// The other side of the epic's trade, and the only thing that can make this app hold
    /// the device while nobody is dictating. macOS lights the menu bar for as long as the
    /// engine runs, so a test that let this pass on a config nobody wrote would be a test
    /// that let the whole epic be undone by a default.
    @Test func theMicrophoneIsHeldFromTheStartWhenTheConfigAsksForIt() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        // Nobody is holding the key, so nothing is being dictated: the microphone is open
        // on the user's own arrangement rather than for a press.
        #expect(isListening(capture))
    }

    /// What the mode buys, stated as the difference it makes to a press. Compare
    /// `aPreRollHasNothingToReachBackOverWhenTheMicrophoneJustOpened`, where the same
    /// pre-roll over the same press comes back with nothing in front of it: there, the
    /// microphone opened at the key and there was no audio behind it to reach into.
    @Test func aHeldMicrophoneGivesAPressTheLookBackAPerPressOneCannotHave() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        // Said before the key went down: the speaker began the word and then reached for
        // the chord.
        hardware.engines[0].appending([1, 2], origin)
        let session = try capture.beginSession(at: after(2), preRoll: AudioSession.defaultPreRoll)
        #expect(session.preRoll == 2)
        hardware.engines[0].appending([3, 4], after(2))
        // One engine throughout, so there is no splice between the two halves of the word
        // and the ring behind the key is this session's to reach into.
        #expect(hardware.engines.count == 1)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3, 4])))
    }

    /// A streamed session's audio is the look-back the ring already holds and then every
    /// buffer as it lands, heard before the key comes up, and it ends when the session does,
    /// whole. Buffers after the end belong to no session and do not reach it.
    @Test func aSessionsAudioArrivesAsItIsCapturedAndEndsWithTheSession() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([1, 2], origin)
        let session = capture.stream(try capture.beginSession(at: after(2), preRoll: AudioSession.defaultPreRoll))
        var audio = session.audio.makeAsyncIterator()
        #expect(await audio.next()?.samples == [1, 2])
        hardware.engines[0].appending([3, 4], after(2))
        #expect(await audio.next()?.samples == [3, 4])
        #expect(capture.endSession(session).lost == nil)
        hardware.engines[0].appending([5, 6], after(4))
        #expect(await audio.next() == nil)
    }

    /// The ring scrolling past a streamed session loses nothing: each buffer reached the
    /// stream as it landed. What the ring had dropped before the stream began is missing,
    /// and the end says how much.
    @Test func aStreamedSessionMissesOnlyWhatTheRingDroppedBeforeItsStreamBegan() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(retaining: 0.5, hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let long = AudioClip.sampleCount(for: 0.8)
        let held = capture.stream(try capture.beginSession(at: origin, preRoll: 0))
        hardware.engines[0].appending([Float](repeating: 1, count: long), origin)
        #expect(capture.endSession(held).lost == nil)
        var heard: [Float] = []
        for await clip in held.audio { heard += clip.samples }
        #expect(heard.count == long)

        // Captured while no press was open, so the next press's pre-roll may reach over it.
        hardware.engines[0].appending([Float](repeating: 1, count: long), after(long))
        let reaching = capture.stream(try capture.beginSession(at: after(2 * long), preRoll: 0.8))
        #expect(capture.endSession(reaching).lost?.scrolledOff == AudioClip.sampleCount(for: 0.3))
    }

    /// A press begun on a held microphone before the last one's pre-roll has passed, as a
    /// mode switched mid-tap always is, begins where the last one ended: those words were
    /// heard and inserted with it, and reaching back over them would insert them twice.
    @Test func aPressOnAHeldMicrophoneBeginsWhereTheLastOneEnded() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let first = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2, 3, 4], origin)
        #expect(capture.endSession(first) == .whole(AudioClip(samples: [1, 2, 3, 4])))

        let second = try capture.beginSession(at: after(2), preRoll: AudioSession.defaultPreRoll)
        #expect(second.begin == 4)
        #expect(second.preRoll == 0)
        hardware.engines[0].appending([5, 6], after(4))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [5, 6])))
    }

    // MARK: - what a press's microphone delivered

    /// A streamed session's end reads what the microphone delivered since the key went down:
    /// the input it came through, how many samples, the loudest of them, and how long after
    /// the key the first was captured. The look-back a held microphone hands over is the
    /// ring's and not among them.
    @Test func aStreamedSessionsEndReadsWhatItsMicrophoneDeliveredSinceTheKey() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([0.9, 0.9], origin)
        let session = capture.stream(try capture.beginSession(at: after(2), preRoll: AudioSession.defaultPreRoll))
        hardware.engines[0].appending([0.5, -0.75], after(2) + .milliseconds(40))
        hardware.engines[0].appending([0.25], after(4) + .milliseconds(40))
        let reading = capture.endSession(session).reading
        #expect(reading == CapturedAudio.Reading(inputs: [hardware.engines[0].input.microphone], samples: 3, peak: 0.75, firstSample: .milliseconds(40)))
        #expect(reading.description == "\"Device 1\" (device 1, 48000 Hz, 1 channel) delivered 0.0 s (3 samples) peaking at -2.5 dBFS, the first 40 ms after the key went down")
    }

    /// A press whose microphone delivered nothing reads as nothing, not as a quiet room: no
    /// samples, and no first one to date.
    @Test func aPressWhoseMicrophoneDeliveredNothingReadsAsNothing() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = capture.stream(try await opened(capture))
        let end = capture.endSession(session)
        #expect(end.reading == CapturedAudio.Reading(inputs: [hardware.engines[0].input.microphone], samples: 0, peak: 0, firstSample: nil))
        #expect(end.reading.description == "\"Device 1\" (device 1, 48000 Hz, 1 channel) delivered nothing after the key went down")
        #expect(end.lost?.unopened == true)
    }

    /// Samples that are all zero are digital silence - a muted input, or one macOS feeds
    /// nothing but zeros - and read as that rather than as a level.
    @Test func aPressOfDigitalSilenceReadsAsSilence() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = capture.stream(try await opened(capture))
        hardware.engines[0].appending([Float](repeating: 0, count: AudioClip.sampleCount(for: 1)), origin)
        let reading = capture.endSession(session).reading
        #expect(reading.samples == AudioClip.sampleCount(for: 1))
        #expect(reading.peak == 0)
        #expect(reading.description == "\"Device 1\" (device 1, 48000 Hz, 1 channel) delivered 1.0 s (16000 samples) of digital silence, the first 0 ms after the key went down")
    }

    /// The device under a press went away and capture relaunched on the one that replaced
    /// it: the reading names both inputs, in the order they fed the press, since the samples
    /// it counts are both of theirs, and the loss says it was spliced.
    @Test func aPressWhoseDeviceWasReplacedReadsBothInputs() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = capture.stream(try await opened(capture))
        hardware.engines[0].appending([0.5], origin)
        hardware.moveDefaultInput()
        hardware.engines[0].input.onStale()
        hardware.engines[1].appending([0.5], after(1))
        let end = capture.endSession(session)
        #expect(end.reading.inputs == [hardware.engines[0].input.microphone, hardware.engines[1].input.microphone])
        #expect(end.reading.samples == 2)
        #expect(end.reading.description == "\"Device 1\" (device 1, 48000 Hz, 1 channel) then \"Device 2\" (device 2, 48000 Hz, 1 channel) delivered 0.0 s (2 samples) peaking at -6.0 dBFS, the first 0 ms after the key went down")
        #expect(end.lost?.interrupted == true)
    }

    /// A held microphone's buffer captured before the key and landing after it is the
    /// session's own audio, since the key marked the newest sample there was: the reading
    /// counts exactly the clip the stream handed over less its pre-roll, and the pre-roll's
    /// level is not the press's.
    @Test func aHeldPressReadsExactlyItsOwnAudio() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([0.9, 0.9], origin)
        let session = capture.stream(try capture.beginSession(at: after(3), preRoll: AudioSession.defaultPreRoll))
        hardware.engines[0].appending([0.5, -0.25], after(2))
        let end = capture.endSession(session)
        var heard: [Float] = []
        for await clip in session.audio { heard += clip.samples }
        #expect(heard == [0.9, 0.9, 0.5, -0.25])
        #expect(end.reading == CapturedAudio.Reading(inputs: [hardware.engines[0].input.microphone], samples: 2, peak: 0.5, firstSample: .zero))
    }

    /// A key-down handled after a held microphone's buffers already reached past the key:
    /// the samples from the key on are the press's head, so the reading dates them from the
    /// key and counts them, and the press is whole rather than one nothing reached.
    @Test func aHeldPressHandledLateIsDatedFromTheKey() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([0.25, 0.25, 0.5, 0.5], origin)
        let end = capture.endSession(capture.stream(try capture.beginSession(at: after(2), preRoll: 0)))
        #expect(end.reading == CapturedAudio.Reading(inputs: [hardware.engines[0].input.microphone], samples: 2, peak: 0.5, firstSample: .zero))
        #expect(end.lost == nil)
    }

    /// The key-up does not close a microphone the user asked to have held, and does not
    /// relaunch it either: a relaunch would splice the ring at every release, which is the
    /// look-back being thrown away once per press by the mode that exists to keep it.
    @Test func aHeldMicrophoneOutlivesThePressThatSpokeIntoIt() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let first = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(first) == .whole(AudioClip(samples: [1, 2])))
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        #expect(isListening(capture))

        let second = try capture.beginSession(at: after(2), preRoll: 0)
        hardware.engines[0].appending([3, 4], after(2))
        #expect(capture.endSession(second) == .whole(AudioClip(samples: [3, 4])))
        #expect(hardware.engines.count == 1)
    }

    /// A saved config that asks for the microphone held opens it when nobody is pressing, once
    /// the input a press would open is readied - with that input readied already, as soon as
    /// the main actor is free - and one that asks for it shut closes it.
    @Test func aRestingModeChangedBetweenPressesTakesEffectOnceTheInputIsReadied() async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await capture.start(grant, atRest: .shut)
        capture.rest(as: .open)
        #expect(capture.atRest == .open)
        try await untilItHolds { hardware.engines.count == 1 }
        #expect(!hardware.engines[0].disposed)
        capture.rest(as: .shut)
        #expect(capture.atRest == .shut)
        // The close lands a main-actor turn later, and a reading before it is not told shut.
        #expect("\(capture.doing)" == "being shut")
        try await untilItHolds { hardware.engines[0].disposed }
        #expect("\(capture.doing)" == "\(MicrophoneAtRest.shut)")
        #expect(isListening(capture))
        #expect(reports.said == ["rest open: reached", "rest shut: reached"])
    }

    /// The same change made mid-press waits for the key-up: the press goes on speaking into
    /// the microphone it opened, keeps every sample, and only then is the device let go.
    @Test func aRestingModeChangedMidPressWaitsForTheKeyUp() async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        capture.rest(as: .shut)
        try await untilItHolds { reports.said == ["rest shut: left for the key-up"] }
        #expect(!hardware.engines[0].disposed)
        #expect(isRunning(capture))
        hardware.engines[0].appending([3, 4], after(2))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3, 4])))
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 1)
    }

    /// Capture that is not started has no microphone to bring anywhere; `start` is what
    /// names its resting mode.
    @Test func aRestingModeChangedWhileStoppedIsNotHeld() {
        let capture = AudioCapture(hardware: FakeHardware())
        capture.rest(as: .open)
        #expect(capture.atRest == nil)
    }

    /// Capture started shut whose microphone a device change has since replaced with one
    /// still being reached: the stretch a save asking for the microphone held can land in.
    private func readyingASecondInput(_ hardware: FakeHardware, _ capture: AudioCapture) async throws {
        let starting = Task { try await capture.start(grant, atRest: .shut) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }
        hardware.inputs[0].finishReadying()
        try await starting.value
        try hardware.changeDefaultInput()
    }

    /// A save asking for the microphone held, landing while the input a press would open is
    /// still being reached, opens it only once that input is reached, and holds nothing up
    /// meanwhile: the call returns at once, and this suite, on the main actor, reads capture
    /// while the move waits. The move's report says how long the wait was.
    @Test func aMoveToOpenWhileAnInputIsReachedOpensItOnceReachedWithoutHoldingTheMainActor() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await readyingASecondInput(hardware, capture)

        capture.rest(as: .open)
        try await untilItHolds { hardware.inputs[1].waiters == 1 }
        #expect(hardware.engines.isEmpty)
        // The menu reads this, and a dark microphone is not called held open.
        #expect("\(capture.doing)" == "held open once its input is reached")
        try await Task.sleep(for: .milliseconds(20))
        hardware.inputs[1].finishReadying()
        try await untilItHolds { reports.said.count == 2 }
        #expect(reports.said == ["defaultInputChanged: readied", "rest open: reached"])
        #expect(hardware.engines.map(\.readying) == [2])
        #expect(reports.waits[0] >= .milliseconds(20))
    }

    /// The same save landing while capture is still coming up opens one microphone, once the
    /// first input is reached, and none before.
    @Test func aMoveToOpenWhileStartWaitsOpensOneMicrophoneOnceReached() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        let starting = Task { try await capture.start(grant, atRest: .shut) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }

        capture.rest(as: .open)
        try await untilItHolds { hardware.inputs[0].waiters == 2 }
        #expect(hardware.engines.isEmpty)
        hardware.inputs[0].finishReadying()
        try await starting.value
        try await untilItHolds { reports.said == ["rest open: reached"] }
        #expect(hardware.engines.map(\.readying) == [1])
    }

    /// A quit while a move waits ends in `stop`, and the move then has no microphone to open:
    /// none opens when the input is reached, and the report says capture stopped first.
    @Test func aStopWhileAMoveWaitsOpensNothing() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await readyingASecondInput(hardware, capture)

        capture.rest(as: .open)
        try await untilItHolds { hardware.inputs[1].waiters == 1 }
        capture.stop()
        hardware.inputs[1].finishReadying()
        try await untilItHolds { reports.said.count == 2 }
        #expect(reports.said.last == "rest open: stopped")
        #expect(hardware.engines.isEmpty)
    }

    /// A press during the wait opens the microphone itself, as a press always may. The move
    /// leaves it to the key-up, which keeps it open under the new mode, and no second
    /// microphone opens.
    @Test func aPressWhileAMoveWaitsKeepsItsMicrophoneAndItsKeyUpHoldsIt() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await readyingASecondInput(hardware, capture)

        capture.rest(as: .open)
        try await untilItHolds { hardware.inputs[1].waiters == 1 }
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines.map(\.readying) == [2])
        hardware.inputs[1].finishReadying()
        try await untilItHolds { reports.said.count == 2 }
        #expect(reports.said.last == "rest open: left for the key-up")
        _ = capture.endSession(session)
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        #expect(isListening(capture))
    }

    /// Two saves in one wait, held then shut: the microphone ends shut and never opened. The
    /// shut lands without waiting, and the held move says it was superseded rather than
    /// claiming a mode it did not set.
    @Test func aMoveSupersededDuringTheWaitSaysSoAndTheLaterOneDecides() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await readyingASecondInput(hardware, capture)

        capture.rest(as: .open)
        try await untilItHolds { hardware.inputs[1].waiters == 1 }
        capture.rest(as: .shut)
        try await untilItHolds { reports.said.count == 2 }
        hardware.inputs[1].finishReadying()
        try await untilItHolds { reports.said.count == 3 }
        #expect(Array(reports.said.dropFirst()) == ["rest shut: reached", "rest open: superseded"])
        #expect(hardware.engines.isEmpty)
    }

    /// Closing needs nothing of the input, so a save asking for a held microphone shut takes
    /// it dark at once, though the input it is held on is still being reached.
    @Test func aMoveToShutWhileAnInputIsReachedClosesTheMicrophoneWithoutWaiting() async throws {
        let hardware = FakeHardware(holdsReadying: true)
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        let starting = Task { try await capture.start(grant, atRest: .open) }
        try await untilItHolds { hardware.inputs.first?.waiters == 1 }
        hardware.inputs[0].finishReadying()
        try await starting.value
        // The device change relaunches the held microphone in place, on an input still being
        // reached.
        try hardware.changeDefaultInput()
        #expect(hardware.engines.map(\.readying) == [1, 2])

        capture.rest(as: .shut)
        try await untilItHolds { hardware.engines[1].disposed }
        #expect(!hardware.inputs[1].isReadied)
        #expect(reports.said.last == "rest shut: reached")
    }

    /// A key-down the input method delivered late is the press `unopened` exists to catch, and it is
    /// not one here. A held engine's buffers run continuously, so the next one to arrive
    /// after the key was already being captured when the key went down - its stamp is a
    /// full second older than the press - and the words said during that lateness are in
    /// the ring rather than missing from it. This is a press a per-press microphone reports
    /// cut and a held one reports whole, and both are right about their own machine.
    @Test func aPressOnAHeldMicrophoneIsNotChargedForAHeadItHeard() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let late = after(AudioClip.sampleCount(for: 1))
        let session = try capture.beginSession(at: late, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The door that a held microphone must not close. A microphone open for hours is one
    /// that can die quietly and go on looking open, and a press it delivers nothing for
    /// yields an empty clip - which transcribes to nothing at all, and reads exactly like a
    /// quiet room. Nothing about being held makes that press whole.
    /// [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatDeliveredNothingForAPressStillSaysItWasNotOpen() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([1, 2], origin)
        let session = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: []), lost: loss(unopened: true)))
    }

    /// The device was gone when capture started, so there was nothing to hold. A press is
    /// a reason to try the device again; without that, a Mac that booted with its
    /// microphone unplugged would stay deaf until one was plugged in, even with a key held
    /// down. [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatCouldNotOpenIsTriedAgainByTheNextPress() async throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.isEmpty)

        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines.count == 1)
        // Readied again, not reused: what failed may have been the device going away, and
        // an input prepared against that one cannot open the one that replaced it.
        #expect(hardware.prepared == 2)
        // The device did come back, and a press is simply where that was noticed: the gap
        // it ends is booked the same as one the device watch ends, or the count would
        // depend on which of the two got there first. [LAW:single-enforcer]
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The press tried the device and the device is still gone. What the user is owed then
    /// is the reason it is dead *now* - a microphone unplugged an hour ago and a cable that
    /// has just failed are the same silence, and only the newest error tells them apart. No
    /// gap is booked, because none ended: this retry extends the outage it found.
    /// [LAW:no-silent-failure]
    @Test func aPressThatCannotReviveAHeldMicrophoneLeavesItFailedAndCountsNoGap() async throws {
        let hardware = FakeHardware(launches: [NoDevice(), BadBuffer()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())

        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin, preRoll: 0) }
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.engines.isEmpty)
        #expect(capture.outages.count == 0)
    }

    /// A device report while the engine is down readies an input that has failed nothing, and
    /// the press that retries opens that one rather than readying a third. Readying runs off
    /// the main actor, so the one the report asked for can still be under way at the key, and
    /// replacing it would make the press wait for it and for its replacement back to back.
    @Test func aRetryOpensTheInputADeviceReportReadiedWhileTheEngineWasDown() async throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.inputs[0].onStale()
        #expect(hardware.prepared == 2)

        _ = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.prepared == 2)
        #expect(hardware.engines[0].readying == 2)
    }

    /// The same input is not kept once the default has moved off the device it was readied
    /// for: that is the retry the default-input watch exists to make.
    @Test func aRetryOnANewDefaultReadiesForItEvenWhenAnInputWasReadiedSinceTheFailure() async throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.inputs[0].onStale()
        try hardware.changeDefaultInput()

        #expect(hardware.prepared == 3)
        #expect(hardware.engines[0].readying == 3)
        #expect(capture.outages.count == 1)
    }

    /// Device churn while nobody is dictating, which only a held microphone can meet: the
    /// engine runs for hours, so a docking station waking up replaces it with no press in
    /// flight. The press that follows hears the new device only, and the audio the old one
    /// captured is on the far side of a splice - so the look-back this mode is held open
    /// for stops at the new engine's first sample rather than reaching across the break
    /// into a clip whose seam is in no sample.
    @Test func aDeviceChangedWhileIdleIsReplacedAndTheNextPressIsWhole() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].appending([1, 2, 3, 4, 5, 6], origin)

        hardware.engines[0].input.onStale()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        // The device this was readied against is the one that just went away, so the
        // replacement launches on a fresh input rather than the stale one.
        #expect(hardware.prepared == 2)
        #expect(capture.deviceChanges == 1)
        // A swap is not an outage and not a press: nothing failed, and nobody is dictating.
        #expect(capture.outages.count == 0)
        #expect(isListening(capture))

        // A second of pre-roll, against a key stamped back among the old device's samples:
        // both reach for audio this run of capture no longer continues from.
        let session = try capture.beginSession(at: after(1), preRoll: 1)
        #expect(session.preRoll == 0)
        hardware.engines[1].appending([7, 8], after(6))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [7, 8])))
    }

    /// What readying early costs, and what a green suite hid: a prepared input is bound to
    /// one device, so a default input that changes while the microphone rests shut leaves
    /// the readied one pointing at a device that is no longer the one to open. Nothing
    /// noticed - the watch acted only on a failed engine, and `shut` records no failure -
    /// so every press afterwards launched on a stale input and no later device change could
    /// clear it. Readying opens no device, so answering this costs the mode nothing: the
    /// microphone stays shut, and is simply ready against the right device.
    @Test func aDefaultInputChangedWhileShutReadiesAnotherAndOpensNothing() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        #expect(hardware.prepared == 1)

        try hardware.changeDefaultInput()
        #expect(hardware.prepared == 2)
        // Readied, not opened: nobody is holding the key, and a device appearing is not a
        // reason to start listening to it.
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))

        // And the press that follows opens what was readied against the new device.
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.count == 1)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The window this arrangement exists to close, and the one no test could reach while the
    /// watch was a parameter of `open`: the device stays the default and changes shape under a
    /// microphone that is readied and shut, a headset renegotiating its codec being the
    /// ordinary way. The default-input watch stays quiet for that - the default did not change
    /// - so only something watching the bound device hears it, and under `shut` nothing was:
    /// the watch went up at the press and came down at the key-up.
    ///
    /// What the stretch cost is the press after it. A readied input fixes its client format,
    /// its render buffer and its converter against the shape it found, and the unit goes on
    /// converting whatever the device now delivers into what it was asked for - so the
    /// utterance was resampled twice rather than captured wrong, which is why this was a
    /// quality defect and not a corrupt one. Readying opens no device, so answering it costs
    /// the mode nothing: the microphone stays shut and is simply ready against the shape the
    /// device has now.
    @Test func aBoundDeviceThatChangedShapeWhileShutReadiesAnotherAndOpensNothing() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        #expect(hardware.prepared == 1)

        hardware.inputs[0].onStale()
        #expect(hardware.prepared == 2)
        // Readied, not opened: nobody is holding the key, and a device changing shape is no
        // more a reason to start listening than a device appearing is.
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))

        // And the press that follows opens what was readied after the change rather than the
        // input prepared against the shape before it.
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines.count == 1)
        #expect(hardware.engines[0].readying == 2)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The third arm of the stale report, and one only this arrangement makes reachable: the
    /// watch used to come down with the engine, so a failed engine could never be told its
    /// device had changed shape. It outlives the press now, and it can.
    ///
    /// Left failed, where `recover()` would relaunch and close the gap. A default input that
    /// changed is a device that may have *appeared*, which is worth trying a dead engine
    /// against; a bound device that changed shape is the same device it was, and nothing about
    /// that says the reason this engine died has passed. So the failure stands with its gap
    /// still open - a press or a default-input change is what ends it, and both ready a
    /// microphone of their own - and all this owes is an input a press could open, because the
    /// one being held is bound to a device that has moved.
    @Test func aBoundDeviceThatChangedShapeUnderAFailedEngineLeavesItFailedAndReadiesAnother() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].onFailure(BadBuffer())
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.prepared == 1)

        hardware.inputs[0].onStale()
        // Still failed, and with the error it already had: a device changing shape under an
        // engine that is already dead is not news that the device is well.
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        // The gap is still open, so it is still uncounted - an outage is booked where it ends.
        #expect(capture.outages.count == 0)
        // A microphone readied against the device as it is now, and nothing opened to do it.
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.count == 1)

        // What that readying was for: the press that ends the outage opens on the device as it
        // is now rather than on the shape the failed engine was bound to.
        let session = try capture.beginSession(at: after(1), preRoll: 0)
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        hardware.engines[1].appending([1, 2], after(1))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// A press that could not open leaves the next one something that can. What went away
    /// may be the device the input was readied against, and under `shut` no failure is
    /// recorded for the watch to act on - so a press that kept its stale input would refuse
    /// every press after it until capture was restarted.
    @Test func aPressThatCouldNotOpenAShutMicrophoneReadiesAnotherForTheNext() async throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        #expect(hardware.prepared == 1)

        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin, preRoll: 0) }
        #expect(hardware.prepared == 2)
        // Shut rather than failed: a failure left behind here would let the next device
        // change hold open a microphone this mode asked to keep closed.
        #expect(isListening(capture))
        #expect(hardware.engines.isEmpty)

        let session = try capture.beginSession(at: after(1), preRoll: 0)
        #expect(hardware.engines.count == 1)
        hardware.engines[0].appending([1, 2], after(1))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// Under `open` the engine runs while nobody is dictating, and a default input that
    /// changes then is a device the run should follow. A HAL unit bound to one device hears
    /// nothing of a switch to a different one that is still alive - neither its liveness nor
    /// its format changed - so the system-wide watch is the only thing that can notice, and
    /// with no session open there is no recording to cut.
    @Test func aDefaultInputChangedWhileHeldAndIdleReplacesTheEngine() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        #expect(hardware.prepared == 1)
        #expect(hardware.engines.count == 1)

        try hardware.changeDefaultInput()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(hardware.prepared == 2)
        // A swap, not a recovery: nothing failed, so no gap opened and none is booked.
        #expect(capture.deviceChanges == 1)
        #expect(capture.outages.count == 0)
        #expect(isListening(capture))
    }

    /// The one case the watch leaves alone. A default input that changes mid-press is not a
    /// reason to cut the recording the speaker is in the middle of making: the engine keeps
    /// running on the device the press began on, and the input it is running on keeps the
    /// only strong reference the open device has.
    @Test func aDefaultInputChangedMidPressDoesNotCutTheRecording() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)

        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        #expect(hardware.prepared == 1)

        hardware.engines[0].appending([3, 4], after(2))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2, 3, 4])))
    }

    /// The other half of that sentence, and the half a green suite was missing: leaving the
    /// press alone is not the same as forgetting it happened. The default-input watch fires
    /// once per change, so the notification a press swallows is the only one coming - a user
    /// who switches from mic A to mic B mid-dictation was left speaking into A on every
    /// press afterwards, with nothing able to notice until the default changed a second time
    /// or A was unplugged. [LAW:no-ambient-temporal-coupling] The key-up is when "no session
    /// is open" becomes true, so that is where the deferred work is spent.
    ///
    /// Under `shut` that means the key-up readies against B and opens nothing, and the press
    /// after it is the one that opens B.
    @Test func aDefaultInputChangedMidPressReadiesTheNewDeviceAtTheKeyUp() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines[0].readying == 1)

        // The press keeps the device it began on, and keeps every sample of it.
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(!hardware.engines[0].disposed)
        #expect(hardware.prepared == 1)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))

        // And the key-up answers what the press deferred: readied against the new default,
        // still opening nothing, which is what `shut` promises whatever else happened.
        #expect(hardware.prepared == 2)
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 1)
        #expect(isListening(capture))

        let next = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines[1].readying == 2)
        #expect(hardware.prepared == 2)
        hardware.engines[1].appending([3, 4], after(2))
        #expect(capture.endSession(next) == .whole(AudioClip(samples: [3, 4])))
    }

    /// The same deferral under `open`, where the microphone the press was speaking into is
    /// held across the key-up rather than closed at it - so answering the change means
    /// moving what is held, not readying what is shut. A run that kept the old engine would
    /// hold a microphone the user stopped choosing, for hours, and light the indicator for
    /// it.
    ///
    /// No device change is booked, and that is not an oversight: the count is of a running
    /// engine swapped out in place, which `replaceEngine` is the only place that does
    /// [LAW:single-enforcer]. This is the press ending - the microphone comes to rest, and
    /// the mode opens the one it now holds - so it reads the way the same event reads under
    /// `shut`, where nothing is replaced at all.
    @Test func aDefaultInputChangedMidPressMovesTheHeldMicrophoneAtTheKeyUp() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines[0].readying == 1)

        try hardware.changeDefaultInput()
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))

        #expect(hardware.prepared == 2)
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines[1].readying == 2)
        #expect(isListening(capture))
        #expect(capture.deviceChanges == 0)

        // The press that follows speaks into the microphone now held, which is the new one.
        let next = try capture.beginSession(at: after(2), preRoll: 0)
        #expect(hardware.engines.count == 2)
        hardware.engines[1].appending([3, 4], after(2))
        #expect(capture.endSession(next) == .whole(AudioClip(samples: [3, 4])))
    }

    /// Two things going wrong at once, which is where a deferral's bookkeeping can swallow
    /// someone else's. The default input changes mid-press, and then the device the press
    /// is on dies before the key-up: the readying is still owed, and the engine is no
    /// longer running but failed, with a gap open since it died. Answering the change by
    /// forcing that engine shut would throw the gap away - `open` would relaunch over the
    /// top of it and the outage would never be booked, which is the accounting this file
    /// treats as the failure itself. [LAW:no-silent-failure] So the key-up readies against
    /// the new default and leaves the failure where it is, for the device watch to end.
    @Test func aDeferredDeviceChangeLeavesAFailureThatArrivedFirstToBeBooked() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)

        try hardware.changeDefaultInput()
        hardware.engines[0].onFailure(NoDevice())
        _ = capture.endSession(session)

        // Readied against the new default, which is owed whatever the engine did...
        #expect(hardware.prepared == 2)
        // ...and nothing relaunched over a gap still open: the failure is still what the
        // run says it is, and the outage is still uncounted because it has not ended.
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.count == 1)
        #expect(capture.outages.count == 0)

        try hardware.changeDefaultInput()
        #expect(isListening(capture))
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines[1].readying == 3)
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
    }

    /// The same pair under `shut`, where the key-up clears the failure by closing a
    /// microphone that is meant to be closed - so the half that has to survive is the other
    /// one. A key-up that skipped the readying because the engine was failed rather than
    /// running would leave the next press opening the device that stopped being the
    /// default, which is the whole of what the deferral exists to prevent.
    @Test func aDeferredDeviceChangeIsStillReadiedWhenThePressesEngineDied() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        let session = try capture.beginSession(at: origin, preRoll: 0)

        try hardware.changeDefaultInput()
        hardware.engines[0].onFailure(NoDevice())
        _ = capture.endSession(session)
        #expect(isListening(capture))
        #expect(hardware.prepared == 2)

        let next = try capture.beginSession(at: after(1), preRoll: 0)
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines[1].readying == 2)
        _ = capture.endSession(next)
    }

    /// Unplugs the default input under whatever microphone capture has readied last, landing
    /// the two reports in `order`. The default moves before either lands, as it does on a
    /// Mac: a report is posted after the change it announces.
    private func unplugTheDefaultInput(_ hardware: FakeHardware, reportedIn order: UnplugReports) throws {
        let bound = try #require(hardware.inputs.last)
        hardware.moveDefaultInput()
        switch order {
        case .defaultFirst:
            try hardware.announceDefaultInput()
            bound.onStale()
        case .deviceFirst:
            bound.onStale()
            try hardware.announceDefaultInput()
        }
    }

    /// One unplug under a held press, answered once. The bound device's report replaces the
    /// engine mid-press so the rest of the utterance is salvaged on the new default - and
    /// when that report lands before the default-input one, the default-input one is about a
    /// change already answered. Reading it as news had the key-up give up the replacement
    /// and relaunch, which splices the ring at the key-up and leaves the next press no
    /// look-back over audio the replacement had captured since: the one thing `open` is
    /// held for.
    @Test(arguments: UnplugReports.allCases)
    func aHeldMicrophoneUnpluggedMidPressIsReplacedOnceWhicheverReportLandsFirst(_ order: UnplugReports) async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)

        try unplugTheDefaultInput(hardware, reportedIn: order)
        hardware.engines[1].appending([3, 4], after(2))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2, 3, 4]), lost: loss(interrupted: true)))

        #expect(hardware.prepared == 2)
        #expect(hardware.engines.count == 2)
        #expect(!hardware.engines[1].disposed)
        #expect(capture.deviceChanges == 1)

        // The replacement kept running across the key-up, so the next press reaches back
        // over what it captured after it, and no further, since what came before was the
        // last press's.
        hardware.engines[1].appending([5, 6], after(4))
        let next = try capture.beginSession(at: after(6), preRoll: AudioSession.defaultPreRoll)
        #expect(next.preRoll == 2)
        hardware.engines[1].appending([7, 8], after(6))
        #expect(capture.endSession(next) == .whole(AudioClip(samples: [5, 6, 7, 8])))
    }

    /// The same unplug under `shut`, where what a second answer costs is a readying at the
    /// key-up rather than a splice: the replacement's input is already on the new default,
    /// and the press after the key-up opens it.
    @Test(arguments: UnplugReports.allCases)
    func aShutMicrophoneUnpluggedMidPressIsReadiedOnceWhicheverReportLandsFirst(_ order: UnplugReports) async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)

        try unplugTheDefaultInput(hardware, reportedIn: order)
        _ = capture.endSession(session)
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.count == 2)
        #expect(hardware.engines[1].disposed)

        let next = try capture.beginSession(at: after(0), preRoll: 0)
        #expect(hardware.engines.count == 3)
        #expect(hardware.engines[2].readying == 2)
        _ = capture.endSession(next)
    }

    /// With nobody pressing, both reports reach code that acts at once, so neither ordering
    /// can hide behind a key-up: the second report used to replace a held engine already on
    /// the new default, a second swap and a second splice for one unplug.
    @Test(arguments: UnplugReports.allCases)
    func aHeldMicrophoneUnpluggedWhileIdleIsReplacedOnceWhicheverReportLandsFirst(_ order: UnplugReports) async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)

        try unplugTheDefaultInput(hardware, reportedIn: order)
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.count == 2)
        #expect(!hardware.engines[1].disposed)
        #expect(capture.deviceChanges == 1)
        #expect(isListening(capture))
    }

    /// The idle unplug under `shut`, where a second answer is a second readying and nothing
    /// is opened either way.
    @Test(arguments: UnplugReports.allCases)
    func aShutMicrophoneUnpluggedWhileIdleIsReadiedOnceWhicheverReportLandsFirst(_ order: UnplugReports) async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)

        try unplugTheDefaultInput(hardware, reportedIn: order)
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))
    }

    /// Every report capture makes, as what it was about and a word for what came of it, so a
    /// test can say which report was answered and which was found already answered, and
    /// what each move of the resting mode came to and how long it waited.
    @MainActor private final class Reports {
        private(set) var said: [String] = []
        private(set) var waits: [Duration] = []
        func record(_ report: CaptureReport) {
            switch report {
            case .device(let report):
                let answer = switch report.answer {
                case .outdated: "outdated"
                case .leftForTheKeyUp: "left for the key-up"
                case .alreadyOnIt: "already on it"
                case .readied: "readied"
                case .launched(.success): "launched"
                case .launched(.failure(let error)): "failed: \(error)"
                }
                said.append("\(report.cause): \(answer)")
            case .resting(let move):
                let outcome = switch move.outcome {
                case .reached: "reached"
                case .leftForTheKeyUp: "left for the key-up"
                case .superseded: "superseded"
                case .stopped: "stopped"
                }
                said.append("rest \(move.to.rawValue): \(outcome)")
                waits.append(move.waited)
            }
        }
    }

    /// One unplug is two reports and one answer, and the log says both: the report that
    /// readied a microphone on the new default, and the other one finding nothing left to do.
    /// A recovery that leaves no trace is indistinguishable from one that never came.
    @Test(arguments: UnplugReports.allCases)
    func anUnplugWhileIdleReportsOneAnswerAndOneReportFoundAnswered(_ order: UnplugReports) async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await capture.start(grant, atRest: .shut)

        try unplugTheDefaultInput(hardware, reportedIn: order)
        switch order {
        case .defaultFirst: #expect(reports.said == ["defaultInputChanged: readied", "boundDeviceChanged: outdated"])
        case .deviceFirst: #expect(reports.said == ["boundDeviceChanged: readied", "defaultInputChanged: already on it"])
        }
    }

    /// The only device going away under a held microphone is reported as the relaunch that
    /// failed, and the device that appears after as the relaunch that worked: the outage and
    /// its end, both in the log.
    @Test func aHeldMicrophoneThatLostItsOnlyDeviceReportsTheFailureAndTheRecovery() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await capture.start(grant, atRest: .open)

        hardware.engines[0].input.onStale()
        try hardware.changeDefaultInput()
        #expect(reports.said == ["boundDeviceChanged: failed: NoDevice()", "defaultInputChanged: launched"])
        #expect(isListening(capture))
    }

    /// A default-input change under a press is reported as left for its key-up, so a press
    /// that went on recording on the old device says why in the log.
    @Test func aDefaultInputChangedMidPressIsReportedAsLeftForTheKeyUp() async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        _ = try await opened(capture)

        try hardware.changeDefaultInput()
        #expect(reports.said == ["defaultInputChanged: left for the key-up"])
    }

    /// The key-up a mid-press change was left for says what it did about it, so the log
    /// carries the recovery it promised and not only the promise.
    @Test(arguments: [(MicrophoneAtRest.shut, "readied"), (.open, "launched")])
    func theKeyUpAMidPressChangeWasLeftForReportsWhatItDid(atRest: MicrophoneAtRest, did: String) async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        let session = try await opened(capture, atRest: atRest)

        try hardware.changeDefaultInput()
        _ = capture.endSession(session)
        #expect(reports.said == ["defaultInputChanged: left for the key-up", "restedOffTheDefault: \(did)"])
    }

    /// An unplug under a press whose bound device reports first is answered then and there,
    /// so the default-input report says so rather than promising a key-up that has nothing
    /// left to do - and the key-up reports nothing.
    @Test func anUnplugMidPressAnsweredByTheBoundDeviceIsNotLeftForTheKeyUp() async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        let session = try await opened(capture)

        try unplugTheDefaultInput(hardware, reportedIn: .deviceFirst)
        _ = capture.endSession(session)
        #expect(reports.said == ["boundDeviceChanged: launched", "defaultInputChanged: already on it"])
    }

    /// A default-input change that lands after capture stopped is reported as outdated, the
    /// same as the bound device's report in that stretch.
    @Test func aDefaultInputChangeAfterStopIsReportedOutdated() async throws {
        let hardware = FakeHardware()
        let reports = Reports()
        let capture = AudioCapture(hardware: hardware, startingAt: origin, reporting: { reports.record($0) })
        try await capture.start(grant, atRest: .shut)
        let lateNotification = try #require(hardware.onDefaultInputChange)

        capture.stop()
        lateNotification()
        #expect(reports.said == ["defaultInputChanged: outdated"])
    }

    /// Quitting gives the device back, however the run was holding it.
    @Test func stopGivesUpAHeldMicrophone() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        capture.stop()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.watchDisposals == 1)
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
    }

    /// The menu reads this rather than the config it was started from, so what it tells the
    /// user is what their microphone is doing. A run that never started says nothing, which
    /// is the truth and is not the same answer as "shut between presses".
    @Test func theRestingModeIsReadBackFromTheRunOfCaptureHoldingIt() async throws {
        let capture = AudioCapture(hardware: FakeHardware(), startingAt: origin)
        #expect(capture.atRest == nil)
        try await capture.start(grant, atRest: .open)
        #expect(capture.atRest == .open)
        capture.stop()
        #expect(capture.atRest == nil)
    }

    /// The resting mode is what the user asked for; this is what they got, and under `open`
    /// they are the two things most likely to disagree. An engine held across presses can
    /// die while nobody is pressing anything, and nothing will try the device again until
    /// someone does - so for as long as that takes, a status surface reading the mode alone
    /// reports a live microphone on a Mac that has none. This is the one reading that puts
    /// the failure in front of the user before their next press does.
    /// [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatDiedSaysSoRatherThanThatItIsStillHeldOpen() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        // Not started is its own answer, and not the same one as "shut between presses".
        #expect("\(capture.doing)" == "not being captured")

        try await capture.start(grant, atRest: .open)
        #expect("\(capture.doing)" == "\(MicrophoneAtRest.open)")

        hardware.engines[0].onFailure(NoDevice())
        let dead = "\(capture.doing)"
        #expect(dead != "\(MicrophoneAtRest.open)")
        // Still says which mode the run is in - the user's arrangement did not change - and
        // now says the device is not keeping to it, in the failure's own words.
        #expect(dead.contains("\(MicrophoneAtRest.open)"))
        #expect(dead.contains("\(NoDevice())"))
        // And it reads as stopped, which is what makes the menu's line one a click copies.
        guard case .stopped(.open, let error) = capture.doing else {
            Issue.record("read as \(capture.doing)")
            return
        }
        #expect(error is NoDevice)
    }

    /// What the mode promises after the device has gone: it comes back by itself. Under
    /// `shut` a dead engine is relaunched by the next press, so the user finds out within
    /// one hold; under `open` nobody presses for hours, and the device watch outliving the
    /// engine is the only thing that can end the gap unattended. A recovery is not a swap -
    /// nothing was replaced, capture simply resumed - so it is booked as the outage it ends
    /// and not as a device change.
    @Test func aHeldMicrophoneThatDiedWhileIdleComesBackWhenADeviceAppears() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        hardware.engines[0].onFailure(NoDevice())
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        // The gap is open, so it is not booked yet: an outage is counted where it ends.
        #expect(capture.outages.count == 0)

        try hardware.changeDefaultInput()
        #expect(isListening(capture))
        #expect(hardware.engines.count == 2)
        // The default input is what changed, so the input readied against the old one is
        // stale and the relaunch happens on another.
        #expect(hardware.prepared == 2)
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        #expect(capture.deviceChanges == 0)
        // And the surface stops saying it stopped, without anyone having pressed anything.
        #expect("\(capture.doing)" == "\(MicrophoneAtRest.open)")
    }

    /// The key-up hands the microphone back to its resting state, and under `open` that
    /// state is one a dead engine cannot be quietly restored to. Compare
    /// `aSessionWhoseMicrophoneDiedAndDidNotComeBackIsPartial`, where the same death under
    /// `shut` leaves capture `.listening` after the key-up: there the failure is cleared by
    /// closing a microphone that is meant to be closed, and the next press relaunches. Here
    /// the run is holding the device, so a failure that outlived the press is the truth
    /// about it until something launches again - and it is what leaves the engine in the
    /// one state `recover()` will act on. [LAW:no-silent-failure]
    @Test func aHeldMicrophoneThatDiedMidPressIsStillDeadAfterTheKeyComesUp() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .open)
        let session = try capture.beginSession(at: origin, preRoll: 0)
        hardware.engines[0].appending([1, 2], origin)
        hardware.engines[0].onFailure(NoDevice())

        // The speaker went on talking to a microphone that was no longer there, so the tail
        // of what they said was never captured however complete the clip looks.
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(unopened: true)))
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.count == 1)
        #expect("\(capture.doing)".contains("\(NoDevice())"))
    }

    // MARK: - what a press was missing

    /// The engine took longer to start than the key was held, so not one sample of what
    /// was said was captured. An empty clip transcribes to nothing at all, which reads
    /// exactly like a quiet room; this is the door that tells the two apart.
    @Test func aSessionTheMicrophoneCapturedNothingForSaysItWasNotOpen() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: []), lost: loss(unopened: true)))
    }

    /// The microphone opened long after the key went down - the key-down reached the
    /// handler late, or this is the first press in the process and the engine paid what the
    /// first launch costs. Either way the speaker was talking to a shut
    /// microphone, and the clip that comes back is their sentence with the front of it
    /// gone. Nothing in those samples says so, which is why the session does.
    @Test func aSessionWhoseMicrophoneOpenedLongAfterTheKeyWentDownSaysSo() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        // The first sample this engine captured was taken past the allowance after the key
        // went down, so that much of what was said was never captured at all.
        hardware.engines[0].appending([1, 2], after(AudioClip.sampleCount(for: AudioCapture.warmUpAllowance + 0.4)))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(unopened: true)))
    }

    /// The ordinary press, and the reason the allowance exists at all: an engine is never
    /// instant, so every session's first sample is taken a little after the key went down.
    /// A press that lost only that much is whole - the measurement behind the allowance is
    /// that a speaker has not begun the word yet - and a loop that called this one partial
    /// would refuse every press ever made.
    @Test func aSessionWhoseMicrophoneOpenedWithinTheAllowanceIsWhole() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        let warmUp = AudioClip.sampleCount(for: AudioCapture.warmUpAllowance / 2)
        hardware.engines[0].appending([1, 2], after(warmUp))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }

    /// The microphone was open and then was not, and the key came up while it was gone:
    /// the tail of the utterance was never captured, and the clip that is left is a
    /// fragment however complete it looks.
    @Test func aSessionWhoseMicrophoneDiedAndDidNotComeBackIsPartial() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1, 2], origin)
        hardware.engines[0].input.onStale()
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        let ended = try capture.endSession(session)
        #expect(try ended == .partial(AudioClip(samples: [1, 2]), lost: loss(unopened: true)))
        // It answered at once and died later, so what the person reads must not say it did not answer.
        if case .partial(_, let lost) = ended { #expect("\(lost)" == "Your microphone was not open for the whole of your dictation") }
        #expect(isListening(capture))
    }

    /// A press with no capture behind it is refused at the key, not handed an empty clip
    /// for a transcriber to call a quiet room.
    @Test func beginningASessionOnStoppedCaptureThrows() throws {
        let capture = AudioCapture(hardware: FakeHardware())
        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin) }
    }

    /// The device cannot feed the pipeline, so there is no microphone to open and the
    /// press says so. Nothing is left half-open behind it.
    @Test func beginningASessionTheDeviceRefusesThrowsAndLeavesNothingOpen() async throws {
        let hardware = FakeHardware(launches: [NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        try await capture.start(grant, atRest: .shut)
        #expect(throws: NoMicrophone.self) { try capture.beginSession(at: origin) }
        #expect(isListening(capture))
        #expect(hardware.engines.isEmpty)
        #expect(hardware.isWatching)
    }

    /// The ring survives the engine: samples from before the change are still there
    /// after it, followed by the new engine's - spliced, since nothing was captured in
    /// between and no position advanced while nothing was. A session open across the
    /// change is told so; the samples themselves have no seam to find it by.
    @Test func aConfigurationChangeReplacesTheEngineAndSplicesTheRing() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].input.onStale()
        #expect(hardware.engines[0].disposed)
        #expect(hardware.engines.count == 2)
        #expect(capture.deviceChanges == 1)
        #expect(isRunning(capture))
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The same splice with the reconnect actually taking time. Positions advance only on
    /// capture, so the two engines' samples sit adjacent while the clock between them ran
    /// for a third of a second, and that gap is exactly what a head measured off the newest
    /// buffer would charge to this session's warm-up. The head was captured on time: what
    /// this press lost is its middle, and saying it was also cut where the microphone was
    /// not open would be a second loss that never happened.
    ///
    /// The splice tests either side of this one stamp the replacement at `after(1)`, which
    /// simulates a reconnect that took no time at all - the one quantity that makes the
    /// error visible. This is the unit-level guard on it; `DictationTests` holds the same
    /// press end to end.
    @Test func aSessionSplicedAcrossARealOutageIsNotAlsoUnopened() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].input.onStale()
        hardware.engines[1].appending([2], after(1 + AudioClip.sampleCount(for: 0.3)))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The press after the one the device changed under hears one engine only: the break
    /// is behind it, so its clip is whole.
    @Test func aSessionBegunAfterAConfigurationChangeIsWhole() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let spanning = try await opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].input.onStale()
        _ = capture.endSession(spanning)

        let session = try capture.beginSession(at: after(1), preRoll: 0)
        hardware.engines[2].appending([2], after(1))
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [2])))
    }

    /// The same splice by the other door: the microphone died mid-session and the device
    /// that appeared brought it back, so the clip is two engines' audio with the outage
    /// taken out of the middle of it.
    @Test func aSessionThatSpansAnOutageIsPartial() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        let session = try await opened(capture)
        hardware.engines[0].appending([1], origin)
        hardware.engines[0].input.onStale()
        try hardware.changeDefaultInput()
        hardware.engines[1].appending([2], after(1))
        #expect(try capture.endSession(session) == .partial(AudioClip(samples: [1, 2]), lost: loss(interrupted: true)))
    }

    /// The only microphone is unplugged mid-hold: the replacement cannot launch, capture
    /// is failed for a while, and the plug-back-in (a default input change) brings it
    /// back before the speaker has let go.
    @Test func aReplacementThatCannotLaunchIsFailedUntilTheDefaultInputChanges() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].input.onStale()
        #expect(failure(of: capture, as: NoDevice.self) == NoDevice())
        #expect(hardware.engines.count == 1)
        #expect(capture.outages.count == 0)

        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(capture.outages.count == 1)
        #expect(capture.outages.total > .zero)
        #expect(capture.deviceChanges == 0)
    }

    /// A device that appears but cannot feed the pipeline either extends the outage
    /// rather than beginning another; the next one that can ends it.
    @Test func aRecoveryThatFailsAgainExtendsTheSameOutage() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice(), BadBuffer()])
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].input.onStale()
        try hardware.changeDefaultInput()
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        try hardware.changeDefaultInput()
        #expect(isRunning(capture))
        #expect(capture.outages.count == 1)
    }

    /// A default input change under a live press launches nothing. The device the press is
    /// recording on is still alive and still the shape it was - what changed is which device
    /// the *next* press should open - so cutting this one buys nothing, and the readying it
    /// does owe is the key-up's.
    @Test func aDefaultInputChangeWhileRunningLaunchesNothing() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(isRunning(capture))
        #expect(capture.deviceChanges == 0)
    }

    /// Plugging a microphone in while nobody is dictating opens nothing. The watch runs
    /// for the whole started period because a session's failed engine has no other way to
    /// hear that a device came back - it must never be read as a reason to start
    /// listening when no session is open.
    @Test func aDefaultInputChangeWhileShutOpensNoMicrophone() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try await capture.start(grant, atRest: .shut)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))
    }

    /// A session that ended while its engine was failed leaves nothing running, so the
    /// device that appears afterwards finds a shut microphone and leaves it shut.
    @Test func aDeviceAppearingAfterAFailedSessionEndedOpensNoMicrophone() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        let session = try await opened(capture)
        hardware.engines[0].input.onStale()
        _ = capture.endSession(session)
        try hardware.changeDefaultInput()
        #expect(hardware.engines.count == 1)
        #expect(isListening(capture))
    }

    @Test func aBufferTheTapCannotConvertFailsCapture() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].onFailure(BadBuffer())
        #expect(failure(of: capture, as: BadBuffer.self) == BadBuffer())
        #expect(hardware.engines[0].disposed)
    }

    /// A replaced engine's late failure says nothing about the engine now running, and neither
    /// does a let-go input's late staleness. Both watches outlive what they were formed for -
    /// the render callback's failure arrives asynchronously, and the device listeners behind `onStale` can
    /// have posted before their input was let go and arrive after - so each callback carries
    /// the generation it belongs to and is matched rather than trusted. Acting on the second
    /// one here would give up an engine running healthily on the input that took over.
    @Test func aCallbackFromAReplacedEngineIsStale() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].input.onStale()
        hardware.engines[0].onFailure(BadBuffer())
        hardware.engines[0].input.onStale()
        #expect(isRunning(capture))
        #expect(hardware.engines.count == 2)
        #expect(!hardware.engines[1].disposed)
    }

    /// Quitting mid-hold: the key is still down, so there is a microphone to give back.
    @Test func stopDuringASessionDisposesTheEngineAndTheWatch() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        capture.stop()
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
        #expect(hardware.engines[0].disposed)
        #expect(!hardware.isWatching)
        #expect(hardware.watchDisposals == 1)
    }

    @Test func stopWhileShutDisposesTheWatch() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware)
        try await capture.start(grant, atRest: .shut)
        capture.stop()
        if case .stopped = capture.state {} else { Issue.record("stop did not stop") }
        #expect(!hardware.isWatching)
        #expect(hardware.watchDisposals == 1)
    }

    @Test func stopWhileFailedDisposesTheWatch() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice()])
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].input.onStale()
        capture.stop()
        #expect(!hardware.isWatching)
    }

    /// A start that cannot watch the input device leaves nothing behind, and says why.
    /// Capture that cannot hear a device appear could never recover a session's engine,
    /// so half-starting is worse than not starting.
    @Test func aStartThatCannotWatchThrowsAndLeavesNothingStarted() async throws {
        let hardware = FakeHardware(watch: NoDevice())
        let capture = AudioCapture(hardware: hardware)
        await #expect(throws: NoDevice.self) { try await capture.start(grant, atRest: .shut) }
        #expect(!hardware.isWatching)
        if case .stopped = capture.state {} else { Issue.record("a failed start should leave capture stopped") }
    }

    @Test func startAgainResetsTheCounts() async throws {
        let hardware = FakeHardware(launches: [nil, NoDevice(), nil, nil])
        let capture = AudioCapture(hardware: hardware)
        _ = try await opened(capture)
        hardware.engines[0].input.onStale()
        try hardware.changeDefaultInput()
        hardware.engines[1].input.onStale()
        #expect(capture.deviceChanges == 1)
        #expect(capture.outages.count == 1)
        try await capture.start(grant, atRest: .shut)
        #expect(capture.deviceChanges == 0)
        #expect(capture.outages.count == 0)
        #expect(capture.outages.total == .zero)
        #expect(hardware.engines[2].disposed)
        #expect(hardware.watchDisposals == 1)
        #expect(hardware.isWatching)
        #expect(isListening(capture))
    }

    /// A microphone the previous run readied, reporting stale after a restart let it go. The
    /// watch behind a readied input lives as long as the input does, so a notification posted
    /// while the previous run still held it can arrive against the run that replaced it, and it
    /// speaks about an input no press could open any more. This is why the preparation count is
    /// the one thing `start()` does not reset: it resets what it counts two lines above, and a
    /// counter back at zero would let this straggler match the microphone the restart readied.
    @Test func aReadiedMicrophoneLetGoByARestartIsStaleWhenItReportsAfterIt() async throws {
        let hardware = FakeHardware()
        let capture = AudioCapture(hardware: hardware, startingAt: origin)
        try await capture.start(grant, atRest: .shut)
        let letGoByTheRestart = hardware.inputs[0]

        try await capture.start(grant, atRest: .shut)
        #expect(hardware.prepared == 2)

        letGoByTheRestart.onStale()
        #expect(hardware.prepared == 2)
        #expect(hardware.engines.isEmpty)
        #expect(isListening(capture))

        // And the press that follows opens the microphone the restart readied, rather than one
        // readied to answer a device change that had already been answered by the restart.
        let session = try capture.beginSession(at: origin, preRoll: 0)
        #expect(hardware.engines.count == 1)
        #expect(hardware.engines[0].readying == 2)
        hardware.engines[0].appending([1, 2], origin)
        #expect(capture.endSession(session) == .whole(AudioClip(samples: [1, 2])))
    }
}
