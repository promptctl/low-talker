import AppKit
@testable import InputMethod
import InputMethodFakes
import Insertion
import Testing

/// Every record `controller` leaves while `drive` runs, from its making to its ending: the
/// controller is dropped once `drive` returns, so its stream finishes. Every record is checked to
/// be this controller's.
@MainActor
func events(of make: () -> DictationInputController?, _ drive: (DictationInputController) async -> Void = { _ in }) async throws -> [ControllerRecord.Event] {
    let (address, records): (UInt, AsyncStream<ControllerRecord>)
    do {
        let controller = try #require(make())
        (address, records) = (UInt(bitPattern: ObjectIdentifier(controller)), controller.records)
        await drive(controller)
    }
    var events: [ControllerRecord.Event] = []
    for await record in records {
        #expect(record.controller == address)
        events.append(record.event)
    }
    // The stream holds the oldest 32 records, so a case that ran past them would not end here.
    #expect(events.first == .made)
    #expect(events.last == .ended)
    return events
}

/// A controller's life and each callback it is handed leave one record each, which is what the
/// running input method is read from (IMK rule 6). Read from the records the controller produced,
/// as values; what the log receives for a record is its `rendering`, asked of it directly.
///
/// On the main actor like every suite that builds an `IMKInputController`.
@Suite @MainActor struct ControllerRecordTests {
    @Test(.timeLimit(.minutes(1))) func aControllerIsMadeThroughEitherInitAndEnds() async throws {
        #expect(try await events(of: { DictationInputController(server: nil, delegate: nil, client: nil) }) == [.made, .ended])
        #expect(try await events(of: { DictationInputController() }) == [.made, .ended])
    }

    /// A sender that is no text client makes no cursor, and the record says the controller holds none.
    @Test(.timeLimit(.minutes(1))) func anActivationAndADeactivationWithNoClientSaySo() async throws {
        let said = try await events(of: { DictationInputController() }) { controller in
            controller.activateServer(nil)
            controller.deactivateServer(nil)
        }
        #expect(said == [
            .made,
            .callback(.inline, .activatedWithoutUsableClient(holding: "holding no client")),
            .callback(.inline, .deactivated(holding: "holding no client")),
            .ended,
        ])
    }

    /// A sender a cursor is made of is the client the controller holds until it is deactivated.
    @Test(.timeLimit(.minutes(1))) func anActivationAndADeactivationWithAClientSayWhichClient() async throws {
        let cursor = try FakeTextInputClient(in: "com.example.ControllerRecordTests").cursor()
        let held = FocusedClient.holding(cursor)
        let said = try await events(of: { DictationInputController() }) { controller in
            controller.activate(nil, makingCursor: { _ in cursor })
            controller.deactivateServer(nil)
        }
        // Whether the cursor is live is `FocusedClient.shared`'s, which other cases share.
        #expect(said.count == 4)
        guard case .callback(.inline, .activated(let activated)) = said[1], case .callback(.inline, .deactivated(let deactivated)) = said[2] else {
            Issue.record("not an activation and a deactivation: \(said)")
            return
        }
        #expect(activated.hasPrefix(held))
        #expect(deactivated.hasPrefix(held))
    }

    /// A command that is no steering key is declined, and the record says so.
    @Test(.timeLimit(.minutes(1))) func aCommandThatIsNoSteeringKeySaysSo() async throws {
        let said = try await events(of: { DictationInputController() }) { controller in
            #expect(controller.didCommand(by: NSSelectorFromString("moveLeft:"), holding: []) == false)
        }
        #expect(said[1] == .callback(.inline, .command("moveLeft:", steered: nil, holding: "holding no client")))
    }

    /// A key typed as text leaves a record that says it was declined, and nothing of what was typed.
    @Test(.timeLimit(.minutes(1))) func aKeyTypedAsTextIsDeclinedAndNotRecorded() async throws {
        let said = try await events(of: { DictationInputController() }) { controller in
            #expect(controller.inputText("secret", client: nil) == false)
        }
        #expect(said[1] == .callback(.inline, .declinedText(holding: "holding no client")))
        #expect(!said.map { ControllerRecord(controller: 0xab, event: $0).rendering.line }.joined().contains("secret"))
    }
}

/// What the unified log receives for a record: the level and line its one edge writes.
@Suite struct ControllerRecordRenderingTests {
    private static let routineReturn = ControllerRecord.Steered(key: .return, decision: SteeringDecision(verdict: .pass, because: "the app owes nothing", routine: true))
    private static let keptReturn = ControllerRecord.Steered(key: .return, decision: SteeringDecision(verdict: .keep, because: "the words did not all reach a cursor", waited: .milliseconds(40)))

    @Test func aControllerLifeIsSaidAtTheDefaultLevel() {
        #expect(ControllerRecord(controller: 0xab, event: .made).rendering == (.default, "controller 0xab was made"))
        #expect(ControllerRecord(controller: 0xab, event: .ended).rendering == (.default, "controller 0xab ended"))
    }

    @Test func anActivationNamesItsClientAndItsHop() {
        let record = ControllerRecord(controller: 0xab, event: .callback(.waited(.milliseconds(3)), .activated(holding: "holding client 7E1 of com.apple.TextEdit")))
        #expect(record.rendering == (.default, "controller 0xab activated, holding client 7E1 of com.apple.TextEdit; reached the main actor \(Hop.waited(.milliseconds(3)))"))
    }

    /// A key typed anywhere is said at debug, which the log does not keep: the log is not a record
    /// of when a person typed.
    @Test func aKeyNothingHeldIsSaidAtDebug() {
        #expect(ControllerRecord(controller: 0xab, event: .callback(.inline, .declinedText(holding: "holding no client"))).rendering.level == .debug)
        #expect(ControllerRecord(controller: 0xab, event: .callback(.inline, .command("moveLeft:", steered: nil, holding: "holding no client"))).rendering.level == .debug)
        let routine = ControllerRecord(controller: 0xab, event: .callback(.inline, .command("insertNewline:", steered: Self.routineReturn, holding: "holding no client")))
        #expect(routine.rendering == (.debug, "controller 0xab was handed insertNewline:, a steering key, Return, that passes: the app owes nothing, holding no client; reached the main actor \(Hop.inline)"))
    }

    /// A Return the gate kept is what a person asks the log about, so it is kept by the log, with
    /// the gate's reason and how long it was held.
    @Test func aKeptReturnIsSaidAtTheDefaultLevelWithItsReason() {
        let kept = ControllerRecord(controller: 0xab, event: .callback(.inline, .command("insertNewline:", steered: Self.keptReturn, holding: "holding no client")))
        #expect(kept.rendering == (.default, "controller 0xab was handed insertNewline:, a steering key, Return, that is kept after \(Duration.milliseconds(40)): the words did not all reach a cursor, holding no client; reached the main actor \(Hop.inline)"))
    }

    @Test func anOverrunSaysTheControllerTookNoClient() throws {
        let overrun = try #require(Overrun(footprint: Notices.memoryCeiling + 1, ceiling: Notices.memoryCeiling))
        #expect(ControllerRecord(controller: 0xab, event: .callback(.inline, .overMemoryCeiling(overrun))).rendering
            == (.default, "controller 0xab activated over the memory ceiling and took no client: \(overrun); reached the main actor \(Hop.inline)"))
    }
}
