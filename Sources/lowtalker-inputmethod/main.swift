import AppKit
import Carbon
import Identity
import InputMethod
import InputMethodKit
import Insertion
import os

/// The input method process: macOS launches it out of its own bundle, it answers on its
/// connection, and it holds nothing else.
///
/// [LAW:effects-at-boundaries] Everything with an effect is here - reading the bundle,
/// opening the port, running the loop - so the controller beside it stays a pure answer to
/// a key.
///
/// Said where `log show` will find it, because LaunchServices launches this process with
/// nowhere for standard error to go, so its only voice is the unified log. Public on purpose - a redacted reason is no reason, and
/// measured, NSLog arrives there as `<private>` and says nothing at all.
///
///     log show --last 10m --predicate 'subsystem BEGINSWITH "ai.promptctl.low-talker"'

private let logger = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "inputmethod")

/// This process's build, read off its bundle before anything else here runs, so it is the
/// build that was launched and not one an install has since put on disk. Said to the app in
/// every greeting and every arrival, which is how the app sends words only to its own build.
///
/// A bundle that carries none says none, and the app holds every word and says why; keys still
/// pass through. The build refuses to make such a bundle, so the fault says it was not built
/// here. [LAW:no-silent-failure]
let build: Build? = {
    let build = Build(of: .main)
    if build == nil {
        logger.fault("this bundle carries no build number or source revision, so the app will send it no words; it was not built by `make app`")
    }
    return build
}()

/// The server owns the port macOS reaches this process on. Held for the life of the process
/// by being a top-level binding: released, the connection goes with it and the text input
/// system's calls land nowhere.
///
/// An input method that cannot open its port is one the Input menu still offers and that
/// does nothing when chosen, so it ends here rather than running on as a source that
/// silently never answers. [LAW:no-silent-failure]
let server: IMKServer = {
    guard let server = IMKServer(name: AppIdentity.inputMethodConnectionName, bundleIdentifier: AppIdentity.inputMethodBundleIdentifier) else {
        logger.fault("will not start: no server could be opened on \(AppIdentity.inputMethodConnectionName, privacy: .public)")
        exit(1)
    }
    return server
}()

/// The app holding Secure Event Input, by name, or nil when nobody holds it.
///
/// Read from the window server's session, which names the holder's process rather than only
/// saying that someone holds it - the name is what the log line needs, since the fix is in
/// that app's own menu. A holder whose process has no name is still a holder, and is named
/// by its pid rather than read as none. [LAW:no-silent-failure]
func secureInputHolder() -> String? {
    // A session that cannot be read says nothing about secure input, which is not the same
    // as saying nobody holds it: said by name, and the insert goes ahead, since the client's
    // own answer is still the account of whether the words landed. [LAW:no-silent-failure]
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        logger.error("the window server's session could not be read, so whether an app holds secure keyboard entry is unknown")
        return nil
    }
    guard let pid = session["kCGSSessionSecureInputPID"] as? pid_t, pid != 0 else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
}

/// Whether this input method's source is the one in use, read from the text input system.
/// No current source, or one that names no identifier, is not this one.
func isTheSelectedSource() -> Bool {
    let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    let identifier = current.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
        .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    return identifier == AppIdentity.inputSourceIdentifier
}

/// Where the insert port's words are committed: on the main actor, each insert waited on for
/// a bounded time. Each insert's turn there is said in the log once it has run, so a commit
/// that outlasted its answer is still accounted for. Held for the life of the process like
/// everything else opened here.
let committer = Committer { ended in logger.notice("\(ended.description, privacy: .public)") }

/// The app's door, beside the text input system's. Held for the life of the process for
/// the same reason the server is: released, the app's next request finds nothing listening.
///
/// Answered on a queue of its own and never on the main one, which is where `FocusedClient`
/// and every `IMKInputController` callback run. Each insert is one turn on the main actor,
/// where the cursor is decided and the words committed, and the port waits for it within the
/// committer's bound, so a hung app costs the person an insert answered by name and not a
/// port that never answers. [LAW:no-ambient-temporal-coupling]
///
/// Only this installation's app gets through; every other sender is refused by the port
/// before its words are read, and the refusal is logged here with what was required.
///
/// A door that will not open is not the end of this process, unlike the server above it.
/// The controller's whole promise is that every key passes through untouched, so a person
/// with this source selected keeps a working keyboard even when nothing here can insert.
/// The fault names the `PortNotHosted` case that stopped it - most often the name
/// already held by another instance of this input method, whose own cursor then answers the
/// app. [LAW:no-silent-failure]
let insertions: InsertionPort? = {
    do {
        return try InsertionPort(build: build, queue: DispatchQueue(label: AppIdentity.inputMethodPortName), told: { event in
            logger.error("\(String(describing: event), privacy: .public)")
        }) { request in
            // Read on the main actor, where the effects are, and handed to the decision as
            // values. [LAW:effects-at-boundaries]
            let placed = committer.insert(request) {
                FocusedClient.shared.inFront(for: request.destination,
                                             whileInFrontIs: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                             secureInputHeldBy: secureInputHolder(),
                                             selected: isTheSelectedSource(),
                                             screens: NSScreen.screens.map(\.frame))
            }
            logger.notice("\(placed.description, privacy: .public)")
            return placed.answer
        }
    } catch {
        logger.fault("""
            no insert port on \(AppIdentity.inputMethodPortName, privacy: .public): \
            \(String(describing: error), privacy: .public); keys still pass through
            """)
        return nil
    }
}()

/// Every cursor that arrives, told to this installation's app. Off the main thread, and
/// waiting on nothing: an arrival the app did not take costs only the wait for the next.
///
/// Said in the log when how the telling fares changes, and not on every arrival: the app not
/// listening is the ordinary state of an app that is not running. [LAW:no-silent-failure]
let tellingTheApp = Task.detached {
    let sender = NoticeSender(build: build)
    var fared: NoticeSender.Told?
    for await _ in Notices.shared.arrivals {
        let told = sender.tellCursorArrived()
        if told != fared { logger.log(level: told.isFault ? .error : .default, "\(told.description, privacy: .public)") }
        fared = told
    }
}

/// A cursor outlives its app unless someone says otherwise, and the text input system does
/// not always say. This is where the workspace is watched for it. [LAW:effects-at-boundaries]
/// Held for the life of the process, like everything else opened here.
let quits = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { note in
    let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    MainActor.assumeIsolated { quit.map(FocusedClient.shared.applicationQuit) }
}

// What this process opened, rather than what it set out to open: the startup line is where
// a reader looks first, and one that named the insert port whether or not it exists would
// send them looking for a fault that is already in the log above. [LAW:no-silent-failure]
let inserts = insertions.map { _ in "answering inserts on \(AppIdentity.inputMethodPortName)" } ?? "answering no inserts"
logger.notice("""
    serving \(AppIdentity.inputMethodConnectionName, privacy: .public), \
    \(inserts, privacy: .public), as \(build.map(\.description) ?? "no build", privacy: .public)
    """)
NSApplication.shared.run()
