import Darwin
import Identity

/// What came of asking LaunchServices to start the app in place of a process another process
/// is responsible for: the status that process exits with, and the line saying why.
public struct Handoff: Equatable, Sendable {
    /// 0 once the app LaunchServices started is running, 1 when it could not be started.
    public let status: Int32
    public let said: String

    /// - Parameters:
    ///   - started: the pid LaunchServices started the app as, or nil when it did not.
    ///   - error: what LaunchServices said went wrong, or nil when it said nothing.
    public init(of responsible: ResponsibleProcess, started: pid_t?, error: String?) {
        let name = AppIdentity.displayName
        (status, said) = switch (started, error) {
        case (let pid?, _): (0, "\(responsible), so macOS would file the menu bar icon under it; LaunchServices started \(name) as pid \(pid) instead")
        case (nil, let error?): (1, "\(responsible), and LaunchServices could not start \(name) in its place: \(error)")
        case (nil, nil): (1, "\(responsible), and LaunchServices answered neither an app nor an error when asked to start \(name) in its place")
        }
    }
}
