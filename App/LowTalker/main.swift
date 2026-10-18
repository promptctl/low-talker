import AppKit
import Identity
import MenuBarPresence
import Synchronization
import os

// `LowTalker --bench …` is the bench from a terminal, and branches off before anything the
// menu-bar app sets up. [LAW:one-type-per-behavior] One binary, so the bench reads the
// bookmarks and the carried store the app does, under the app's own sandbox and signature.
if CommandLine.arguments.dropFirst().first == "--bench" {
    BenchTerminal.run(Array(CommandLine.arguments.dropFirst(2)))
}

// A menu-bar app another process started directly is filed under that process's row in the
// menu bar's allow list, a terminal's when a shell ran it, and its icon is hidden whenever
// that row is off (see LaunchOrigin). So a direct start is handed to LaunchServices, and
// this process leaves before it makes anything. The instance LaunchServices starts has
// launchd for its parent, so it is never handed on again.
// [LAW:single-enforcer] Every way the app comes up passes here.
let origin = LaunchOrigin.ofThisProcess()
let launchLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "launch")
launchLog.notice("launch: \(origin, privacy: .public)")
if case .directly = origin { handToLaunchServices(origin, log: launchLog) }

/// Starts this bundle again through LaunchServices, with the arguments this process was
/// given, and exits: 0 once it is running, 1 with what went wrong on stderr when it could not
/// be started. A direct start is never left to run as it is. [LAW:no-silent-failure]
func handToLaunchServices(_ origin: LaunchOrigin, log launchLog: Logger) -> Never {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = Array(CommandLine.arguments.dropFirst())
    let name = AppIdentity.displayName
    // What LaunchServices answered, as the exit status and the line saying it.
    let answer = Mutex<(status: Int32, said: String)?>(nil)
    let done = DispatchSemaphore(value: 0)
    // Waited on rather than awaited: an `await` here would make all of this file's top level
    // async, the AppKit start below included.
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
        let said: (Int32, String) = switch (app, error) {
        case (let app?, _): (0, "\(origin), so macOS would file the menu bar icon under that app; LaunchServices started \(name) as pid \(app.processIdentifier) instead")
        case (nil, let error?): (1, "\(origin), and LaunchServices could not start \(name) in its place: \(error)")
        case (nil, nil): (1, "\(origin), and LaunchServices answered neither an app nor an error when asked to start \(name) in its place")
        }
        answer.withLock { $0 = said }
        done.signal()
    }
    done.wait()
    let (status, said) = answer.withLock { $0 }!
    if status == 0 { launchLog.notice("launch: \(said, privacy: .public)") } else { launchLog.error("launch: \(said, privacy: .public)") }
    FileHandle.standardError.write(Data("\(name): \(said)\n".utf8))
    exit(status)
}

// AppKit's `@main` entry only calls NSApplicationMain, which creates the delegate
// from a nib named in Info.plist. This app has no nib, so the delegate is wired here.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
