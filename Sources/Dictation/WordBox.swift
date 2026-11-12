import GrammaticalNumber
import Insertion
import LowTalkerCore

/// What the word box draws, put on screen by the app. The box decides, and the panel only lays
/// out and orders in what it was given. [LAW:effects-at-boundaries]
@MainActor
public protocol WordBoxPanel: AnyObject {
    func draw(_ face: WordBox.Face)
    func hide()
    /// Whether the panel is on screen, which a draw with nowhere to put it is not.
    var isShown: Bool { get }
}

/// The word box: the panel near the bottom of the screen while a press is on its way, or while
/// words no cursor took are held, and the person's dismissal of it, with Escape or the circle on
/// its corner, which keeps what the activity alone shows away until a press opens after it.
///
/// [LAW:one-source-of-truth] It draws `Dictation.Activity` and `Held` as it is handed them, and
/// keeps only what neither says: the dismissal, and whether the press open at it has closed.
/// Neither shows a press the person threw away, so words held after a dismissal are new to the
/// person, and draw the box.
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
    /// The person put the box away, so what the activity alone shows stays away.
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
        // A press opening is new words to show.
        if pressIsOpen && !pressWasOpen { dismissed = false }
        pressWasOpen = pressIsOpen
        // A press open over a dismissal is the one the Escape ended, its ending still in delivery,
        // or a refusal, which cannot be cancelled: words held under either wait for it to close.
        guard !dismissed || (held != nil && !pressIsOpen), let face = Self.face(of: activity, over: readiness, held: held, insertable: insertable) else { return panel.hide() }
        panel.draw(face)
    }

    /// The person put the dictation away, with Escape or the circle: the held words no cursor has
    /// taken are let go, the press the box shows, open or on its way, is cancelled through
    /// `steering`, and the box is put away until a press opens or words are held again. The words
    /// the press already put at the cursor are taken back by the press's own path.
    /// [LAW:single-enforcer] One dismissal, whichever way it was asked for, so the circle cannot
    /// let go of the words and leave the microphone open. `hold` is handed in because the hold
    /// shows the box from its own start, before a box built over it could be. Dismissed first,
    /// so the box the hold shows as it lets go is already put away, and the words let go before
    /// the cancel, so the activity the cancel shows is drawn over nothing held.
    public func dismiss(cancelling steering: KeySteering?, hold: Hold) {
        dismissed = true
        hold.dismiss()
        steering?.escape()
        panel.hide()
    }

    /// An Escape the input method asks the app to take: the person putting the box away while it
    /// is on screen, decided and done in this one turn so the answer cannot go stale, and nothing
    /// while it is not, so the Escape is the app in front's. A box already put away does not take
    /// a second Escape, which would throw away the presses still on their way past it.
    public func escape(cancelling steering: KeySteering, hold: Hold) -> Dismissal {
        guard panel.isShown else { return .nothingShown }
        dismiss(cancelling: steering, hold: hold)
        return .dismissed
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
