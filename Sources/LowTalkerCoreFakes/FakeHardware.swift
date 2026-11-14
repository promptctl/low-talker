import CoreAudio
import LowTalkerCore
import TestProbes
import Testing
import Uptime

/// Hardware a test controls: each opening takes the next scripted outcome, every engine's and
/// every readied input's callbacks are the test's to fire, and the default input device changes
/// when the test says so. It keeps `AudioHardwareContract`.
///
/// Readying a microphone and opening one are counted apart, because the difference is what keeps
/// `shut` affordable and a test that could not see it could not hold the difference in place.
@MainActor
public final class FakeHardware: AudioHardware {
    /// A microphone readied and not open: opening it is what takes the next scripted outcome, so
    /// preparing one costs a test nothing and proves nothing was opened.
    public final class Input: PreparedInput {
        private unowned let hardware: FakeHardware
        /// Which readying this one came from, counting from one. A prepared input is bound to the
        /// device that was default when it was readied, so this is the only thing a test can say
        /// "the press opened the microphone readied against the new device" with.
        public let readying: Int
        /// The device that was the default when this was readied, which is the device a real
        /// input binds to.
        public let device: Int
        /// Fired by a test to say the device this was readied against went away or changed shape.
        /// It belongs to the readied input rather than to an engine because that is where the real
        /// one lives, and that is what lets a test reach the stretch where the microphone is
        /// readied and nothing is open.
        public let onStale: @MainActor () -> Void

        /// Whether readying has finished: at once, unless the hardware holds readying back, and
        /// then when the test calls `finishReadying()`.
        public private(set) var isReadied: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []
        /// How many waits are waiting for readying to finish, which is how a test sees a wait
        /// reach this input.
        public var waiters: Int { waiting.count }

        init(_ hardware: FakeHardware, readying: Int, onStale: @escaping @MainActor () -> Void) {
            self.hardware = hardware
            self.readying = readying
            device = hardware.defaultInput
            isReadied = !hardware.holdsReadying
            self.onStale = onStale
        }

        public func finishReadying() {
            isReadied = true
            waiting.forEach { $0.resume() }
            waiting = []
            hardware.changed.note()  // [LAW:no-ambient-temporal-coupling] readying finished; waiters let go
        }

        public func open(
            appending: @escaping @Sendable ([Float], HostTime) -> Void,
            onFailure: @escaping @MainActor (any Error) -> Void
        ) throws -> OpenedInput {
            OpenedInput(dispose: try hardware.open(on: self, appending: appending, onFailure: onFailure), input: microphone)
        }

        /// The device this is bound to, as an open says it.
        public var microphone: MicrophoneInput { FakeHardware.microphone(on: device) }

        public var isOnTheDefaultInput: Bool { device == hardware.defaultInput }

        public func waitUntilReadied() async {
            if isReadied { return }
            // [LAW:no-ambient-temporal-coupling] The wait raises `waiters` here, before this
            // suspends; the note fires now, since this does not return until readying finishes.
            await withCheckedContinuation { waiting.append($0); hardware.changed.note() }
        }
    }

    public final class Engine {
        /// The readied microphone this engine was opened on. Held rather than copied from, so
        /// `engine.input.onStale()` is how a test says the device under a running engine changed.
        /// [LAW:one-source-of-truth]
        public let input: Input
        public let appending: @Sendable ([Float], HostTime) -> Void
        public let onFailure: @MainActor (any Error) -> Void
        public internal(set) var disposed = false

        /// Which readying this engine was opened on, read off that input.
        public var readying: Int { input.readying }

        init(input: Input, appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) {
            self.input = input
            self.appending = appending
            self.onFailure = onFailure
        }
    }

    /// The microphone an input readied against `device` opens as.
    public static func microphone(on device: Int) -> MicrophoneInput {
        MicrophoneInput(device: AudioObjectID(device), name: .success("Device \(device)"), sampleRate: 48_000, channels: 1, heard: HeardChannels(of: 1, stereo: .named(1, 1)))
    }

