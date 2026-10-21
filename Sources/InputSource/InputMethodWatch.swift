import Insertion

/// What the app knows of its input method: the supervisor's latest word on the process, the
/// latest cursor arrival, which says the build of the process that told it, and the latest
/// process to end itself over its memory ceiling, which the person is told for as long as the
/// app runs, since the supervisor has the next process running within the second.
///
/// [LAW:one-source-of-truth] All are folded here and the standing is read off them, so the
/// supervisor and the notices never each write a status of their own. An overrun and the
/// supervisor's word that its process ended reach the app by different queues, so the
/// standing is the same whichever comes first. [LAW:no-ambient-temporal-coupling]
///
/// A build counts only for the process that said it: a loop rebuilt makes a new supervisor,
/// whose first word is the same running process again, and that process is still of the
/// build it said.
public struct InputMethodWatch: Sendable {
    private let app: Build
    private var process: InputMethodSupervisor.Event?
    private var arrival: CursorArrival?
    /// The process that said it is ending itself, for as long as it is the one the supervisor
    /// speaks of: once the supervisor has seen it end and opens another, or none, a process
    /// given its pid again is another one.
    private var ending: (pid: Int32, overrun: Overrun, ended: Bool)?
    /// The latest process to end itself over its memory ceiling, or nil while none has.
    public private(set) var lastOverrun: Overrun?
    /// The standing last shown, so the log says each one once.
    private var shown: InputMethodStanding?

    /// A standing to show, and whether it is one the log has not said yet.
    public struct Showing: Equatable, Sendable {
        public let standing: InputMethodStanding
        public let isNew: Bool
    }

    /// Watching for an app of `app`.
    public init(app: Build) { self.app = app }

    /// Every word of the supervisor's is shown, since the line may stand on what a rebuild put
    /// up while it set the input method up.
    public mutating func told(_ event: InputMethodSupervisor.Event) -> Showing {
        process = event
        switch event {
        case .ended(let pid, _): if pid == ending?.pid { ending?.ended = true }
        case .running, .notOpened: if ending?.ended == true { ending = nil }
        }
        return show(standing(of: event))
    }

    /// Kept whichever process told it, so a notice heard before the supervisor says that
    /// process is running counts once it does. Shown only when it moved the standing, so an
    /// arrival in each app the person moves to leaves whatever else the line says, a
    /// microphone that would not start included.
    public mutating func heard(_ notice: InputMethodNotice) -> Showing? {
        switch notice {
        case .cursorArrived(let arrival): self.arrival = arrival
        case let .overMemoryCeiling(pid, overrun):
            lastOverrun = overrun
            ending = switch process {
            case nil, .running(pid, _)?: (pid, overrun, false)
            case .ended(pid, _)?: (pid, overrun, true)
            // Heard after the supervisor moved past its process.
            default: nil
            }
        }
        guard let standing, standing != shown else { return nil }
        return show(standing)
    }

    /// Where the input method stands, or nil while the supervisor has said nothing.
    public var standing: InputMethodStanding? { process.map(standing(of:)) }

    private mutating func show(_ standing: InputMethodStanding) -> Showing {
        defer { shown = standing }
        return Showing(standing: standing, isNew: standing != shown)
    }

    private func standing(of process: InputMethodSupervisor.Event) -> InputMethodStanding {
        switch process {
        case .running(let pid, _): overran(pid) ?? running(pid)
        case .ended(let pid, _): overran(pid) ?? .ended(pid: pid)
        case .notOpened(let reason, _): .notOpened(reason)
        }
    }

    /// The process `pid` ending itself, if it said so.
    private func overran(_ pid: Int32) -> InputMethodStanding? {
        ending.flatMap { $0.pid == pid ? .overMemoryCeiling(pid: pid, $0.overrun) : nil }
    }

    private func running(_ pid: Int32) -> InputMethodStanding {
        guard let arrival, arrival.pid == pid else { return .running(pid: pid, build: .notYetSaid) }
        return BuildMismatch(app: app, inputMethod: arrival.build).map { .otherBuild(pid: pid, $0) }
            ?? .running(pid: pid, build: .sameBuild)
    }
}

/// Where the input method stands for the app.
public enum InputMethodStanding: Equatable, Sendable, CustomStringConvertible {
    /// Running, and words may go to it: its build is the app's, or it has not said its build
    /// yet. Not yet said is not refused here. Its greeting says the build before any words go,
    /// and the inserter refuses there. A process the supervisor launched is given the client
    /// in front at once (`InputMethodSupervisor`), so its first arrival follows straight away.
    /// One already running says its build at the next cursor it is given, and one from before
    /// cursor arrivals only in the first press's greeting.
    case running(pid: Int32, build: Said)
    /// Running, and of another build, so no words go to it.
    case otherBuild(pid: Int32, BuildMismatch)
    case ended(pid: Int32)
    /// Ending, or ended, by its own hand, holding more memory than its ceiling.
    case overMemoryCeiling(pid: Int32, Overrun)
    case notOpened(String)

    public enum Said: Equatable, Sendable {
        case sameBuild
        case notYetSaid
    }

    public var description: String {
        switch self {
        case let .running(pid, .sameBuild): "process \(pid) running, of this app's build"
        case let .running(pid, .notYetSaid): "process \(pid) running, its build not yet said"
        case let .otherBuild(pid, mismatch): "process \(pid) running, \(mismatch.facts)"
        case let .ended(pid): "process \(pid) ended"
        case let .overMemoryCeiling(pid, overrun): "process \(pid) ending itself, \(overrun)"
        case let .notOpened(reason): "not opened: \(reason)"
        }
    }
}
