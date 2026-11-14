import Dispatch
import Identity
import os
import Uptime

extension Logger {
    /// [LAW:one-source-of-truth] The `hotkey` category of the unified log, for everything
    /// the hotkey, its modifier feed and its input method's notices hear and decide.
    static let hotkey = Logger(subsystem: AppIdentity.bundleIdentifier, category: "hotkey")
}

/// What the loop that heard a press's `began` says back when it refused the press: nothing will
/// listen, so the hotkey must not latch it as a tap. A handler that took a transition says nil.
public struct PressRefusal: Sendable {
    public init() {}
}

/// The hotkey for the life of the app: the modifier keys as the window server's events tell
/// them, a detector reading them, and the presses it finds handed on by the main queue.
@MainActor
public final class Hotkey {
    nonisolated public static let defaultTapThreshold: Duration = .milliseconds(250)
    /// The chord listened for where the config names no other: Right Option.
    nonisolated public static let defaultChord = KeyChord(modifiers: .rightOption)

    /// The chord in the words a person presses it by, in `Modifier.allCases` order, so one
    /// chord always spells one name: `rightOption` as "Right Option", the case's own name
    /// split at its capitals, so no table of names stands beside the cases to fall out of
    /// step with them.
    nonisolated public static func named(_ chord: KeyChord) -> String {
        named(chord.modifiers)
    }

    /// Modifiers held together, named as a chord is.
    nonisolated public static func named(_ modifiers: Set<Modifier>) -> String {
        Modifier.allCases.filter(modifiers.contains).map { modifier in
            modifier.rawValue.reduce(into: "") { name, letter in
                name += name.isEmpty ? letter.uppercased() : letter.isUppercase ? " \(letter)" : String(letter)
            }
        }.joined(separator: "+")
    }

    /// Every chord `config` listens for, named as above, in the order the file declares its
    /// modes.
    nonisolated public static func named(in config: Config) -> String {
        config.modes.map { named($0.chord) }.joined(separator: " or ")
    }

    /// What the hotkey did: each transition it handed on, and each press the loop refused at
    /// `began`. [LAW:nothing-unseen] Every one is recorded, and `log` renders it in the unified
    /// log, so what a test reads is what the log says.
    public enum Record: Hashable, Sendable, CustomStringConvertible {
        case transition(HotkeyDetector.Transition)
        /// The press begun at this moment was refused by the loop. Whether the detector ended it
        /// then or leaves it to end as the chord comes up, its ending is a transition of its own.
        case refused(pressBegunAt: HostTime)

        public var description: String {
            switch self {
            case .transition(let transition): "\(transition)"
            case .refused(let moment): "the press begun \(moment.onUptime) was refused"
            }
        }
    }

    /// The app's rendering of a record: a line under the `hotkey` category.
    nonisolated public static func log(_ record: Record) {
        Logger.hotkey.notice("\(record, privacy: .public)")
    }

    private let feed: any ModifierFeed
    private let recording: @MainActor (Record) -> Void
    private var detector: HotkeyDetector
    /// The feed that is running, and the handler its presses go to - kept together because a
    /// press still open when the feed stops is ended at that same handler.
    private var installed: (dispose: Disposal, onTransition: Handler)?

    /// Hears each transition and answers whether it refused the press that began.
    public typealias Handler = @MainActor (HotkeyDetector.Transition) -> PressRefusal?

    /// Every record goes to `recording`.
    public init(modes: Modes, tapThreshold: Duration = defaultTapThreshold, feed: any ModifierFeed, recording: @escaping @MainActor (Record) -> Void = Hotkey.log) {
        self.feed = feed
        self.recording = recording
        detector = HotkeyDetector(modes: modes, tapThreshold: tapThreshold)
    }

    /// The app's hotkey: the modes `config` names, heard by their chords from the window
    /// server's own events.
    public convenience init(listeningFor config: Config, tapThreshold: Duration = defaultTapThreshold) {
        self.init(modes: config.modes, tapThreshold: tapThreshold, feed: ModifierMonitor())
    }

    public var phase: HotkeyDetector.Phase { detector.phase }

    /// [LAW:one-source-of-truth] The clock the feed stamps its key events on, which a refusal is
    /// timed on too, and which whatever times a press from those stamps must read.
    public var clock: HostClock { feed.clock }

    /// Whether the feed is running and presses are being heard.
    ///
    /// False before the first `start`, and after `stop`. [LAW:one-source-of-truth] derived
    /// from the installation itself, so it cannot disagree with whether anything is actually
    /// listening - which is the question a caller offering the user a way to start it again
    /// has to ask.
    public var isWatching: Bool { installed != nil }

