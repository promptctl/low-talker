import Insertion

/// What the app knows of its input method: the supervisor's latest word on the process, and
/// the latest cursor arrival, which says the build of the process that told it.
///
/// [LAW:one-source-of-truth] Both are folded here and the standing is read off them, so the
/// supervisor and the arrivals never each write a status of their own. A build counts only for
/// the process that said it: a loop rebuilt makes a new supervisor, whose first word is the
/// same running process again, and that process is still of the build it said.
public struct InputMethodWatch: Sendable {
    private let app: Build
    private var process: InputMethodSupervisor.Event?
    private var arrival: CursorArrival?
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
        return show(Self.standing(of: event, said: arrival, by: app))
    }

    /// Kept whichever process told it, so an arrival heard before the supervisor says that
    /// process is running counts once it does. Shown only when it moved the standing, so an
    /// arrival in each app the person moves to leaves whatever else the line says, a
    /// microphone that would not start included.
    public mutating func arrived(_ arrival: CursorArrival) -> Showing? {
        self.arrival = arrival
        guard let standing, standing != shown else { return nil }
        return show(standing)
    }

    /// Where the input method stands, or nil while the supervisor has said nothing.
    public var standing: InputMethodStanding? {
        process.map { Self.standing(of: $0, said: arrival, by: app) }
    }

    private mutating func show(_ standing: InputMethodStanding) -> Showing {
        defer { shown = standing }
        return Showing(standing: standing, isNew: standing != shown)
    }

    private static func standing(of process: InputMethodSupervisor.Event, said arrival: CursorArrival?, by app: Build) -> InputMethodStanding {
        switch process {
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
    /// and the inserter refuses there. A process the supervisor launched is given the client
    /// in front at once (`InputMethodSupervisor`), so its first arrival follows straight away.
    /// One already running says its build at the next cursor it is given, and one from before
    /// cursor arrivals only in the first press's greeting.
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
