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
/// at the moment the Return was typed and the loop's tail is waited out. A Return's effect is in
/// the second question and never the first, so no bound the input method puts on an answer can be
/// raced by it. [LAW:no-ambient-temporal-coupling]
///
/// An Escape asks one question, taken to the main actor too, where the word box decides whether it
/// takes it and, when it does, puts itself away and cancels the press it showed through
/// `escape()`, in the same turn as it answers. [LAW:no-ambient-temporal-coupling] Nothing can
/// settle between what the box said and what was done, so a kept Escape always did something. Its
/// effect is under the input method's short bound, so an answer later than it is done though the
/// Escape passes as well (`SteeringGate`): bounding it by the ceiling instead would hold every
/// Escape typed into any app for as long as this main actor is busy.
///
/// [LAW:single-enforcer] The press is ended here and nowhere else a typed key can end one, through
/// the hotkey, which is the one thing that ends presses.
public struct KeySteering: Sendable {
    private let dictation: Dictation
    private let hotkey: Hotkey
    /// Whether a bare Return is held at all: the setting, read where the question is answered. A
    /// Return is held against a debt only while it is on, so with it off nothing is owed.
    private let holdsReturn: @Sendable () -> Bool
    /// The word box taking an Escape, on the main actor where the box is: put away, cancelling
    /// through the steering handed it, when it is shown.
    private let dismissing: @MainActor @Sendable (KeySteering) -> Dismissal

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lowtalker", category: "hotkey")

    public init(dictation: Dictation, hotkey: Hotkey, holdsReturn: @escaping @Sendable () -> Bool, dismissing: @escaping @MainActor @Sendable (KeySteering) -> Dismissal) {
        self.dictation = dictation
        self.hotkey = hotkey
        self.holdsReturn = holdsReturn
        self.dismissing = dismissing
    }

    /// Answers `question` through `reply`, now or when it is known.
    public func answer(_ question: Question, through reply: some Answering) {
        switch question {
        case .owed:
            let owing: Owing = holdsReturn() && dictation.owes ? .words : .nothing
            Self.report(reply.send(owing), "whether words were owed (\(owing))")
        case .escape:
            Task { @MainActor in
                let dismissal = dismissing(self)
                Self.report(reply.send(dismissal), "what the Escape did (\(dismissal))")
            }
        case .settled(let moment):
            let (dictation, hotkey) = (dictation, hotkey)
            Task { @MainActor in
                let steered = hotkey.steer(.send(at: HostTime(seconds: moment)))
                let settlement = await dictation.settled(after: steered)
                Self.report(reply.send(settlement), "whether the words landed (\(settlement)), after \(steered)")
            }
        }
    }

    /// The word box put away, with Escape or its circle: the dictation the box shows is cancelled,
    /// the open press, held or latched, or the presses on their way, and the words they already put
    /// at the cursor are taken back by each press's own path. The outcome is in each press's own
    /// report.
    /// [LAW:single-enforcer] One Escape throws away one dictation. The detector ends the press it
    /// holds open, as it ends every press; only with none open does the loop throw away the
    /// presses past the detector, so a chord pressed just before the Escape is the one it cancels,
    /// never that and the press before it.
    @MainActor public func escape() {
        let steered = hotkey.steer(.cancel)
        let pastTheDetector = switch steered {
        case .ended, .chordDown: 0
        case .nothingOpen: dictation.cancel()
        }
        Self.log.debug("escape: \(String(describing: steered), privacy: .public), \(pastTheDetector) presses past the detector cancelled")
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
