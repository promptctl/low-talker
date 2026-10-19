import AppKit
import Identity

/// The input method's process kept running for as long as the app hears its hotkey through
/// it: opened through LaunchServices, watched until it ends, and opened again.
///
/// Measured on studious, 2026-10-18: an input method that crashes stays gone. Nothing
/// relaunches it - not the app in front, not a switch to another app - and every chord
/// goes unheard while the menu still says how to press it. Opened again through
/// LaunchServices without taking the front, it is handed keys at once by the app that was
/// in front, with no change of focus; the first chord after loses its key-down.
///
/// [LAW:dataflow-not-control-flow] Every turn of the watch is the same steps: wait out the
/// throttle, open, tell, wait for the end, tell. Opening an input method that is already
/// running answers that process, so a process macOS launched and one this launched are
/// watched the same way.
@MainActor
public final class InputMethodSupervisor {
    /// The least time between two opens: launchd's default ThrottleInterval, which bounds a
    /// process that ends as soon as it starts to six launches a minute here too.
    public static let throttleInterval: Duration = .seconds(10)

    /// What happened to the input method's process, told as it happens.
    public enum Event: Equatable, Sendable, CustomStringConvertible {
        /// The `opening`th open since the watch began answered this process.
        case running(pid: Int32, opening: Int)
        /// The process ended, launched at `launched` where LaunchServices said when.
        case ended(pid: Int32, launched: Date?)
        /// The `opening`th open failed, for this reason.
        case notOpened(String, opening: Int)

        public var description: String {
            switch self {
            case let .running(pid, opening): "process \(pid) running, open \(opening)"
            case let .ended(pid, launched): "process \(pid) ended, launched \(launched.map { "\($0)" } ?? "at a time LaunchServices did not say")"
            case let .notOpened(reason, opening): "open \(opening) failed: \(reason)"
            }
        }
    }

    /// Where events go until `stop`, after which nothing is told: a watch stopped while an
    /// open or an end was on its way says nothing about a loop that is gone.
    private var told: (@MainActor (Event) -> Void)?
    private var watching: Task<Void, Never>?

    /// Starts watching at once, opening with `open` and telling each event to `told`.
    public init(
        throttleInterval: Duration = InputMethodSupervisor.throttleInterval,
        open: @escaping @MainActor () async throws -> InputMethodProcess = { try await .open(InstalledInputMethod().bundle()) },
        told: @escaping @MainActor (Event) -> Void
    ) {
        self.told = told
        watching = Task { [weak self] in
            var nextOpen = ContinuousClock.now
            for opening in 1... {
                // Cancelled is the only way the sleep throws, and it ends the watch.
                do { try await Task.sleep(until: nextOpen) } catch { return }
                nextOpen = .now.advanced(by: throttleInterval)
                do {
                    let process = try await open()
                    self?.tell(.running(pid: process.pid, opening: opening))
                    await process.ended()
                    self?.tell(.ended(pid: process.pid, launched: process.launched))
                } catch {
                    self?.tell(.notOpened("\(error)", opening: opening))
                }
            }
        }
    }

    private func tell(_ event: Event) { told?(event) }

    /// Stops watching. The process is left running: it is what every app in front talks to,
    /// and a loop rebuilt straight after hears through it again.
    public func stop() {
        told = nil
        watching?.cancel()
    }

    // Released without a stop, it stops: a watch nobody holds would open the input method
    // forever. Only main-actor code holds this class, so its last release is there.
    deinit { MainActor.assumeIsolated { watching?.cancel() } }
}

/// One process of the input method, as LaunchServices answered for it.
public struct InputMethodProcess {
    public let pid: Int32
    public let launched: Date?
    /// Returns once the process has ended, or the task awaiting it is cancelled.
    public let ended: @MainActor () async -> Void

    public init(pid: Int32, launched: Date?, ended: @escaping @MainActor () async -> Void) {
        self.pid = pid
        self.launched = launched
        self.ended = ended
    }

    /// The input method at `bundle`: the process already running, or one launched now.
    ///
    /// Without taking the front, which is the person's, and without a line in Recent Items,
    /// since the person opened nothing. Its end is read off `isTerminated`: measured on
    /// studious, NSWorkspace posts neither its launch nor its end for an input method, which
    /// runs as a UIElement, while `isTerminated` changes the moment it dies.
    @MainActor
    public static func open(_ bundle: URL) async throws -> InputMethodProcess {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        return InputMethodProcess(pid: app.processIdentifier, launched: app.launchDate) {
            let (ending, end) = AsyncStream<Never>.makeStream()
            // `.initial`, so a process that ended before the observation began is seen ending.
            // Sendable, so it is isolated to no actor: written here it would otherwise be the
            // main actor's, and trap if KVO tells the change on another thread.
            let observation = app.observe(\.isTerminated, options: [.initial]) { @Sendable app, _ in
                if app.isTerminated { end.finish() }
            }
            // Ends when the stream finishes or the task is cancelled, whichever is first.
            for await _ in ending {}
            observation.invalidate()
        }
    }
}