    /// Starts watching. Each press begins and ends at `onTransition`, on the main actor and
    /// on the main queue, and a press its handler refuses at `began` is not a tap that latches.
    /// [LAW:single-enforcer] The detector applies the refusal, here, for every handler, and a
    /// handler must answer one: there is no start whose handler can leave the answer out.
    /// `start(feeding:)` is the one handler the app starts with.
    public func start(_ onTransition: @escaping Handler) throws {
        stop()
        let dispose = try feed.install { [weak self] event in self?.handle(event, onTransition) }
        installed = (dispose, onTransition)
    }

    /// Listens for `modes` from the next press on, without stopping the feed or ending a
    /// press already open; see `HotkeyDetector.listen(for:)`.
    public func listen(for modes: Modes) {
        detector.listen(for: modes)
    }

    /// A key that steers dictation was typed, Return at a moment on the clock key events are
    /// stamped by, with the chord up, or Escape. A press that ends does so delivered like every
    /// other transition, so `Dictation.press` still sees it in order.
    public func steer(_ steering: HotkeyDetector.Steering) -> HotkeyDetector.Steered {
        let steered = detector.steer(steering)
        if case .ended(let transition) = steered, let installation = installed {
            deliver(transition, to: installation.onTransition)
        }
        return steered
    }

    /// Stops watching. A press still open is ended here as `.lapsed`, at the handler it
    /// began at: once the feed has stopped its release can never arrive, and a press left open
    /// is a microphone left open with nothing to close it.
    /// [LAW:no-ambient-temporal-coupling]
    public func stop() {
        let unfinished = detector.lapse()
        let was = installed
        installed = nil
        was?.dispose()
        detector = HotkeyDetector(modes: detector.modes, tapThreshold: detector.tapThreshold)
        unfinished.map { transition in
            was.map { installation in deliver(transition, to: installation.onTransition) }
        }
    }

    /// Stops watching, and returns once everything already handed to the main queue has
    /// been delivered.
    ///
    /// [LAW:single-enforcer] What a caller waiting out a loop's sessions needs is both of
    /// these, in this order, and the pairing lives here rather than at each call site.
    /// Presses leave by the main queue, so a key-up told moments ago can still be
    /// sitting on it, and a wait on the sessions a loop has been given cannot cover one
    /// that has not reached it yet. Spelled out at three teardowns and forgotten at a
    /// fourth, that is a final session lost in silence - which is the failure the wait was
    /// put there to prevent.
    ///
    /// [LAW:no-ambient-temporal-coupling] The queue itself is waited on, never a duration
    /// chosen to be long enough, so this is exactly as long as the work and no longer.
    public func stopAndDeliver() async {
        stop()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // A non-Sendable @MainActor class is only ever held by main-actor code, so its
    // last release is on the main actor; assumeIsolated traps if that stops holding.
    // Only the feed stops: nothing is left to hear an ending told from here.
    deinit { MainActor.assumeIsolated { installed?.dispose() } }

    /// Records `transition`, then hands it to `onTransition` on the main queue, after the event
    /// that caused it has been read.
    ///
    /// [LAW:single-enforcer] The one way anything leaves this class, so every transition
    /// is recorded, a lapse at `stop` among them. The main queue is
    /// first-in-first-out, which is what keeps a `began` ahead of the `ended` that
    /// follows it: `Dictation.press` traps on a pair out of order rather than repairing
    /// one, so the order is a correctness property and not a preference.
    private func deliver(_ transition: HotkeyDetector.Transition, to onTransition: @escaping Handler) {
        recording(.transition(transition))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let refusal = onTransition(transition)
                if case .began(_, let moment) = transition, refusal != nil { self?.refuse(pressBegunAt: moment, to: onTransition) }
            }
        }
    }

    /// The press begun at `moment` was refused by the loop. [LAW:nothing-unseen] The record says
    /// so whether the detector ends the press now or leaves it to end as the chord comes up.
    private func refuse(pressBegunAt moment: HostTime, to onTransition: @escaping Handler) {
        recording(.refused(pressBegunAt: moment))
        detector.refuse(pressBegunAt: moment, at: clock.now).map { deliver($0, to: onTransition) }
    }

    private func handle(_ event: KeyEvent, _ onTransition: @escaping Handler) {
        for transition in detector.handle(event) { deliver(transition, to: onTransition) }
    }
}
