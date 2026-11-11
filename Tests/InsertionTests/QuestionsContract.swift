import Foundation
@testable import Insertion
import InsertionFakes
import TestProbes
import Testing

/// What the questions carry: each answer the app sends through its right to answer is delivered,
/// and is what the input method reads back from its question. Stated once, run against the fakes
/// every steering test stands in an end with - `FakeReply` for the app's end and `FakeApp` for the
/// input method's - and against `Reply` and `Asker` over a real port in this process.
/// [LAW:behavior-not-structure]
@Suite(.timeLimit(.minutes(1))) struct QuestionsContract {
    /// One question and the answer the app gives it.
    enum Asked: Sendable, CustomStringConvertible {
        case owed(Owing)
        case settled(Settlement)
        case panel(PanelState)

        var description: String {
            switch self {
            case .owed(let owing): "owed, answered \(owing)"
            case .settled(let settlement): "settled, answered \(settlement)"
            case .panel(let panel): "panel, answered \(panel)"
            }
        }

        /// The answer as `FakeReply` records it.
        var said: FakeReply.Said {
            switch self {
            case .owed(let owing): .owing(owing)
            case .settled(let settlement): .settlement(settlement)
            case .panel(let panel): .panel(panel)
            }
        }

        /// The answer sent through `reply`.
        func answer(through reply: some Answering) -> Reply.Delivery {
            switch self {
            case .owed(let owing): reply.send(owing)
            case .settled(let settlement): reply.send(settlement)
            case .panel(let panel): reply.send(panel)
            }
        }

        /// The question asked of `app`, read back as the answer it carried.
        func ask(_ app: some SteeringAsking) -> Result<Asked, NotAnswered> {
            switch self {
            case .owed: app.owed(at: 1, within: aBudgetTheRunnerCannotSpend).map(Asked.owed)
            case .settled: app.settled(at: 1, within: aBudgetTheRunnerCannotSpend).map(Asked.settled)
            case .panel: app.panel(at: 1, within: aBudgetTheRunnerCannotSpend).map(Asked.panel)
            }
        }
    }

    static let asked: [Asked] =
        Owing.allCases.map(Asked.owed) + Settlement.allCases.map(Asked.settled) + PanelState.allCases.map(Asked.panel)

    @Test(arguments: asked)
    func theFakeCarriesAnAnswerAsThePortDoes(question: Asked) async throws {
        // The fake: the app's answer through its right.
        let reply = FakeReply()
        let fakeDelivery = question.answer(through: reply)
        let said = await reply.said()

        // The real ends, across a port.
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = Asker(portName: name, answerer: .success(try OwnProcess.identity()))
        async let realRead = onAThreadOfItsOwn { question.ask(asker) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        let realDelivery = question.answer(through: asked.reply)

        #expect(fakeDelivery == .delivered)
        #expect(realDelivery == fakeDelivery)
        #expect(said == question.said)
        #expect("\(try await realRead.get())" == "\(question)")
        withExtendedLifetime(port) {}
    }
}
