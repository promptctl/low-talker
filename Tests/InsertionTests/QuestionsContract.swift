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
    enum Exchange: Sendable, CustomStringConvertible {
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

        /// The answer sent through `reply`.
        func answer(through reply: some Answering) -> Reply.Delivery {
            switch self {
            case .owed(let owing): reply.send(owing)
            case .settled(let settlement): reply.send(settlement)
            case .panel(let panel): reply.send(panel)
            }
        }

        /// The question asked of `app`, read back as the answer it carried.
        func ask(_ app: some SteeringAsking) -> Result<Exchange, NotAnswered> {
            switch self {
            case .owed: app.owed(at: 1, within: aBudgetTheRunnerCannotSpend).map(Exchange.owed)
            case .settled: app.settled(at: 1, within: aBudgetTheRunnerCannotSpend).map(Exchange.settled)
            case .panel: app.panel(at: 1, within: aBudgetTheRunnerCannotSpend).map(Exchange.panel)
            }
        }
    }

    static let exchanges: [Exchange] =
        Owing.allCases.map(Exchange.owed) + Settlement.allCases.map(Exchange.settled) + PanelState.allCases.map(Exchange.panel)

    @Test(arguments: exchanges)
    func theFakesCarryAnAnswerAsThePortDoes(exchange: Exchange) async throws {
        // The fakes: the app's answer through its right, and the input method's question of an app
        // that gives what that right was sent.
        let reply = FakeReply()
        let fakeDelivery = exchange.answer(through: reply)
        let said = await reply.said()
        let fakeRead = exchange.ask(FakeApp(
            owing: { if case .owing(let owing) = said { .success(owing) } else { .failure(.wire(.abandoned(port: "fake"))) } },
            settling: { if case .settlement(let settlement) = said { .success(settlement) } else { .failure(.wire(.abandoned(port: "fake"))) } },
            panelling: { if case .panel(let panel) = said { .success(panel) } else { .failure(.wire(.abandoned(port: "fake"))) } }))

        // The real ends, across a port.
        let name = aPortNobodyElseUses()
        let (port, _, questions) = try hostNoticesAndQuestions(name: name, senders: try OwnProcess.identity())
        let asker = Asker(portName: name, answerer: .success(try OwnProcess.identity()))
        async let realRead = onAThreadOfItsOwn { exchange.ask(asker) }
        let asked = try #require(await questions.first { @Sendable _ in true })
        let realDelivery = exchange.answer(through: asked.reply)

        #expect(fakeDelivery == .delivered)
        #expect(realDelivery == fakeDelivery)
        #expect("\(try fakeRead.get())" == "\(exchange)")
        #expect("\(try await realRead.get())" == "\(exchange)")
        withExtendedLifetime(port) {}
    }
}
