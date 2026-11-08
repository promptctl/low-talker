import Foundation
import Insertion
import LowTalkerCore
import os

/// How the app answers the input method about a Return or an Escape it is holding.
///
/// The first question, whether anything is owed, is answered from the port's own queue off the
/// loop's queue fact (`Dictation.owes`), so a main actor busy with a come-up never delays it, and
/// it is the question a Return asks first. The second is taken to the main actor and answered
/// when it is known: the port's queue is not held for it. For a Return, a latched press is ended
/// at the moment the Return was typed and the loop's tail is waited out. The effect is in the
/// second question and never the first, so no bound the input method puts on an answer can be
/// raced by it. [LAW:no-ambient-temporal-coupling]
///
/// [LAW:single-enforcer] The press is ended here and nowhere else a typed key can end one, through
/// the hotkey, which is the one thing that ends presses. An Escape is `escape()`, not a question:
/// the input method keeps it while the panel is shown, and the app cancels the press when told.
public struct KeySteering: Sendable {
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
        case .owed:
            let owing: Owing = dictation.owes ? .words : .nothing
            Self.report(reply.send(owing), "whether words were owed (\(owing))")
        case .settled(let moment):
            let (dictation, hotkey) = (dictation, hotkey)
            Task { @MainActor in
                let steered = hotkey.steer(.send(at: HostTime(seconds: moment)))
                let settlement = await dictation.settled(after: steered)
                Self.report(reply.send(settlement), "whether the words landed (\(settlement)), after \(steered)")
            }
        }
    }

    /// Escape, typed while the panel is shown: the press that is open, held or latched, is
    /// cancelled, and its words not yet at a cursor are taken back by the press's own path. Nothing
    /// is cancelled when no press is open, and the outcome is in that press's own report.
    /// [LAW:single-enforcer] The detector ends the press, as it ends every press.
    @MainActor public func escape() {
        let steered = hotkey.steer(.cancel)
        Self.log.debug("escape: \(String(describing: steered), privacy: .public)")
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
