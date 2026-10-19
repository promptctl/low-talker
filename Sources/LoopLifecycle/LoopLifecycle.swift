/// What becomes of the loop - the hotkey, the input method and the dictation behind them - as
/// readings of the requirements arrive: brought up, rebuilt, or left as it stands. Never two
/// come-ups at once, never two rebuilds side by side, and nothing new once a quit is asked for.
///
/// Every effect is the app's, handed in as a closure, so this bookkeeping runs under
/// `swift test` against fakes. [LAW:effects-at-boundaries]
@MainActor
public final class LoopLifecycle {
    /// What a reading was taken to mean, and what came of the work it started, told as it happens.
    public enum Event: Equatable, Sendable, CustomStringConvertible {
        /// A reading of the requirements, and what it was taken to mean.
        case settled(Outcome)
        /// A come-up asked for while one is under way, which joins it.
        case joined
        /// The come-up's capture step: what it came to, and how long it took. A slow or
        /// Bluetooth input is reached in this wait.
        case capture(Capture, waited: Duration)
        /// Work asked for after the quit, and not started.
        case refused(Work)

        public var description: String {
            switch self {
            case .settled(let outcome): "reading: \(outcome)"
            case .joined: "come-up: one is under way; joining it rather than starting a second"
            case .capture(.started, let waited): "come-up: waited \(waited) for capture to start with its microphone readied"
            case .capture(.running, _): "come-up: capture was already holding the microphone, and is left running"
            case .capture(.notStarted, let waited): "come-up: capture did not start, after \(waited); the loop stays down"
            case .refused(let work): "\(work.rawValue): not started, as the app is quitting"
            }
        }
    }

    /// What one reading does to the loop, decided from where things stand when it arrives.
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        /// Nothing: the app is on its way out.
        case quitting
        /// Owed to the come-up or rebuild under way, which may have read the grants before this
        /// reading did, and paid with a fresh reading when the last of them ends.
        case owed
        /// Nothing: a requirement is unmet, and setup is where it is met.
        case unmet
        /// No hotkey is watching, whatever took it down, so the loop is brought up.
        case comingUp
        /// The input method was switched on since the loop went up, so the loop is rebuilt and
        /// the install selects it.
        case rebuilding
        /// Nothing: the loop is up and has nothing to take up.
        case up

