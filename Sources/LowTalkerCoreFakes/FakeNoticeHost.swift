import Darwin
import Insertion
import LowTalkerCore
import TestProbes

/// The notice port as a test holds it: one name, hosted or refused as the test says, every notice
/// and question the test tells handed over at once. `NoticeHostContract` holds it to
/// `InputMethodNotices.Host`. [LAW:one-type-per-behavior]
@MainActor
public final class FakeNoticeHost: NoticeHost {
    private struct Open {
        let generation: Int
        let heard: @MainActor (InputMethodNotice) -> Void
        let asked: @Sendable (Question, any Answering) -> Void
        let unsupervise: Disposal
    }

    /// Why the next host is refused, or nil to host it.
    public var refusal: PortNotHosted?
    private var open: Open?
    private var hosted = 0
    private let changes: Changes?

    /// Whether a host is open now.
    public var isHosted: Bool { open != nil }

    /// `changes` is noted at every host and stop, so a test awaits one.
    public init(refusing refusal: PortNotHosted? = nil, noting changes: Changes? = nil) {
        self.refusal = refusal
        self.changes = changes
    }

    public func host(
        heard: @escaping @MainActor (InputMethodNotice) -> Void,
        asked: @escaping @Sendable (Question, any Answering) -> Void,
        superviseInputMethod: @MainActor () -> Disposal
    ) async throws(PortNotHosted) -> Disposal {
        if let refusal { throw refusal }
        guard open == nil else { throw .nameIsTaken("the fake notice port") }
        hosted += 1
        let generation = hosted
        open = Open(generation: generation, heard: heard, asked: asked, unsupervise: superviseInputMethod())
        changes?.note()
        return { [weak self] in
            // Only the host this disposal was handed for, and only once, as a real port's own
            // stop closes that port and no later one.
            guard let self, let open = self.open, open.generation == generation else { return }
            open.unsupervise()
            self.open = nil
            self.changes?.note()
        }
    }

    /// The input method in this process tells a cursor arrival, with `build`.
    public func tellCursorArrived(build: Build? = nil) {
        tell(.cursorArrived(CursorArrival(pid: getpid(), build: build)))
    }

    /// The input method tells `notice`, heard only while a host is open.
    public func tell(_ notice: InputMethodNotice) {
        open?.heard(notice)
    }

    /// The input method asks `question`, answered through `reply`.
    public func ask(_ question: Question, through reply: any Answering) {
        guard let open else { preconditionFailure("a question was asked with no notice port hosted") }
        open.asked(question, reply)
    }
}
