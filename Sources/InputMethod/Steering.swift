import Foundation
import Insertion

/// What a steering key's verdict asks for beyond the verdict itself: a kept Return is heard, and
/// a kept Escape is told to the app, which cancels the open press with it. A key that passes asks
/// for nothing. [LAW:effects-at-boundaries] The decision says it; `Steering` does it.
public nonisolated enum SteeringEffect: Equatable, Sendable {
    /// The system's own answer to a key that did nothing, so a kept Return is heard at the
    /// moment it was typed and not only found in a log. [LAW:no-silent-failure]
    case beep
    /// The app cancels the open press when told, and is told only of an Escape that is kept.
    /// [LAW:single-enforcer]
    case tellTheApp

    /// What `key` asks for when the gate's verdict on it is `verdict`.
    public init?(of key: SteeringKey, _ verdict: SteeringVerdict) {
        switch (key, verdict) {
        case (_, .pass): return nil
        case (.return, .keep): self = .beep
        case (.escape, .keep): self = .tellTheApp
        }
    }
}

/// What a controller decides its steering keys with: the gate that asks the app, the notices a
/// kept Escape is told through, and the beep a kept Return is heard by.
///
/// [LAW:no-shared-mutable-globals] One per `InputMethodProcess`, which makes it of its own notices.
public nonisolated struct Steering: Sendable {
    public let gate: SteeringGate
    let notices: Notices
    let beep: @MainActor @Sendable () -> Void

    /// The gate's decision of `key`, typed at `typedAt` (system uptime), with what it asks for done.
    @MainActor
    func decide(_ key: SteeringKey, typedAt timestamp: TimeInterval) -> SteeringDecision {
        let decided = switch key {
        case .return: gate.verdict(at: timestamp)
        case .escape: gate.escapeVerdict(at: timestamp)
        }
        switch SteeringEffect(of: key, decided.verdict) {
        case .beep: beep()
        case .tellTheApp: notices.keyTyped(.escape)
        case nil: break
        }
        return decided
    }
}
