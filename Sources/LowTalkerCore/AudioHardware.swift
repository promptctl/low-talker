import AVFoundation
import CoreAudio

/// Gives back something the hardware handed out: an engine, a listener. Called once.
public typealias Disposal = @MainActor () -> Void

/// A microphone that has paid, or is paying elsewhere, everything it can pay before being
/// opened.
///
/// Preparing one takes no device: nothing is captured and macOS lights no indicator until
/// `open`. That is why this is a value rather than a step inside `open`: reaching a
/// microphone costs far more than opening one already reached, and none of the reaching
/// opens a device, so an app that prepares while it is idle leaves a press paying only the
/// opening - which is what lets `shut` keep both the closed microphone and the head of the
/// first word. What each part costs is measured in `HALInput`, where the split is made.
///
/// The paying is not done by whoever asked for it. A readying handed back from
/// `AudioHardware.prepareInput` may still be under way, and nothing that holds one has to
/// know: `open` waits for whatever of it is left, and `isOnTheDefaultInput` answers for the
/// device it was asked to bind until it has bound one. [LAW:no-ambient-temporal-coupling]
///
/// [LAW:types-are-the-program] Prepared and open are two facts about the microphone, and
/// this type carries the first: a press cannot reach a device nothing prepared, and
/// preparing cannot open one. The second is the `Disposal` `open` hands back.
@MainActor
public protocol PreparedInput {
    /// Opens the device, and says which one it opened and in what format. Every buffer it captures arrives at `appending` as pipeline
    /// samples with the host time its first sample was captured at, on a thread of the
    /// press's own - never CoreAudio's IO thread, which has a deadline to keep - and
    /// `onFailure` reports on the main actor when one could not be converted or placed in
    /// time. Throws when the device cannot feed the pipeline - including when
    /// there was nothing to prepare, which is the one moment that matters and the one place
    /// every caller already answers it. [LAW:single-enforcer]
    ///
    /// Both of those are facts about a press, which is why they are asked for here and why
    /// the device going away or changing shape is not: that one is a fact about the binding,
    /// and it is asked for where the binding is made, in `AudioHardware.prepareInput`.
    ///
    /// The disposal gives the device back and leaves the input prepared, so the next
    /// press opens it at the prepared price rather than at the first one's.
    ///
    /// Waits for the rest of a readying still under way, which is the one moment anything
    /// has to: a press is what the microphone is readied for.
    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) throws -> OpenedInput

    /// Whether the device this is bound to is the system default input now.
    ///
    /// Read off the hardware, because nothing else can answer it. A default-input
    /// notification says only that the default changed - not to what, and not whether
    /// anything has answered it yet - and CoreAudio does not order it against the bound
    /// device's own watch, so a change can be answered before its notification lands.
    /// Remembering what was owed kept a second copy of this fact, and it outlived the
    /// answer. [FRAMING:representation] Read the territory, not a map of it.
    var isOnTheDefaultInput: Bool { get }

    /// Waits for readying to finish - what `open` does first, for a caller that needs the
    /// microphone reached before a press can come for it. What readying came to is not
    /// answered here: a readying that failed throws at `open`, which is where every caller
    /// already answers a microphone that cannot be had. [LAW:single-enforcer]
    func waitUntilReadied()
}

/// A microphone that opened: what gives it back, and the device it is.
public struct OpenedInput {
    public let dispose: Disposal
    public let input: MicrophoneInput

    public init(dispose: @escaping Disposal, input: MicrophoneInput) {
        self.dispose = dispose
        self.input = input
    }
}

/// The device a microphone is bound to and the format it delivers in, before conversion to
/// the pipeline's. [LAW:nothing-unseen] What a press's record names its microphone by, so a
/// press that heard nothing says which device heard nothing.
public struct MicrophoneInput: Sendable, Equatable, CustomStringConvertible {
    public let device: AudioObjectID
    /// The name macOS shows for it, or why CoreAudio would not say: an input is no less
    /// openable for lacking a name, so this is a fact on the record rather than a refusal.
    public let name: Result<String, AudioHardwareError>
    public let sampleRate: Double
    public let channels: Int

