import Foundation
import Insertion

/// The app as the input method's gate asks it, answering each question with what the test gave
/// it, and with no port and no app. The one `SteeringAsking` fake: `QuestionsContract` holds it
/// to `Asker` on the one thing it decides, which answer each question reads.
/// [LAW:one-type-per-behavior]
///
/// An app that is asked nothing in particular owes nothing, has settled, and has no box to dismiss,
/// which is the app on any key typed while no one is dictating.
public struct FakeApp: SteeringAsking {
    public var owing: @Sendable () -> Result<Owing, NotAnswered>
    public var settling: @Sendable () -> Result<Settlement, NotAnswered>
    public var dismissing: @Sendable () -> Result<Dismissal, NotAnswered>

    public init(
        owing: @escaping @Sendable () -> Result<Owing, NotAnswered> = { .success(.nothing) },
        settling: @escaping @Sendable () -> Result<Settlement, NotAnswered> = { .success(.landed) },
        dismissing: @escaping @Sendable () -> Result<Dismissal, NotAnswered> = { .success(.nothingShown) }
    ) {
        (self.owing, self.settling, self.dismissing) = (owing, settling, dismissing)
    }

    public func owed(at _: TimeInterval, within _: Duration) -> Result<Owing, NotAnswered> { owing() }
    public func settled(at _: TimeInterval, within _: Duration) -> Result<Settlement, NotAnswered> { settling() }
    public func dismiss(at _: TimeInterval, within _: Duration) -> Result<Dismissal, NotAnswered> { dismissing() }
}

/// The right to answer one question, as the app's steering holds it, which hands the answer to the
/// test instead of a port. The one `Answering` fake, held by `QuestionsContract` to what `Reply`
/// does with each answer: delivered, and read by the asker as what was sent. A second answer
/// stops here as it stops `Reply`.
public final class FakeReply: Answering {
    /// The answer, as it was sent.
    public enum Said: Equatable, Sendable {
        case owing(Owing)
        case settlement(Settlement)
        case dismissal(Dismissal)
    }

    private let stream: AsyncStream<Said>
    private let continuation: AsyncStream<Said>.Continuation

    public init() { (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }

    public func send(_ owing: Owing) -> Reply.Delivery { deliver(.owing(owing)) }
    public func send(_ settlement: Settlement) -> Reply.Delivery { deliver(.settlement(settlement)) }
    public func send(_ dismissal: Dismissal) -> Reply.Delivery { deliver(.dismissal(dismissal)) }

    private func deliver(_ said: Said) -> Reply.Delivery {
        // A second answer is the same programming error here that `Reply` stops on.
        guard case .enqueued = continuation.yield(said) else { preconditionFailure("a question is answered once") }
        continuation.finish()
        return .delivered
    }

    /// The answer, waiting for it if none has been sent yet.
    public func said() async -> Said {
        for await said in stream { return said }
        preconditionFailure("the question was let go of unanswered")
    }
}
