import Foundation
import Insertion
import LowTalkerCore
import os

/// How the app answers the input method about a Return it is holding.
///
/// The first question, whether anything is owed, is answered from the port's own queue off the
/// loop's queue fact (`Dictation.owes`), so a main actor busy with a come-up never delays it. The
/// second is taken to the main actor, where a latched press is ended at the moment the Return was
/// typed and the loop's tail is waited out, and it is answered when it is known: the port's queue
/// is not held for it. [LAW:no-ambient-temporal-coupling]
///
/// [LAW:single-enforcer] The press is ended here and nowhere else a typed key can end one, through
/// the hotkey, which is the one thing that ends presses.
public struct ReturnSteering: Sendable {
    private let dictation: Dictation
    private let hotkey: Hotkey

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "hotkey")

    public init(dictation: Dictation, hotkey: Hotkey) {
        self.dictation = dictation
        self.hotkey = hotkey
    }

    /// Answers `question` through `reply`, now or when it is known.
    public func answer(_ question: Question, through reply: some Answering) {
        switch question {
        case .returnTyped:
            let owing: Owing = dictation.owes ? .words : .nothing
            Self.report(reply.send(owing), "whether words were owed (\(owing))")
        case .settled(let moment):
            let (dictation, hotkey) = (dictation, hotkey)
            Task { @MainActor in
                let steered = hotkey.steer(at: HostTime(seconds: moment))
                let settlement = await dictation.settled(after: steered)
                Self.report(reply.send(settlement), "whether the words landed (\(settlement)), after \(steered)")
            }
        }
    }

    /// [LAW:no-silent-failure] An answer the kernel would not take is said, so a Return the input
    /// method then kept at its ceiling has the app's side of the story in the log beside it.
    private static func report(_ delivery: Reply.Delivery, _ answered: String) {
        switch delivery {
        case .delivered: log.debug("answered the input method \(answered, privacy: .public)")
        case .failed(let status): log.error("the answer \(answered, privacy: .public) could not be delivered: status \(status)")
        }
    }
}
