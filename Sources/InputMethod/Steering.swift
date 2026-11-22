import Foundation
import Insertion

/// What a process decides its steering keys with: the gate that asks the app, the beep a kept
/// Return is heard by, and the steering key held down, whose repeats follow its press.
///
/// [LAW:no-shared-mutable-globals] One per `InputMethodProcess`. [LAW:single-enforcer] The one
/// decider of every key-down's verdict: a key repeats wherever focus has gone while it is held,
/// so the press it repeats is the process's to remember, not a controller's.
public nonisolated final class Steering: Sendable {
    public let gate: SteeringGate
    let beep: @MainActor @Sendable () -> Void
    /// The steering key last pressed and its decision, until another key goes down.
    @MainActor private var held: ControllerRecord.Steered?

    init(gate: SteeringGate, beep: @escaping @MainActor @Sendable () -> Void) {
        (self.gate, self.beep) = (gate, beep)
    }

    /// The steering key `key` is and its decision, or nil for any other key. A press is the gate's
    /// to decide, and a kept Return beeps, the system's own answer to a key that did nothing, so it
    /// is heard at the moment it was typed and not only found in a log. [LAW:no-silent-failure] A
    /// kept Escape already did what it was kept for: the app put its word box away with it before
    /// answering.
    ///
    /// A held key's repeat takes the verdict of its press, unasked and unheard: once an Escape has
    /// put the box away, its repeats would otherwise find nothing shown and reach the app, where
    /// Option+Escape's run `complete:`, and a Return kept for owed words would be asked again, and
    /// beep, at every repeat. It is said at the press's level, so a kept repeat is on the record.
    @MainActor
    func decide(_ key: KeyDown) -> ControllerRecord.Steered? {
        held = key.steering.map { steering in
            if key.repeats, let held, held.key == steering { return held.repeated }
            return ControllerRecord.Steered(key: steering, decision: pressed(steering, typedAt: key.typedAt))
        }
        return held
    }

    @MainActor
    private func pressed(_ key: SteeringKey, typedAt timestamp: TimeInterval) -> SteeringDecision {
        let decided = switch key {
        case .return: gate.verdict(at: timestamp)
        case .escape: gate.escapeVerdict(at: timestamp)
        }
        switch (key, decided.verdict) {
        case (.return, .keep): beep()
        case (.escape, .keep), (_, .pass): break
        }
        return decided
    }
}

private extension ControllerRecord.Steered {
    /// This key's repeat, which follows it.
    var repeated: ControllerRecord.Steered {
        let was = switch decision.verdict {
        case .keep: "kept"
        case .pass: "passed"
        }
        return ControllerRecord.Steered(key: key, decision: SteeringDecision(
            verdict: decision.verdict, because: "it repeats the \(key) held down, which was \(was)", routine: decision.routine))
    }
}