    /// The microphone of the device that is the default until a test moves it.
    public static let microphone = microphone(on: 1)

    /// What each opening does, in order: an error to throw, or nil to succeed.
    private var launches: [(any Error)?]
    /// What an opening past the end of the script does: throw this, as a device that cannot feed
    /// the pipeline does, or succeed when nil.
    public var failingToLaunch: (any Error)?
    /// What `watchDefaultInput` does: an error to throw, or nil to watch.
    private let watch: (any Error)?
    public private(set) var engines: [Engine] = []
    public private(set) var onDefaultInputChange: (@MainActor () -> Void)?
    public private(set) var watchDisposals = 0
    /// Every microphone readied, in the order they were readied. Kept rather than counted,
    /// because a readied input is watched for its whole life and a test that could only count
    /// them could not reach one that was never opened.
    public private(set) var inputs: [Input] = []
    /// Which device is the system default input. Moved apart from the notification that
    /// announces it, because CoreAudio delivers that notification in no fixed order against the
    /// bound device's own reports, and a test has to be able to land either one first.
    public private(set) var defaultInput = 1

    /// How many microphones have been readied. Never a device: the count exists so a test can say
    /// that resting readied one and opened nothing.
    public var prepared: Int { inputs.count }

    /// Whether a microphone readied here stays readying until the test finishes it, which is how a
    /// test reaches the stretch a slow input spends being reached.
    public let holdsReadying: Bool

    /// Moved whenever what a test awaits on this hardware changes - a microphone readied, a wait
    /// reaching one, an engine opened or disposed - so a test awaits the change rather than
    /// polling for it. [LAW:no-ambient-temporal-coupling]
    public let changed = Changes()

    public init(launches: [(any Error)?] = [], watch: (any Error)? = nil, holdsReadying: Bool = false) {
        self.launches = launches
        self.watch = watch
        self.holdsReadying = holdsReadying
    }

    /// The engine opened last, which capture is listening to while it is not disposed. Under
    /// `shut` there is one only while a press is open, so speaking between presses is a test
    /// describing a Mac that does not exist.
    public var live: Engine {
        guard let engine = engines.last, !engine.disposed else { preconditionFailure("nothing is capturing; the microphone opens for a press unless the resting mode holds it") }
        return engine
    }

    /// The microphone readied last, which capture holds until the next readying.
    public var readied: Input {
        guard let input = inputs.last else { preconditionFailure("nothing has readied a microphone; capture readies one when it starts") }
        return input
    }

    public func prepareInput(onStale: @escaping @MainActor () -> Void) -> any PreparedInput {
        let input = Input(self, readying: inputs.count + 1, onStale: onStale)
        inputs.append(input)
        changed.note()  // [LAW:no-ambient-temporal-coupling] a microphone was readied
        return input
    }

    fileprivate func open(on input: Input, appending: @escaping @Sendable ([Float], HostTime) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) throws -> Disposal {
        if let error = launches.isEmpty ? failingToLaunch : launches.removeFirst() { throw error }
        let engine = Engine(input: input, appending: appending, onFailure: onFailure)
        engines.append(engine)
        changed.note()  // [LAW:no-ambient-temporal-coupling] an engine opened
        return { [changed = changed] in engine.disposed = true; changed.note() }  // and disposed
    }

    public func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        if let watch { throw watch }
        onDefaultInputChange = onChange
        return { [self] in
            onDefaultInputChange = nil
            watchDisposals += 1
        }
    }

    public var isWatching: Bool { onDefaultInputChange != nil }

    /// The system default input device changed, and the watch was told.
    public func changeDefaultInput() throws {
        moveDefaultInput()
        try announceDefaultInput()
    }

    /// Another device became the default input, and the notification saying so has not landed yet.
    public func moveDefaultInput() { defaultInput += 1 }

    /// The notification that the default input changed lands.
    public func announceDefaultInput() throws {
        let onChange = try #require(onDefaultInputChange, "nothing is watching the default input")
        onChange()
    }
}
