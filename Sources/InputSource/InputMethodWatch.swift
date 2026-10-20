import Insertion

/// What the app knows of its input method: the supervisor's latest word on the process, and
/// the latest cursor arrival, which says the build of the process that told it.
///
/// [LAW:one-source-of-truth] Both are folded here and the standing is read off them, so the
/// supervisor and the arrivals never each write a status of their own. A build counts only for
/// the process that said it: a loop rebuilt makes a new supervisor, whose first word is the
/// same running process again, and that process is still of the build it said.
public struct InputMethodWatch: Sendable {
    private var process: InputMethodSupervisor.Event?
    private var arrival: CursorArrival?

    public init() {}

    public mutating func told(_ event: InputMethodSupervisor.Event) { process = event }

    /// Kept whichever process told it, so an arrival heard before the supervisor says that
    /// process is running counts once it does.
    public mutating func arrived(_ arrival: CursorArrival) { self.arrival = arrival }

    /// Where the input method stands for an app of `app`, or nil while the supervisor has said
    /// nothing.
    public func standing(for app: Build) -> InputMethodStanding? {
        switch process {
        case nil: return nil
        case .running(let pid, _):
            guard let arrival, arrival.pid == pid else { return .running(pid: pid, build: .notYetSaid) }
            return BuildMismatch(app: app, inputMethod: arrival.build).map { .otherBuild(pid: pid, $0) }
                ?? .running(pid: pid, build: .sameBuild)
        case .ended(let pid, _): return .ended(pid: pid)
        case .notOpened(let reason, _): return .notOpened(reason)
        }
    }
}

/// Where the input method stands for the app.
public enum InputMethodStanding: Equatable, Sendable, CustomStringConvertible {
    /// Running, and words may go to it: its build is the app's, or it has not said its build
    /// yet. Not yet said is not refused here. Its greeting says the build before any words go,
    /// and the inserter refuses there. And a process the supervisor opens is handed the cursor
    /// in front at once (`InputMethodSupervisor`), so its first arrival follows straight away.
    case running(pid: Int32, build: Said)
    /// Running, and of another build, so no words go to it.
    case otherBuild(pid: Int32, BuildMismatch)
    case ended(pid: Int32)
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
        case let .notOpened(reason): "not opened: \(reason)"
        }
    }
}
