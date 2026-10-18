import AppKit
import Identity
import MenuBarPresence
import os

// `LowTalker --bench …` is the bench from a terminal, and branches off before anything the
// menu-bar app sets up. [LAW:one-type-per-behavior] One binary, so the bench reads the
// bookmarks and the carried store the app does, under the app's own sandbox and signature.
if CommandLine.arguments.dropFirst().first == "--bench" {
    BenchTerminal.run(Array(CommandLine.arguments.dropFirst(2)))
}

// A menu-bar app another process is responsible for is filed under that process's row in the
// menu bar's allow list, a terminal's when a shell ran it, and its icon is hidden whenever
// that row is off (see ResponsibleProcess). So such a start is handed to LaunchServices, and
// this process leaves before it makes anything. The instance LaunchServices starts is
// responsible for itself, so it is never handed on again. Where macOS does not say which
// process is responsible, the app runs as it is, and the menu bar check in AppDelegate says
// when its icon never showed.
// [LAW:single-enforcer] Every way the app comes up passes here.
let responsible = ResponsibleProcess.ofThisProcess()
let launchLog = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "launch")
switch responsible {
case .this: launchLog.notice("launch: \(responsible, privacy: .public)")
case .other: handToLaunchServices(responsible, log: launchLog)
case .unknown: launchLog.error("launch: \(responsible, privacy: .public)")
}

/// Starts this bundle again through LaunchServices, with the arguments and environment this
/// process was given, and exits: 0 once it is running, 1 with what went wrong on stderr when
/// it could not be started. Such a start is never left to run as it is. [LAW:no-silent-failure]
func handToLaunchServices(_ responsible: ResponsibleProcess, log launchLog: Logger) -> Never {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = Array(CommandLine.arguments.dropFirst())
    configuration.environment = ProcessInfo.processInfo.environment
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
        let handoff = Handoff(of: responsible, started: app?.processIdentifier, error: error.map { "\($0)" })
        if handoff.status == 0 { launchLog.notice("launch: \(handoff.said, privacy: .public)") } else { launchLog.error("launch: \(handoff.said, privacy: .public)") }
        FileHandle.standardError.write(Data("\(AppIdentity.displayName): \(handoff.said)\n".utf8))
        exit(handoff.status)
    }
    // Parked rather than awaiting: an `await` here would make all of this file's top level
    // async, the AppKit start below included. The answer exits the process.
    dispatchMain()
}

// AppKit's `@main` entry only calls NSApplicationMain, which creates the delegate
// from a nib named in Info.plist. This app has no nib, so the delegate is wired here.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
