import Dictation

/// The word box's panel as a test holds it: what it was told to show, in order, and nothing on
/// screen. The one `WordBoxPanel` fake. [LAW:one-type-per-behavior]
@MainActor
public final class FakePanel: WordBoxPanel {
    public enum Shown: Equatable {
        case face(WordBox.Face)
        case away
    }

    public private(set) var shown: [Shown] = []

    public init() {}

    /// The face on screen, nil once the box is put away or before it is shown.
    public var face: WordBox.Face? {
        if case .face(let face)? = shown.last { face } else { nil }
    }

    public func draw(_ face: WordBox.Face) { shown.append(.face(face)) }
    public func hide() { shown.append(.away) }
    public var isShown: Bool { face != nil }
}
