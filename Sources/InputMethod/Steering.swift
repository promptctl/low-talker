import Foundation
import Insertion

/// What a controller decides its steering keys with: the gate that asks the app, and the beep a
/// kept Return is heard by.
///
/// [LAW:no-shared-mutable-globals] One per `InputMethodProcess`.
public nonisolated struct Steering: Sendable {
    public let gate: SteeringGate
    let beep: @MainActor @Sendable () -> Void

    /// The gate's decision of `key`, typed at `typedAt` (system uptime). A kept Return beeps, the
    /// system's own answer to a key that did nothing, so it is heard at the moment it was typed and
    /// not only found in a log. [LAW:no-silent-failure] A kept Escape already did what it was kept
    /// for: the app put its word box away with it before answering.
    @MainActor
    func decide(_ key: SteeringKey, typedAt timestamp: TimeInterval) -> SteeringDecision {
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
