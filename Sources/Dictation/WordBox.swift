import GrammaticalNumber
import Insertion
import LowTalkerCore

/// What the word box draws, put on screen by the app. The box decides, and the panel only lays
/// out and orders in what it was given. [LAW:effects-at-boundaries]
@MainActor
public protocol WordBoxPanel: AnyObject {
    func draw(_ face: WordBox.Face)
    func hide()
}

/// The word box: the panel near the bottom of the screen while a press is on its way, or while
/// words no cursor took are held, and the person's dismissal of it, with Escape or the circle on
/// its corner, which keeps it away until there are new words to show: a press opening after it,
/// or words held after it, whether a press's insert failed or the dismissed words were brought back.
///
/// [LAW:one-source-of-truth] It draws `Dictation.Activity` and `Held` as it is handed them, and
/// keeps only what neither says: the dismissal, and whether the press open at it has closed.
@MainActor
public final class WordBox {
    /// The box's lines and controls, as the panel draws them.
    public struct Face: Equatable, Sendable {
        /// What the press is doing, if a press is on its way.
        public let state: String?
        /// Why a press is not heard, then why words are held, oldest first, each said once a
        /// warning symbol says it is a warning; the last ends with what a click places.
        public let warnings: [String]
        /// The words being spoken, or else every word held.
        public let words: Transcript
        /// The circle, Insert and Copy, which are there only while words are held.
        public let controls: Controls?
    }

    /// Insert, while it is offered, and Copy, dimmed where it is not: the circle beside them is
    /// always offered.
    public struct Controls: Equatable, Sendable {
        public let insert: Bool
        public let copy: Bool
    }

    private let panel: any WordBoxPanel
    /// The person put the box away, so it stays away until there are new words to show.
    private var dismissed = false
    /// Whether the activity last shown had a press open, so a press opening is told from one
    /// going on. A cancelled press goes on being heard until its cancellation is delivered, and a
    /// refused one cannot be cancelled at all, and neither is a press starting.
    private var pressWasOpen = false

    public init(panel: any WordBoxPanel) {
        self.panel = panel
    }

    /// Draws `activity` over `readiness` with what is `held`, or puts the box away. `insertable`
    /// is whether a loop is listening to insert what is held through, without which Insert is not
    /// offered.
    public func show(_ activity: Dictation.Activity, over readiness: EngineReadiness, held: Held?, insertable: Bool) {
        let pressIsOpen = switch activity {
        case .listening, .refused: true
        case .idle, .transcribing: false
        }
        // A press opening is new words to show, and so is anything held: the dismissal let go of
        // what was held at it.
        if pressIsOpen && !pressWasOpen || held != nil { dismissed = false }
        pressWasOpen = pressIsOpen
        guard !dismissed, let face = Self.face(of: activity, over: readiness, held: held, insertable: insertable) else { return panel.hide() }
        panel.draw(face)
    }

    /// The person put the dictation away, with Escape or the circle: the held words no cursor has
    /// taken are let go, the open press is cancelled through `hotkey`, and the box is put away
    /// until there are new words to show. The words the press already put at the cursor are
    /// taken back by the press's own path.
    /// [LAW:single-enforcer] One dismissal, whichever way it was asked for, so the circle cannot
    /// let go of the words and leave the microphone open. `hold` is handed in because the hold
    /// shows the box from its own start, before a box built over it could be. Dismissed first,
    /// so the box the hold shows as it lets go is already put away, and let go before the press
    /// is cancelled, so no box shown for the cancel is handed the words being let go.
    public func dismiss(cancelling hotkey: Hotkey?, hold: Hold) {
        dismissed = true
        hold.dismiss()
        hotkey.map(KeySteering.escape)
        panel.hide()
    }

    /// What each steering key the input method reports does. The switch is exhaustive, so a key
    /// added to `SteeringKey` has to say what it does here before this builds.
    public func react(to key: SteeringKey, cancelling hotkey: Hotkey?, hold: Hold) {
        switch key {
        // The input method keeps an Escape only while the box is shown, so one told here is
        // the person putting it away.
        case .escape: dismiss(cancelling: hotkey, hold: hold)
        // Return is held and sent by the input method; the app has nothing to do when it passes.
        case .return: break
        }
    }

    /// What the box shows of `activity` over `readiness` with what is `held`, or nil when there
    /// is nothing to show.
    ///
    /// A press on its way carries the words a cursor is offered in its own insert, so only a box
    /// with nothing on its way asks for a click, and only for those words: not those that may
    /// have landed. Insert is offered once the press is closed, since an ask is queued behind its
    /// insert; while it is open the face shows what it heard instead. Copy is offered where the
    /// click is, since a press's insert would carry what it copied. A refused press's reason is
    /// warned of first, above why any words are held.
    public static func face(of activity: Dictation.Activity, over readiness: EngineReadiness, held: Held?, insertable: Bool) -> Face? {
        let box = activity.box(over: readiness)
        guard box.state != nil || held != nil else { return nil }
        let offer = box.offersClick ? held.flatMap(offer) ?? "" : ""
        let reasons = ([box.refusal].compactMap { $0 } + (held?.warnings ?? [])).map { String($0.trimmingPrefix("WARNING: ")) }
        let warnings = reasons.enumerated().map { index, reason in index == reasons.count - 1 ? reason + offer : reason }
        return Face(
            state: box.state, warnings: warnings, words: box.heard ?? held?.allWords ?? Transcript(words: []),
            controls: held.map { _ in Controls(insert: box.offersInsert && insertable, copy: box.offersCopy) })
    }

    /// What a click into a text field places of what is held, said after why it is held: the
    /// words after any that may have landed, which the box shows ahead of them.
    private static func offer(_ held: Held) -> String? {
        held.offered.map { offered in
            " Click into a text field to insert \(held.standing == nil ? "these words" : "the last \(counted(offered.words.words.count, "word", "words"))")."
        }
    }
}
