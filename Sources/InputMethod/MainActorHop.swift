import Foundation

/// How an IMK callback reached the main actor.
public nonisolated enum Hop: Equatable, Sendable, CustomStringConvertible {
    /// It arrived on the main thread and ran there as it was.
    case inline
    /// It arrived on another thread, which waited this long for the main thread to start it.
    case waited(Duration)

    public var description: String {
        switch self {
        case .inline: "inline, already on the main thread"
        case .waited(let waited): "from another thread, after waiting \(waited) for the main thread"
        }
    }
}

/// Runs an IMK callback's `body` on the main actor with the callback's `argument`, and hands
/// `body` how it got there, so the record the callback leaves says so.
///
/// IMK rule 3: the overrides are nonisolated, and this is their one way onto the main actor -
/// inline when IMK called on the main thread, as it does, and through `DispatchQueue.main.sync`
/// when it did not. [LAW:single-enforcer] The argument crosses unchecked because IMK's
/// signatures are older than `Sendable`. The crossing is safe because the calling thread is
/// blocked until `body` returns, so nothing else holds the argument meanwhile.
///
/// The hop is known before `body` starts, so `body` records it with the rest of what the
/// callback did, and nothing here writes to the log. [LAW:nothing-unseen]
nonisolated func onMainActor<Argument, Answer: Sendable>(_ argument: Argument, _ body: @MainActor (Argument, Hop) -> Answer) -> Answer {
    nonisolated(unsafe) let argument = argument
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body(argument, .inline) }
    }
    let asked = ContinuousClock.now
    return DispatchQueue.main.sync {
        let hop = Hop.waited(ContinuousClock.now - asked)
        return MainActor.assumeIsolated { body(argument, hop) }
    }
}
