import Identity
import Insertion
import os

/// What one unit of a controller's work did: its making, its ending, or one IMK callback.
///
/// The input method cannot be debugged (IMK rule 6), so this is what its running process is read
/// from. A test reads it as a value from the controller's `records`; the unified log receives its
/// `rendering`, written at one edge. [LAW:nothing-unseen]
public nonisolated struct ControllerRecord: Equatable, Sendable {
    /// The controller's address, which the allocator hands to a later controller once this one
    /// has ended: read in order, "made" minus "ended" at one address is still how many are live.
    public let controller: UInt
    public let event: Event

    public enum Event: Equatable, Sendable {
        case made
        case ended
        /// A callback, how it reached the main actor, and what it decided there.
        case callback(Hop, Decision)
    }

    /// What one callback decided. Each case is one callback's outcome, so every callback ends in
    /// exactly one of them, a callback that decided nothing included. Each says the client the
    /// controller holds as `FocusedClient` spells it.
    public enum Decision: Equatable, Sendable {
        /// `handle` with a key: the gate's decision when it was a steering key; any other key is
        /// declined. Which key it was is never recorded, as it names what was typed.
        case key(steered: Steered?, holding: String)
        /// `handle` with no event, as IMK calls it after an activate, declined.
        case handedNoEvent(holding: String)
        /// `handle` with an event that is no key-down, which `recognizedEvents` asks for none of,
        /// declined.
        case handedNoKey(holding: String)
        /// `activateServer` with a client a cursor was made of, which `holding` names.
        case activated(holding: String)
        /// `activateServer` with no client, or one that would not name its app.
        case activatedWithoutUsableClient(holding: String)
        /// `activateServer` past the memory ceiling (IMK rule 7), which takes no client.
        case overMemoryCeiling(Overrun)
        /// `deactivateServer`.
        case deactivated(holding: String)
    }

    /// A steering key and what the gate decided of it.
    public struct Steered: Equatable, Sendable {
        public let key: SteeringKey
        public let decision: SteeringDecision
    }

    /// What the unified log receives for this record.
    ///
    /// Everything said is public, because a redacted line is no line, and no record holds a
    /// character anyone typed. A key's record is made for every key typed anywhere, so
    /// it is said at debug, which the log does not keep by default: the log is not a record of
    /// when a person typed. A steering key the gate kept or waited on is the exception, said at
    /// the default level, because a Return that did nothing is what a person asks the log about.
    public var rendering: (level: OSLogType, line: String) {
        switch event {
        case .made: (.default, controllerLine(controller: controller, "was made"))
        case .ended: (.default, controllerLine(controller: controller, "ended"))
        case let .callback(hop, decision):
            (decision.isRoutineKey ? .debug : .default, "\(decision.line(controller: controller)); reached the main actor \(hop)")
        }
    }
}

nonisolated extension ControllerRecord.Decision {
    /// A key typed anywhere that nothing held: nearly every key.
    var isRoutineKey: Bool {
        switch self {
        case let .key(steered, _): steered?.decision.routine ?? true
        case .handedNoEvent: true
        // [LAW:nothing-unseen] An event nothing asked for is said where the log keeps it.
        case .handedNoKey: false
        case .activated, .activatedWithoutUsableClient, .overMemoryCeiling, .deactivated: false
        }
    }

    func line(controller: UInt) -> String {
        switch self {
        case let .key(steered, holding):
            controllerLine(controller: controller, "was handed "
                + (steered.map { "a steering key, \($0.key), that \($0.decision)" } ?? "a key, not a steering key"), client: holding)
        case let .handedNoEvent(holding):
            controllerLine(controller: controller, "was handed no event", client: holding)
        case let .handedNoKey(holding):
            controllerLine(controller: controller, "was handed an event that is no key-down", client: holding)
        case let .activated(holding):
            controllerLine(controller: controller, "activated", client: holding)
        case let .activatedWithoutUsableClient(holding):
            controllerLine(controller: controller, "activated without a usable client", client: holding)
        case let .overMemoryCeiling(overrun):
            controllerLine(controller: controller, "activated over the memory ceiling and took no client: \(overrun)")
        case let .deactivated(holding):
            controllerLine(controller: controller, "deactivated", client: holding)
        }
    }
}

/// A line about one controller: which it is, what happened to it, and what it says of its
/// client, when there is something to say. Nothing is decided from any of it.
nonisolated func controllerLine(controller: UInt, _ event: String, client: String? = nil) -> String {
    "controller 0x\(String(controller, radix: 16)) \(event)" + (client.map { ", \($0)" } ?? "")
}

/// The `imk` channel, which receives every controller record and nothing else.
private nonisolated let imkLog = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "imk")

nonisolated extension ControllerRecord {
    /// The one edge where a record reaches the unified log, where `log show` reads the running
    /// process. [LAW:single-enforcer]
    func log() {
        let (level, line) = rendering
        imkLog.log(level: level, "\(line, privacy: .public)")
    }
}
