import AppKit
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


/// This process's build, read off its bundle before anything else here runs, so it is the
/// build that was launched and not one an install has since put on disk. Said to the app in
/// every arrival, which the app's log names, and in every greeting, which an app from before
/// builds of either end took each other's words compares with its own.
///
/// A bundle that carries none says none. The build refuses to make such a bundle, so the fault
/// says it was not built here. [LAW:no-silent-failure]
let build: Build? = {
    let build = Build(of: .main)
    if build == nil {
        processLog.fault("this bundle carries no build number or source revision, so the app cannot say which build answers it; it was not built by `make app`")
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
        processLog.fault("will not start: no server could be opened on \(AppIdentity.inputMethodConnectionName, privacy: .public)")
        exit(1)
    }
    return server
}()

/// The process's parts, assembled once (`InputMethodProcess.shipped`): the controllers `IMKServer`
/// builds take the same one, so the ports opened here and the controllers answer as one process.
let process = InputMethodProcess.shipped

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
/// The controller's whole promise is that every key passes through untouched, a Return held
/// for the app's words aside, and a Return is held only for an app that said it owes some, so a
/// person with this source selected keeps a working keyboard even when nothing here can insert.
/// The fault names the `PortNotHosted` case that stopped it - most often the name
/// already held by another instance of this input method, whose own cursor then answers the
/// app. [LAW:no-silent-failure]
///
/// Opened off the main thread while the server above already answers, since opening it
/// verifies this process's own signature. The task holds the port for the life of the
/// process.
let insertions = Task.detached { () -> InsertionPort? in
    do {
        let port = try await InsertionPort(build: build, queue: DispatchQueue(label: AppIdentity.inputMethodPortName), told: { event in
            processLog.error("\(String(describing: event), privacy: .public)")
        }) { request in
            let placed = process.insert(request)
            processLog.notice("\(placed.description, privacy: .public)")
            return placed.answer
        }
        processLog.notice("answering inserts on \(AppIdentity.inputMethodPortName, privacy: .public)")
        return port
    } catch {
        processLog.fault("""
            no insert port on \(AppIdentity.inputMethodPortName, privacy: .public): \
            \(String(describing: error), privacy: .public); keys still pass through
            """)
        return nil
    }
}

/// Every notice, told to this installation's app. Off the main thread, and waiting on
/// nothing: an arrival the app did not take costs only the wait for the next.
///
/// Told only once the insert port is open or has failed to, because an arrival is what sends
/// the app to that port with the words it holds. The stream keeps what arrives meanwhile.
/// [LAW:no-ambient-temporal-coupling]
///
/// An overrun of the memory ceiling is told before the process ends (IMK rule 7), so the app
/// can say why its input method went away; the stream's order is what puts the one before the
/// other. Ended as a failure, since nobody asked it to end, and on the main queue, so it comes
/// between two turns there and never in the middle of a commit.
let tellingTheApp = Task.detached {
    _ = await insertions.value
    let sender = NoticeSender(build: build)
    await process.notices.relay(tell: sender.tell, end: { DispatchQueue.main.async { exit(EXIT_FAILURE) } })
}

/// What a held Return asks the app, and whom it believes: this installation's app, by its
/// signature, which is read off the main thread for the reason the insert port's is. Until it is
/// read, and for good if it cannot be, nobody admits anything and every Return passes, said in
/// the log. [LAW:no-silent-failure]
let askingTheApp = Task.detached {
    let answerer: Result<PeerIdentity, PeerIdentity.Unreadable>
    do throws(PeerIdentity.Unreadable) {
        answerer = .success(try await .signedLikeThisProcess(identifier: AppIdentity.bundleIdentifier))
    } catch {
        processLog.fault("no Return will be held for the app's words: this installation's app cannot be recognised: \(String(describing: error), privacy: .public)")
        answerer = .failure(error)
    }
    process.steering.gate.connect(Asker(answerer: answerer))
}

/// A cursor outlives its app unless someone says otherwise, and the text input system does
/// not always say. This is where the workspace is watched for it. [LAW:effects-at-boundaries]
/// Held for the life of the process, like everything else opened here.
let quits = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { note in
    let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    MainActor.assumeIsolated { quit.map(process.focused.applicationQuit) }
}

// The insert port is said by the task opening it, once it is open or has failed to.
processLog.notice("""
    serving \(AppIdentity.inputMethodConnectionName, privacy: .public) \
    as \(build.map(\.description) ?? "no build", privacy: .public)
    """)
NSApplication.shared.run()
