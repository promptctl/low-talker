import Darwin

/// Which process started this one, which decides whose row in the menu bar's allow list its
/// status item is filed under.
///
/// Control Center files a status item under its process's responsible process, and shows or
/// hides it with that process's row in System Settings > Menu Bar. A process launchd starts,
/// which is every launch through LaunchServices (`open`, Finder, a login item), is its own
/// responsible process and gets a row of its own. A process another one starts directly, a
/// shell running the executable, inherits that process's responsible app: from a terminal,
/// the terminal, so the icon is filed under the terminal's row and hidden while that row is
/// off. Measured on macOS 26.5 (u2, 2026-10-18), with apps that started a probe's executable
/// and opened it.
public enum LaunchOrigin: Equatable, Sendable, CustomStringConvertible {
    case launchd
    /// Started by this process, whose executable is at `path`, or nil when it could not be read.
    case directly(by: pid_t, path: String?)

    public static func ofThisProcess() -> LaunchOrigin { LaunchOrigin(parent: getppid()) }

    init(parent: pid_t) {
        guard parent != 1 else {
            self = .launchd
            return
        }
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(parent, &path, UInt32(path.count))
        self = .directly(by: parent, path: length > 0 ? String(decoding: path.prefix(Int(length)), as: UTF8.self) : nil)
    }

    public var description: String {
        switch self {
        case .launchd: "started by launchd"
        case .directly(let pid, let path?): "started directly by \(path) (pid \(pid))"
        case .directly(let pid, nil): "started directly by pid \(pid), whose executable could not be read"
        }
    }
}