        public var description: String {
            switch self {
            case .quitting: "dropped, as the app is quitting"
            case .owed: "owed to the come-up or rebuild under way"
            case .unmet: "a requirement is unmet; the loop is left as it stands"
            case .comingUp: "every requirement is met and no hotkey is watching; bringing the loop up"
            case .rebuilding: "the input method was switched on; rebuilding the loop to select it"
            case .up: "every requirement is met and the loop is up"
            }
        }
    }

    /// What the come-up's capture step came to. A loop is built over the first two.
    public enum Capture: Equatable, Sendable {
        /// Capture started, holding the microphone readied.
        case started
        /// Capture was already holding the microphone, and was left running.
        case running
        /// Capture did not start, and the app has said why.
        case notStarted
    }

    /// The two kinds of work a reading can start.
    public enum Work: String, Sendable {
        case comeUp = "come-up"
        case rebuild
    }

    private let startCapture: @MainActor () async -> Capture
    private let adopt: @MainActor () async -> Void
    private let requirementsMet: @MainActor () -> Bool
    private let watching: @MainActor () -> Bool
    private let told: @MainActor (Event) -> Void

    /// - Parameters:
    ///   - startCapture: brings capture up holding the microphone, or leaves one already holding
    ///     it running, and says which. One that did not start has already said why.
    ///   - adopt: takes the old loop down, waits out its sessions, and builds the new one.
    ///   - requirementsMet: a fresh reading: whether every requirement is met. Read when an owed reading
    ///     is paid.
    ///   - watching: whether a hotkey is watching now.
    ///   - told: every event, as it happens.
    public init(
        startCapture: @escaping @MainActor () async -> Capture,
        adopt: @escaping @MainActor () async -> Void,
        requirementsMet: @escaping @MainActor () -> Bool,
        watching: @escaping @MainActor () -> Bool,
        told: @escaping @MainActor (Event) -> Void
    ) {
        self.startCapture = startCapture
        self.adopt = adopt
        self.requirementsMet = requirementsMet
        self.watching = watching
        self.told = told
    }

    /// The come-up under way, from the moment it is decided until it ends.
    private var comingUp: Task<Void, Never>?
    /// The rebuild in progress, which the next one waits behind.
    ///
    /// [LAW:no-ambient-temporal-coupling] A rebuild awaits the old loop's sessions, and a
    /// second one asked for during that wait would otherwise build a loop beside the first
    /// one's and leave a hotkey up that nothing can take down. Each rebuild awaits the one
    /// before it, so there is only ever one loop being built.
    private var rebuilding: Task<Void, Never>?
    /// How many rebuilds are queued or running. While any is, the loop is being rebuilt by
    /// someone already, and a reading taken in the meantime is that rebuild's to take up.
    private var rebuildsInFlight = 0
    /// Set when a reading arrived while a come-up or a rebuild was running, and settled - with a
    /// fresh reading - by whichever of them ends last.
    private var readingOwed = false
    /// Set when the input method was switched on; cleared once a reading has acted on it.
    private var inputMethodSwitchedOn = false
    /// Set the moment a quit is asked for, and never cleared. `rebuild` and the come-up refuse
    /// once it is set.
    ///
    /// A rebuild taken after that point would chain behind the one the quit is waiting on,
    /// and put a fresh hotkey up after the quit has taken the old one down, with nothing
    /// left to wait for its sessions. [LAW:no-ambient-temporal-coupling]
    public private(set) var quitting = false

    /// Whether the loop is being brought up or rebuilt by someone already.
    private var busy: Bool { comingUp != nil || rebuildsInFlight > 0 }

    /// Takes up one reading of the requirements: brings the loop up when no hotkey is watching,
    /// whatever took it down, and rebuilds a loop that is up when the input method was just
    /// switched on. Every reading is a retry, so a loop that came down is never down until a
    /// relaunch.
    ///
    /// [LAW:dataflow-not-control-flow] Decided from where things stand, not from a difference
    /// between two readings, so it holds however a grant arrived and whichever reading first
    /// sees it. The outcome is decided whole and told before it is acted on.
    public func settle(requirementsMet: Bool) {
        let outcome: Outcome =
            if quitting { .quitting }
            else if busy { .owed }
            else if !requirementsMet { .unmet }
            else if !watching() { .comingUp }
            else if inputMethodSwitchedOn { .rebuilding }
            else { .up }
        told(.settled(outcome))
        switch outcome {
        case .owed:
            readingOwed = true
        case .comingUp:
            inputMethodSwitchedOn = false
            comeUp()
        case .rebuilding:
            inputMethodSwitchedOn = false
            rebuild()
        case .quitting, .unmet, .up:
            break
        }
    }

    /// A request to switch the input method on went through: switched on is not selected, so
    /// the next reading that finds the loop up rebuilds it, and the install selects it.
    public func inputMethodWasSwitchedOn() {
        inputMethodSwitchedOn = true
    }

    /// From the microphone up: capture holding it, then the loop built in front of it, last, so
    /// no press can arrive before there is a capture to open a microphone for it.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// Called while a come-up is under way, it hands back that one rather than starting a
    /// second. The come-up is claimed in the same step that starts it, so a reading taken after
    /// the decision finds it claimed and is owed to its end.
    @discardableResult
    public func comeUp() -> Task<Void, Never> {
        if let comingUp {
            told(.joined)
            return comingUp
        }
        let this = Task {
            defer {
                comingUp = nil
                settleOwedReading()
            }
            // A capture started now could open the microphone after the quit let it go.
            guard !quitting else {
                told(.refused(.comeUp))
                return
            }
            let reaching = ContinuousClock.now
            let capture = await startCapture()
            told(.capture(capture, waited: reaching.duration(to: .now)))
            guard capture != .notStarted else { return }
            // A quit during the capture wait is refused by `rebuild`, the one place that refuses
            // it. [LAW:single-enforcer]
            await rebuild()?.value
        }
        comingUp = this
        return this
    }

    /// Takes the loop down and builds it again, queued behind any rebuild still in progress;
    /// see `rebuilding`. Counted in flight in the step that asks for it, so a reading taken
    /// after the decision is owed to its end, as a come-up's is.
    ///
    /// Refused once a quit is asked for, and nothing is handed back; see `quitting`. A caller
    /// that suspended before asking needs no check of its own. [LAW:single-enforcer]
    @discardableResult
    private func rebuild() -> Task<Void, Never>? {
        guard !quitting else {
            told(.refused(.rebuild))
            return nil
        }
        let before = rebuilding
        rebuildsInFlight += 1
        let this = Task {
            await before?.value
            await adopt()
            rebuildsInFlight -= 1
            settleOwedReading()
        }
        rebuilding = this
        return this
    }

    /// The one place an owed reading is paid: once nothing is bringing up or rebuilding the loop.
    private func settleOwedReading() {
        guard readingOwed, !busy else { return }
        readingOwed = false
        settle(requirementsMet: requirementsMet())
    }

    /// Asks for nothing new from here on, and hands back the rebuild in progress, which the
    /// quit lets finish so the loop it takes down is the last one.
    public func quit() -> Task<Void, Never>? {
        quitting = true
        return rebuilding
    }
}