    public init(device: AudioObjectID, name: Result<String, AudioHardwareError>, sampleRate: Double, channels: Int) {
        self.device = device
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var description: String {
        let named = switch name {
        case .success(let name): "\"\(name)\""
        case .failure(let error): "an input whose name is unknown (\(error))"
        }
        return "\(named) (device \(device), \(Int(sampleRate)) Hz, \(channels) channel\(channels == 1 ? "" : "s"))"
    }
}

/// What the system does for capture: ready a microphone, open it, and say when the
/// default input device changes.
///
/// [LAW:effects-at-boundaries] Every one of these is an effect against CoreAudio. They
/// sit behind this seam so the state machine above them (which microphone is open, when
/// to open another, what an outage was) runs in tests against hardware a test controls,
/// and on a CI machine that has no microphone at all.
@MainActor
public protocol AudioHardware {
    /// Readies a microphone without opening it, and without waiting for it: the reaching
    /// happens off the main actor, because this is called from inside the notifications that
    /// say a device changed, and the main actor they land on is the one a key-down needs.
    ///
    /// It also watches the device it was readied against for the whole life of the input
    /// that comes back: `onStale` is called on the main actor when this input has stopped
    /// being one to open, whether or not a press has it open. The device going away or
    /// changing shape is how that happens to a resting microphone; a press whose microphone
    /// cannot be shown to have gone dark is how it happens to a held one, and `HALInput` is
    /// where that reading is taken. What the callers of this share is the answer - ready
    /// another - so the rule is what is promised here rather than the list of ways it comes
    /// about. [LAW:one-source-of-truth]
    ///
    /// That lifetime is why the callback is asked for here rather than at `open`. A prepared
    /// input is bound to one device and fixes its format, its render buffer and its
    /// converter against the shape that device had when it was readied, so it can go stale
    /// for exactly as long as it exists - and watching only from `open` to its disposal left
    /// a device that renegotiates its format while the microphone rests heard by nobody, a
    /// headset changing codec being the ordinary way that happens. The next press then opened
    /// against the shape before it and resampled the utterance twice.
    /// [LAW:no-ambient-temporal-coupling] The fact and the watch on it have one lifetime now.
    ///
    /// A switch of *which* device is the default is a different event with a different
    /// answer - the bound device is still healthy and a press on it need not be cut - and it
    /// is `watchDefaultInput`'s to report.
    ///
    /// Never throws, and that is deliberate: what can go wrong about reaching a
    /// microphone is not a thing the resting state can answer. Capture rests between
    /// presses, and a rest that could fail would have to decide whether a Mac with no
    /// microphone is a failed capture - which would leave a device change relaunching an
    /// engine a config asked to keep shut. So a preparation that could not happen is
    /// carried in the input and thrown when a press opens it. [LAW:no-silent-failure]
    func prepareInput(onStale: @escaping @MainActor () -> Void) -> any PreparedInput

    /// Calls `onChange` on the main actor each time the system default input device
    /// changes, until disposed.
    func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal
}

public enum AudioHardwareError: Error, Equatable, CustomStringConvertible {
    case defaultInputWatchFailed(OSStatus)
    /// A listener on one bound device - its liveness or its stream format - rather than on
    /// which device is the default. Two different subsystems, and a person reading the
    /// failure of a press is the one who has to tell them apart.
    case deviceWatchFailed(OSStatus)
    /// A buffer arrived with no host clock behind its time.
    case bufferWithoutTime
    case noInputComponent
    case componentUnavailable(OSStatus)
    case inputUnavailable(OSStatus)
    case noDefaultInput(OSStatus)
    /// Readying a microphone left the device running on this process's account, so the
    /// split the whole resting state rests on - reach a microphone without taking one - did
    /// not hold for this device.
    case preparingOpenedTheDevice(AudioObjectID)
    /// The device would not say whether it is running, so nothing can say what the
    /// menu-bar indicator is showing for it.
    case runningStateUnreadable(OSStatus)
    case nameUnreadable(OSStatus)
    case renderFailed(OSStatus)
    /// The device asked to hand over more audio at once than it offered when the press opened.
    case overlongSlice(frames: Int, capacity: Int)
    /// The thread handing a press's audio over fell so far behind the device that the ring
    /// between them filled, and slices were dropped rather than make the IO thread wait.
    case deliveryFellBehind(dropped: Int)

