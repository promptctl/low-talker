import Darwin
import DarwinCalls
import Foundation

/// A port was not published under its name.
public enum PortNotHosted: Error, CustomStringConvertible {
    /// Someone is already answering on this name: another copy of the process that hosts it,
    /// or another port in this one.
    case nameIsTaken(String)
    case notRegistered(String, kern_return_t)
    case noPort(kern_return_t)
    case noRequirement(PeerIdentity.Unreadable)

    public var description: String {
        switch self {
        case .nameIsTaken(let name): "no port could be hosted on \(name); something is already answering there"
        case .notRegistered(let name, let status): "no port could be hosted on \(name): bootstrap status \(status)"
        case .noPort(let status): "no Mach port could be allocated: \(Mach.describe(status))"
        case .noRequirement(let failure): "nobody could be admitted to the port, because this process cannot say who signed it: \(failure)"
        }
    }
}

/// A Mach port published under a name, handing every message that arrives to one closure on
/// one queue: what both directions of the channel host, the insert port in the input method
/// and the hotkey port in the app. [LAW:one-type-per-behavior] What each does with a message
/// - answer it, or read it and answer nothing - is its closure's, and the closure owns the
/// message's reply right either way.
///
/// Held for the life of whoever hosts it. Released, the port closes and the name is
/// withdrawn once the queue is out of any message it was handling. `close()` does the same
/// and returns only when the name is free, for a host that hosts the name again at once -
/// the app does that each time it rebuilds its hotkey. [LAW:no-ambient-temporal-coupling]
final class NamedPort: Sendable {
    private let source: DispatchSourceMachReceive
    private let queue: DispatchQueue
    /// Signalled once the receive right is gone, which is what withdraws the name.
    private let withdrawn = DispatchSemaphore(value: 0)

    /// The receive right, owned by the cancel handler alone so that it goes exactly when
    /// that handler says, and not whenever dispatch lets go of a block that captured it.
    private final class Holding {
        var right: ReceiveRight?
        init(_ right: ReceiveRight) { self.right = right }
    }

    init(
        name: String, queue: DispatchQueue,
        received: @escaping @Sendable (Mach.Received) -> Void, failed: @escaping @Sendable (kern_return_t) -> Void
    ) throws(PortNotHosted) {
        let right: ReceiveRight
        do throws(ReceiveRight.NotAllocated) { right = try ReceiveRight(sendable: true) } catch { throw .noPort(error.status) }
        let registered = lt_bootstrap_register(name, right.port)
        guard registered == KERN_SUCCESS else {
            throw registered == BOOTSTRAP_NAME_IN_USE ? .nameIsTaken(name) : .notRegistered(name, registered)
        }
        let port = right.port
        self.queue = queue
        source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        // Every message waiting is taken each time the source fires, so a burst is not left
        // queued behind an event that has already been handled.
        source.setEventHandler {
            while true {
                switch Mach.receive(on: port, timeout: Duration.zero) {
                case .received(let message):
                    received(message)
                case .failed(MACH_RCV_TIMED_OUT):
                    return
                case .failed(let status):
                    failed(status)
                    return
                }
            }
        }
        // The right goes with the source, after the last handler has returned: the name is
        // withdrawn by the same step that stops anything answering on it.
        let holding = Holding(right)
        source.setCancelHandler { [withdrawn] in
            holding.right = nil
            withdrawn.signal()
        }
        source.activate()
    }

    /// Closes the port and returns once its name is free to host again. It waits for the
    /// queue to finish any message it is handling, so it is never called on that queue,
    /// which would be waiting on itself, nor while the queue is suspended.
    func close() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        source.cancel()
        withdrawn.wait()
    }

    deinit { source.cancel() }
}
