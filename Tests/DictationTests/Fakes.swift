import AVFoundation
import Dictation
import Dispatch
import Grants
import Insertion
import InsertionFakes
import LowTalkerCore
import LowTalkerCoreFakes
import Synchronization
import TestProbes

/// A store kept in memory, outliving the rigs built over it as a file outlives the app, and
/// keeping the store's contract.
@MainActor
final class FakeHeldStore: HeldStore {
    private(set) var state: HoldState
    /// What is held, as kept.
    var kept: Held? { state.held }
    /// Every write, in order.
    private(set) var written: [HoldState] = []
    /// What every read throws, when set.
    var unreadable: HeldUnreadable?
    /// What every write throws, when set; `.lost` keeps nothing, `.stale` leaves what was kept.
    var failing: HeldUnkept?

    init(keeping kept: Held? = nil, dismissed: Held? = nil) {
        state = HoldState(held: kept, dismissed: dismissed)
    }

    func read() throws(HeldUnreadable) -> HoldState {
        if let unreadable { throw unreadable }
        return state
    }

    func write(_ state: HoldState) throws(HeldUnkept) {
        written.append(state)
        switch failing {
        case nil: self.state = state
        case .lost?: self.state = HoldState()
        case .stale?: break
        }
        if let failing { throw failing }
    }
}

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

        func waitUntilReadied() async {}
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
    static let microphone = MicrophoneInput(device: 1, name: .success("Fake Microphone"), sampleRate: 48_000, channels: 1, heard: HeardChannels(of: 1, stereo: .named(1, 1)))

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