    public var description: String {
        switch self {
        case .defaultInputWatchFailed(let status): "CoreAudio refused a listener on the default input device (status \(status))"
        case .deviceWatchFailed(let status): "CoreAudio refused a listener on the input device this microphone is bound to (status \(status))"
        case .bufferWithoutTime: "the input device delivered a buffer with no host time; nothing can say when its samples were captured"
        case .noInputComponent: "this Mac has no HAL audio unit to capture through"
        case .componentUnavailable(let status): "the HAL audio unit could not be instantiated (status \(status))"
        case .inputUnavailable(let status): "the input device would not be made ready to capture (status \(status))"
        case .noDefaultInput(let status): "this Mac has no default input device (status \(status))"
        case .preparingOpenedTheDevice(let device): "readying a microphone opened device \(device) instead of only reaching it"
        case .runningStateUnreadable(let status): "CoreAudio would not say whether the input device is running (status \(status))"
        case .nameUnreadable(let status): "CoreAudio would not say the input device's name (status \(status))"
        case .renderFailed(let status): "the input device refused to hand over a buffer it had announced (status \(status))"
        case .overlongSlice(let frames, let capacity): "the input device asked to hand over \(frames) frames at once, past the \(capacity) it offered when the press opened"
        case .deliveryFellBehind(let dropped): "the microphone's audio was handed over too slowly to keep up with the device, and \(dropped) of its buffers were lost"
        }
    }

    /// [LAW:no-silent-failure] The one place an OSStatus becomes a thrown error, so no
    /// call in the capture path can be checked by eye and then not checked.
    static func check(_ status: OSStatus, _ fault: (OSStatus) -> AudioHardwareError) throws(AudioHardwareError) {
        guard status == noErr else { throw fault(status) }
    }
}

extension HostTime {
    /// [LAW:parse-dont-validate] The one place a CoreAudio stamp becomes a host time.
    /// It counts the machine's raw ticks rather than nanoseconds, and CoreAudio may hand
    /// out a time with no host clock behind it at all - samples that cannot be placed in
    /// time are samples no session can be cut from, so that is a failed engine rather
    /// than a guess. [LAW:no-silent-failure]
    init(_ when: AVAudioTime) throws {
        guard when.isHostTimeValid else { throw AudioHardwareError.bufferWithoutTime }
        self.init(uptime: .seconds(AVAudioTime.seconds(forHostTime: when.hostTime)))
    }

    init(_ stamp: AudioTimeStamp) throws {
        guard stamp.mFlags.contains(.hostTimeValid) else { throw AudioHardwareError.bufferWithoutTime }
        self.init(uptime: .seconds(AVAudioTime.seconds(forHostTime: stamp.mHostTime)))
    }
}

public struct SystemAudioHardware: AudioHardware {
    public init() {}

    public func prepareInput(onStale: @escaping @MainActor () -> Void) -> any PreparedInput {
        HALInput(onStale: onStale)
    }

    public func watchDefaultInput(_ onChange: @escaping @MainActor () -> Void) throws -> Disposal {
        let remove = try listen(
            to: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            on: AudioObjectID(kAudioObjectSystemObject),
            refused: AudioHardwareError.defaultInputWatchFailed,
            onChange
        )
        return {
            let status = remove()
            precondition(status == noErr, "CoreAudio refused to remove the default input listener it added (status \(status))")
        }
    }
}
