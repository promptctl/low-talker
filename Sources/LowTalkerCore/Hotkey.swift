import Dispatch
import Identity
import os

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

    private let feed: any ModifierFeed
    private var detector: HotkeyDetector
    /// The feed that is running, and the handler its presses go to - kept together because a
    /// press still open when the feed stops is ended at that same handler.
    private var installed: (dispose: Disposal, onTransition: Handler)?

    /// Hears each transition and answers whether it refused the press that began.
    public typealias Handler = @MainActor (HotkeyDetector.Transition) -> PressRefusal?

    public init(modes: Modes, tapThreshold: Duration = defaultTapThreshold, feed: any ModifierFeed) {
        self.feed = feed
        detector = HotkeyDetector(modes: modes, tapThreshold: tapThreshold)
    }

    /// The app's hotkey: the modes `config` names, heard by their chords from the window
    /// server's own events.
    public convenience init(listeningFor config: Config, tapThreshold: Duration = defaultTapThreshold) {
        self.init(modes: config.modes, tapThreshold: tapThreshold, feed: ModifierMonitor())
    }

    public var phase: HotkeyDetector.Phase { detector.phase }

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

    /// Logs `transition`, then hands it to `onTransition` on the main queue, after the event
    /// that caused it has been read.
    ///
    /// [LAW:single-enforcer] The one way anything leaves this class, so every transition
    /// is logged, a lapse at `stop` among them. The main queue is
    /// first-in-first-out, which is what keeps a `began` ahead of the `ended` that
    /// follows it: `Dictation.press` traps on a pair out of order rather than repairing
    /// one, so the order is a correctness property and not a preference.
    private func deliver(_ transition: HotkeyDetector.Transition, to onTransition: @escaping Handler) {
        Logger.hotkey.notice("\(transition, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let refusal = onTransition(transition)
                if case .began(_, let moment) = transition, refusal != nil { self?.refuse(pressBegunAt: moment, to: onTransition) }
            }
        }
    }

    /// The press begun at `moment` was refused by the loop. [LAW:nothing-unseen] The log says so
    /// whether the detector ends the press now or leaves it to end as the chord comes up.
    private func refuse(pressBegunAt moment: HostTime, to onTransition: @escaping Handler) {
        Logger.hotkey.notice("the press begun at \(moment.uptime / .milliseconds(1)) ms of uptime was refused")
        detector.refuse(pressBegunAt: moment, at: .now).map { deliver($0, to: onTransition) }
    }

    private func handle(_ event: KeyEvent, _ onTransition: @escaping Handler) {
        for transition in detector.handle(event) { deliver(transition, to: onTransition) }
    }
}
