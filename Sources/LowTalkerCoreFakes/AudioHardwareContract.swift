import LowTalkerCore
import Synchronization
import Uptime

/// Capture hardware's semantics, stated once. Each statement runs one fresh hardware and says
/// every way it disagreed; nothing, when it agreed. `FakeHardware` runs it. `SystemAudioHardware`
/// cannot run inside the suite: a CI runner has no microphone. [LAW:one-source-of-truth]
@MainActor
public struct AudioHardwareContract {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// Readying a microphone opens no device.
        case readyingOpensNothing
        /// An open microphone hands over what the device hears at `appending`.
        case anOpenMicrophoneDeliversWhatItHears
        /// The disposal shuts the device and leaves the input prepared, so it opens again.
        case aDisposedMicrophoneOpensAgain
        /// An input is on the default input until another device becomes the default.
        case anInputIsOnTheDefaultUntilTheDefaultMoves
        /// The default-input watch is called at each change until it is disposed, and not after.
        case theDefaultInputWatchHearsUntilDisposed

        public var description: String {
            switch self {
            case .readyingOpensNothing: "readying opens nothing"
            case .anOpenMicrophoneDeliversWhatItHears: "an open microphone delivers what it hears"
            case .aDisposedMicrophoneOpensAgain: "a disposed microphone opens again"
            case .anInputIsOnTheDefaultUntilTheDefaultMoves: "an input is on the default until the default moves"
            case .theDefaultInputWatchHearsUntilDisposed: "the default-input watch hears until disposed"
            }
        }
    }

    /// One hardware under test, and the world around it a statement moves.
    public struct Subject {
        public let hardware: any AudioHardware
        /// How many devices this process holds open now.
        public let opened: @MainActor () -> Int
        /// The device open now hears `samples`.
        public let hear: @MainActor ([Float]) -> Void
        /// Another device becomes the system default input, and the system says so.
        public let moveDefault: @MainActor () throws -> Void

        public init(hardware: any AudioHardware, opened: @escaping @MainActor () -> Int, hear: @escaping @MainActor ([Float]) -> Void, moveDefault: @escaping @MainActor () throws -> Void) {
            self.hardware = hardware
            self.opened = opened
            self.hear = hear
            self.moveDefault = moveDefault
        }
    }

    /// A fresh hardware, nothing readied on it.
    public let subject: @MainActor () -> Subject

    public init(subject: @escaping @MainActor () -> Subject) {
        self.subject = subject
    }

    public func disagreements(with statement: Statement) throws -> [String] {
        let subject = subject()
        let hardware = subject.hardware
        switch statement {
        case .readyingOpensNothing:
            _ = hardware.prepareInput(onStale: {})
            return subject.opened() == 0 ? [] : ["readying held \(subject.opened()) devices open"]
        case .anOpenMicrophoneDeliversWhatItHears:
            let heard = Heard()
            let opened = try hardware.prepareInput(onStale: {}).open(appending: { samples, _ in heard.samples.withLock { $0 += samples } }, onFailure: { _ in })
            defer { opened.dispose() }
            subject.hear([0.25, -0.5])
            let delivered = heard.samples.withLock { $0 }
            return delivered == [0.25, -0.5] ? [] : ["delivered \(delivered) of [0.25, -0.5]"]
        case .aDisposedMicrophoneOpensAgain:
            let input = hardware.prepareInput(onStale: {})
            try input.open(appending: { _, _ in }, onFailure: { _ in }).dispose()
            var disagreements = subject.opened() == 0 ? [] : ["a disposed microphone left \(subject.opened()) devices open"]
            let again = try input.open(appending: { _, _ in }, onFailure: { _ in })
            if subject.opened() != 1 { disagreements.append("opening again held \(subject.opened()) devices open") }
            again.dispose()
            return disagreements
        case .anInputIsOnTheDefaultUntilTheDefaultMoves:
            let input = hardware.prepareInput(onStale: {})
            var disagreements = input.isOnTheDefaultInput ? [] : ["a fresh input was not on the default input"]
            let watch = try hardware.watchDefaultInput {}
            defer { watch() }
            try subject.moveDefault()
            if input.isOnTheDefaultInput { disagreements.append("an input stayed on the default input after it moved") }
            return disagreements
        case .theDefaultInputWatchHearsUntilDisposed:
            let changes = Counted()
            let watch = try hardware.watchDefaultInput { changes.count += 1 }
            try subject.moveDefault()
            watch()
            try subject.moveDefault()
            return changes.count == 1 ? [] : ["the watch heard \(changes.count) changes, one before its disposal and one after"]
        }
    }
}

/// What a microphone delivered, from the thread it delivers on.
private final class Heard: Sendable {
    let samples = Mutex<[Float]>([])
}

@MainActor private final class Counted {
    var count = 0
}
