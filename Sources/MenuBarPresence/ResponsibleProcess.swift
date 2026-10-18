import Darwin

/// The process macOS holds responsible for this one, under whose row in the menu bar's allow
/// list this process's status item is filed.
///
/// Control Center files a status item under its process's responsible process, and shows or
/// hides it with that process's row in System Settings > Menu Bar. A process launchd starts,
/// which is every launch through LaunchServices (`open`, Finder, a login item), is responsible
/// for itself and gets a row of its own. A process another one starts directly, a shell
/// running the executable, inherits that process's responsible app: from a terminal, the
/// terminal, so the icon is filed under the terminal's row and hidden while that row is off.
/// Measured on macOS 26.5 (u2, 2026-10-18), with apps that started a probe's executable and
/// opened it.
public enum ResponsibleProcess: Equatable, Sendable, CustomStringConvertible {
    case this
    /// Another process, whose executable is at `path`, or nil when it could not be read.
    case other(pid_t, path: String?)
    /// macOS did not say which process it is.
    case unknown

    public static func ofThisProcess() -> ResponsibleProcess {
        // Private, so looked up rather than linked: a macOS without it still launches the app.
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return .unknown }
        let responsible = unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
        return ResponsibleProcess(responsible(getpid()), this: getpid())
    }

    init(_ responsible: pid_t, this: pid_t) {
        guard responsible > 0 else {
            self = .unknown
            return
        }
        guard responsible != this else {
            self = .this
            return
        }
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(responsible, &path, UInt32(path.count))
        self = .other(responsible, path: length > 0 ? String(decoding: path.prefix(Int(length)), as: UTF8.self) : nil)
    }

    public var description: String {
        switch self {
        case .this: "responsible for itself"
        case .other(let pid, let path?): "\(path) (pid \(pid)) is responsible for it"
        case .other(let pid, nil): "pid \(pid), whose executable could not be read, is responsible for it"
        case .unknown: "which process is responsible for it could not be read"
        }
    }
}
