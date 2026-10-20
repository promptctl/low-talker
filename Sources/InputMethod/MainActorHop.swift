import Foundation
import Identity
import os

/// How an IMK callback reached the main actor.
nonisolated enum Hop: Sendable, CustomStringConvertible {
    /// It arrived on the main thread and ran there as it was.
    case inline
    /// It arrived on another thread, which waited this long for the main thread to start it.
    case waited(Duration)

    var description: String {
        switch self {
        case .inline: "inline, already on the main thread"
        case .waited(let waited): "from another thread, after waiting \(waited) for the main thread"
        }
    }
}

private nonisolated let log = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "imk")

/// Runs an IMK callback's `body` on the main actor with the callback's `argument`, and says how
/// it got there.
///
/// IMK rule 3: the overrides are nonisolated, and this is their one way onto the main actor -
/// inline when IMK called on the main thread, as it does, and through `DispatchQueue.main.sync`
/// when it did not. [LAW:single-enforcer] The argument crosses unchecked because IMK's
/// signatures are older than `Sendable`. The crossing is safe because the calling thread is
/// blocked until `body` returns, so nothing else holds the argument meanwhile.
nonisolated func onMainActor<Argument>(_ callback: StaticString, _ argument: Argument,
                                       _ body: @MainActor (Argument) -> Void) {
    nonisolated(unsafe) let argument = argument
    let hop: Hop
    if Thread.isMainThread {
        MainActor.assumeIsolated { body(argument) }
        hop = .inline
    } else {
        let asked = ContinuousClock.now
        hop = DispatchQueue.main.sync {
            let started = Hop.waited(ContinuousClock.now - asked)
            MainActor.assumeIsolated { body(argument) }
            return started
        }
    }
    // [LAW:nothing-unseen] Which way every callback came, at the level `log show` keeps.
    log.notice("\(callback, privacy: .public) reached the main actor \(hop.description, privacy: .public)")
}
