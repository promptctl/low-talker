import Darwin
import Foundation
@testable import Insertion
import DarwinCalls
import TestProbes
import Testing

/// What goes onto the wire comes back off it.
///
/// [LAW:behavior-not-structure] Held against the values and never against the bytes: the
/// contract is that an answer survives the crossing, not that it is spelled any particular
/// way, and a test that pinned the JSON would fail on a change that broke nothing.
@Suite struct WireTests {
    @Test(arguments: [
        InsertionAnswer.inserted(characters: 0, into: "com.example.editor"),
        .inserted(characters: 12, into: "com.example.editor"),
        .refused(.noTextFieldHasFocus),
        .refused(.cursorIsInAnotherApp),
        .refused(.dictationIsInAnotherApp),
        .refused(.requestWasNotReadable),
        .refused(.secureInputIsOn),
        .refused(.senderIsNotThisInstallationsApp),
        .refused(.inputMethodIsBusy),
        .notYetTaken(characters: 5, into: "com.example.editor"),
    ])
    func everyAnswerSurvivesTheCrossing(answer: InsertionAnswer) {
        #expect(Wire.answer(of: Wire.answer(answer)) == answer)
    }

    /// Text is what the request carries, and the alphabet is not this program's to choose:
    /// dictation puts out apostrophes and em dashes, and a person may be dictating into any
    /// language the machine can show.
    @Test(arguments: ["", "hello", "it's a test - really", "🫠 emoji", "日本語", String(repeating: "x", count: 10_000)])
    func everyTextSurvivesTheCrossing(text: String) {
        let request = InsertRequest(text, into: .cursorInFront)
        #expect(Wire.request(of: Wire.request(request)) == request)
    }

    @Test(arguments: [Destination.cursorInFront, .app("com.example.editor")])
    func everyDestinationSurvivesTheCrossing(destination: Destination) {
        let request = InsertRequest("hello", into: destination)
        #expect(Wire.request(of: Wire.request(request)) == request)
    }

    /// An input method from before requests were JSON reads a request as UTF-8 text, and
    /// has to find none, so it refuses the request rather than typing it into the document.
    @Test func aRequestIsNotTextToAnInputMethodThatReadsText() {
        #expect(String(data: Wire.request(InsertRequest("hello", into: .app("com.example.editor"))), encoding: .utf8) == nil)
    }

    /// The refusal that input method answers is one this app reads as a refusal, so the
    /// person is told nothing was inserted rather than that their words may have landed.
    /// Pinned to the bytes, because those bytes are what a build from then sends.
    @Test func theRefusalOfAnInputMethodThatReadsTextIsARefusal() {
        #expect(Wire.answer(of: Data(#"{"refused":{"_0":"requestWasNotText"}}"#.utf8)) == .refused(.requestWasNotReadable))
    }

    /// An input method from before a client without document access was refused names its
    /// no-focus refusal as it always has, and this app reads it as the no-text-field refusal.
    /// Pinned to the bytes for the same reason as the one above.
    @Test func theNoFocusRefusalOfAnEarlierInputMethodIsTheNoTextFieldRefusal() {
        #expect(Wire.answer(of: Data(#"{"refused":{"_0":"noClientHasFocus"}}"#.utf8)) == .refused(.noTextFieldHasFocus))
    }

    @Test func bytesThatAreNotARequestAreNotARequest() {
        #expect(Wire.request(of: Data([0xFF, 0xFE, 0xFD])) == nil)
        #expect(Wire.request(of: Data("hello".utf8)) == nil)
    }

    @Test func nonsenseIsNotAnAnswer() {
        #expect(Wire.answer(of: Data("nonsense".utf8)) == nil)
    }

    /// A greeting is answered with the build, or with nothing by an input method from before
    /// builds were compared, or with the refusal a port gives a sender it turns away.
    @Test func aGreetingsAnswerIsABuildNoneOrARefusal() {
        #expect(Wire.greeting(of: Wire.said(aBuild)) == .admitted(by: aBuild))
        #expect(Wire.greeting(of: Wire.said(nil)) == .admitted(by: nil))
        #expect(Wire.greeting(of: Data()) == .admitted(by: nil))
        #expect(Wire.greeting(of: Wire.answer(.refused(.senderIsNotThisInstallationsApp))) == .refused(.senderIsNotThisInstallationsApp))
        #expect(Wire.greeting(of: Wire.answer(.inserted(characters: 1, into: "com.example.editor"))) == nil)
        #expect(Wire.greeting(of: Data("nonsense".utf8)) == nil)
    }

    /// Every later app reads the build an input method of this one says, and one it cannot
    /// read is an answer nobody could read rather than a mismatch. Pinned to the bytes for
    /// the same reason as the refusals above.
    @Test func aBuildIsSaidInBytesEveryLaterBuildReads() throws {
        let build = Build(number: "9", revision: "0123456789ab")
        #expect(Wire.greeting(of: Data(#"{"number":"9","revision":"0123456789ab"}"#.utf8)) == .admitted(by: build))
        #expect(try JSONSerialization.jsonObject(with: Wire.said(build)) as? [String: String] == ["number": "9", "revision": "0123456789ab"])
    }

    /// An insert that reports no characters is a real answer - a zero-length request arrives
    /// as an empty request and is answered honestly - so nothing here may turn it away.
    @Test func anInsertOfNothingIntoARealAppStillCrosses() {
        let nothing = InsertionAnswer.inserted(characters: 0, into: "com.example.editor")
        #expect(Wire.answer(of: Wire.answer(nothing)) == nothing)
    }
}


/// Long enough that the runner's own stall cannot spend it: the macos-15 CI runner has been
/// measured freezing the test process for 1.6-3.6 s shortly after it starts, and `InputMethodInserter`
/// hands each of its four phases a quarter of what it is given. Said once, because it is one
/// fact about the machine rather than five. [LAW:one-source-of-truth] The cases that ARE
/// timing under test set their own budget and say so.
let aBudgetTheRunnerCannotSpend = Duration.seconds(20)

/// The app a hosted double says it committed into. Any name at all: what crosses the wire is
/// what the far end said, and no case here is about which app that was.
private let anEditor = "com.example.editor"

/// The channel, end to end, against a port standing in for the input method, with the suite
/// on both ends: this process sends, and this process is the one both requirements name.
///
/// Every case here awaits rather than calling the blocking `insert` on its own thread, and
/// that is not a style choice: a test body runs on the cooperative pool, and this repo has
/// already measured what blocking there costs - four blocking calls held every thread of a
/// three-core runner until no other test ran at all. The
/// awaited overload puts the wait on a thread of its own, which is what it is for.
/// [LAW:no-ambient-temporal-coupling]
@Suite struct InserterTests {
    @Test func theTextArrivesAndTheAnswerComesBack() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try hostInsertion(name: name) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        let answer = try await inserter(name).insert("hello there", into: .cursorInFront)
        #expect(answer == Inserted(characters: 11, into: anEditor))
        #expect(seen.text == "hello there")
        withExtendedLifetime(port) {}
    }

    /// Where the words may go reaches the input method as the sender named it, since the
    /// input method is the one that refuses a dictation's words anywhere else.
    @Test func theDestinationArrivesWithTheText() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try hostInsertion(name: name) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        _ = try await inserter(name).insert("hello", into: .app(anEditor))
        #expect(seen.request == InsertRequest("hello", into: .app(anEditor)))
        withExtendedLifetime(port) {}
    }

    /// Hosted from the main actor, as the input method's top-level code hosts it, and
    /// answered on the port's own queue. A closure formed there that took the main actor's
    /// isolation trapped the input method on its first insert, after the words had landed -
    /// measured on studious, 2026-09-27 - so the port takes only closures that hold none.
    @MainActor @Test func aPortHostedOnTheMainActorAnswersOffIt() async throws {
        let name = aPortNobodyElseUses()
        let port = try InsertionPort(
            portName: name, senders: try OwnProcess.identity(), build: aBuild, queue: DispatchQueue(label: name),
            told: { Issue.record("the port was told \($0)") }
        ) { request in
            Optional(request.text).map { InsertionAnswer.inserted(characters: $0.count, into: anEditor) } ?? .refused(.noTextFieldHasFocus)
        }

        #expect(try await inserter(name).insert("hello", into: .cursorInFront) == Inserted(characters: 5, into: anEditor))
        withExtendedLifetime(port) {}
    }

    /// Nothing to say is still something to send. `inserted(characters: 0)` is a modelled
    /// outcome, and empty text has to arrive as a request for empty text, answered with its
    /// count, rather than be turned away on either end.
    @Test func emptyTextCrossesAsARequest() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.text.count, into: anEditor) }

        #expect(try await inserter(name).insert("", into: .cursorInFront) == Inserted(characters: 0, into: anEditor))
        withExtendedLifetime(port) {}
    }

    /// Larger than the buffer a request is first received into, so the receive has to grow
    /// to it and take the same message again rather than lose it.
    @Test func aLongRequestCrossesWhole() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.text.count, into: anEditor) }

        let long = String(repeating: "dictated words ", count: 10_000)
        #expect(try await inserter(name).insert(long, into: .cursorInFront) == Inserted(characters: long.count, into: anEditor))
        withExtendedLifetime(port) {}
    }

    /// A refusal crosses the wire as an answer and is thrown past it, by name: to the caller
    /// it is a failure like any other, since the words are not at the cursor.
    @Test func aRefusalIsThrownByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { _ in .refused(.noTextFieldHasFocus) }

        await #expect(throws: InsertFailure.refused(.noTextFieldHasFocus)) { try await inserter(name).insert("hello", into: .cursorInFront) }
        withExtendedLifetime(port) {}
    }

    /// Words the app in front has not taken yet cross the wire as their own answer and are
    /// thrown past it by that name - never as a refusal, since they may still land.
    @Test func wordsNotYetTakenAreThrownByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .notYetTaken(characters: $0.text.count, into: anEditor) }

        await #expect(throws: InsertFailure.notYetTaken(NotYetTaken(characters: 5, into: anEditor))) { try await inserter(name).insert("hello", into: .cursorInFront) }
        withExtendedLifetime(port) {}
    }

    /// Bytes that are not a request are answered rather than dropped, so a sender learns why
    /// instead of waiting out its timeout. [LAW:no-silent-failure]
    @Test func bytesThatAreNotARequestAreRefusedByName() async throws {
        let name = aPortNobodyElseUses()
        let port = try hostInsertion(name: name) { .inserted(characters: $0.text.count, into: anEditor) }

        // Sent by hand, because no `Inserter` can put bytes that are not a request onto the wire,
        // and on a thread of its own for the reason the suite doc gives.
        let answer = try await onAThreadOfItsOwn { try roundTrip(Data([0xFF, 0xFE]), to: name) }
        #expect(Wire.answer(of: answer) == .refused(.requestWasNotReadable))
        withExtendedLifetime(port) {}
    }

    /// A second port on one name is refused rather than built onto nothing, and the first
    /// goes on answering with its own closure.
    @Test func aSecondPortOnOneNameIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let first = try hostInsertion(name: name) { .inserted(characters: $0.text.count, into: anEditor) }

        #expect {
            _ = try hostInsertion(name: name) { _ in .refused(.noTextFieldHasFocus) }
        } throws: { error in
            guard case PortNotHosted.nameIsTaken(name)? = error as? PortNotHosted else { return false }
            return true
        }
        #expect(try await inserter(name).insert("hello", into: .cursorInFront) == Inserted(characters: 5, into: anEditor))
        withExtendedLifetime(first) {}
    }
}

/// Who gets through, with a real second process on the sending end: the check is only worth
/// what it refuses, and the process it has to refuse is never the one checking.
/// [LAW:verifiable-goals]
@Suite struct SenderTests {
    /// The exposure low-input-method-s71.6tk closes: a process that computed the name and
    /// sent to it. Its words never reach the insert, it is told why, and the log line says
    /// who it was and who was required.
    @Test func aSenderThatIsNotTheOneNamedIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let told = Told()
        let us = try OwnProcess.identity()
        let port = try InsertionPort(portName: name, senders: us, build: aBuild, queue: DispatchQueue(label: name), told: told.record) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: us)
        #expect(printed == Refusal.senderIsNotThisInstallationsApp.description)
        #expect(seen.text == nil)
        guard case .turnedAway(_, .someoneElse(.adHoc), us)? = told.events.first, told.events.count == 1 else {
            Issue.record("told \(told.events), not once that the probe was turned away as itself")
            return
        }
        #expect(told.events[0].description.contains(us.description))
        withExtendedLifetime(port) {}
    }

    /// Signed by a real certificate, as the identifier required: answered as the app is.
    @Test func theSenderTheIdentityNamesIsAnswered() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let port = try InsertionPort(
            portName: name, senders: probe.identity, build: aBuild, queue: DispatchQueue(label: name), told: { Issue.record("told \($0)") }
        ) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(printed == "inserted 9 into \(anEditor)")
        #expect(seen.text == "type this")
        withExtendedLifetime(port) {}
    }

    /// The same certificate is not enough: signed as anything but the app, the sender is
    /// someone else, and the log names who.
    @Test func aSenderSignedAsAnotherIdentifierIsRefused() async throws {
        let name = aPortNobodyElseUses()
        let told = Told()
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let required = PeerIdentity.signed(identifier: "ai.promptctl.low-talker.test.app", certificate: probe.certificate)
        let port = try InsertionPort(portName: name, senders: required, build: aBuild, queue: DispatchQueue(label: name), told: told.record) {
            .inserted(characters: $0.text.count, into: anEditor)
        }

        let printed = try await Probe.send("type this", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(printed == Refusal.senderIsNotThisInstallationsApp.description)
        guard case .turnedAway(_, .someoneElse(probe.identity), required)? = told.events.first else {
            Issue.record("told \(told.events), not that \(probe.identity) was turned away")
            return
        }
        withExtendedLifetime(port) {}
    }

    /// The other direction: a name anyone can compute is a name anyone can hold, so the app
    /// asks who holds it before saying anything, and a stranger never hears the words.
    @Test func aStrangerHoldingTheNameNeverHearsTheWords() async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try hostInsertion(name: name) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        let us = try OwnProcess.identity()
        let elsewhere = PeerIdentity.adHoc(cdhash: String(repeating: "0", count: 40))
        let asking = InputMethodInserter(portName: name, timeout: aBudgetTheRunnerCannotSpend, answerer: .success(elsewhere), build: aBuild)
        await #expect(throws: InsertFailure.unreachable(.answeredByAStranger(port: name, pid: getpid(), because: .someoneElse(us), required: elsewhere, words: .notSent))) {
            try await asking.insert("hello", into: .cursorInFront)
        }
        #expect(seen.text == nil)
        withExtendedLifetime(port) {}
    }

    /// An input method of another build is never sent the words, whether it is a build
    /// between the same two releases, which only the revision tells apart, or one from before
    /// builds were compared, which answers the greeting with nothing.
    @Test(arguments: [Optional(Build(number: aBuild.number, revision: "ba9876543210")), nil])
    func anInputMethodOfAnotherBuildNeverHearsTheWords(said: Build?) async throws {
        let name = aPortNobodyElseUses()
        let seen = Seen()
        let port = try InsertionPort(portName: name, senders: try OwnProcess.identity(), build: said, queue: DispatchQueue(label: name), told: { _ in }) { request in
            seen.record(request)
            return .inserted(characters: request.text.count, into: anEditor)
        }

        let mismatch = try #require(BuildMismatch(app: aBuild, inputMethod: said))
        await #expect(throws: InsertFailure.buildMismatch(mismatch)) { try await inserter(name).insert("hello", into: .cursorInFront) }
        #expect(seen.text == nil)
        withExtendedLifetime(port) {}
    }

    /// A build that cannot say who its input method is says so on each insert, rather than
    /// sending to whoever answers.
    @Test func anInserterThatCannotNameItsInputMethodSaysSo() async {
        let asking = InputMethodInserter(portName: aPortNobodyElseUses(), timeout: .seconds(1), answerer: .failure(.noCertificate), build: aBuild)
        await #expect(throws: InsertFailure.answererUnreadable(.noCertificate)) { try await asking.insert("hello", into: .cursorInFront) }
    }
}

/// Reading a process's identity off the kernel, against processes whose signatures this
/// suite knows.
@Suite struct PeerIdentityTests {
    /// Read off the running process the way `codesign` reads it off the file.
    @Test func aSignedProcessIsReadAsItsIdentifierAndCertificate() async throws {
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe")
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let name = aPortNobodyElseUses()
        let read = Read()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { request in
            read.record(Result { () throws(PeerIdentity.Unreadable) in try PeerIdentity.of(request.sender) })
            return Wire.answer(.refused(.noTextFieldHasFocus))
        }

        _ = try await Probe.send("hello", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(try read.result?.get() == probe.identity)
        withExtendedLifetime(port) {}
    }

    /// A certificate vouches for code only when nothing else can be loaded into it, so a
    /// signed process without the hardened runtime is not read as signed at all.
    @Test func aSignedProcessWithoutTheHardenedRuntimeIsNotReadAsSigned() async throws {
        let probe = try await Probe.signed(as: "ai.promptctl.low-talker.test.probe", hardened: false)
        defer { try? FileManager.default.removeItem(at: probe.url) }
        let name = aPortNobodyElseUses()
        let read = Read()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { request in
            read.record(Result { () throws(PeerIdentity.Unreadable) in try PeerIdentity.of(request.sender) })
            return Wire.answer(.refused(.noTextFieldHasFocus))
        }

        _ = try await Probe.send("hello", to: name, answeredBy: try OwnProcess.identity(), from: probe.url)
        #expect(read.result.map { if case .failure(.notHardened) = $0 { true } else { false } } == true)
        withExtendedLifetime(port) {}
    }

    @Test func aTokenNamingNoProcessIsUnreadable() throws {
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: 99_999_999)
        #expect(throws: PeerIdentity.Unreadable.self) { try PeerIdentity.of(token) }
    }
}

/// The ways the transport can fail to carry the question, each seen as its own named error.
/// Named, because each one means something different to do.
///
/// All but `failed`, which is the bucket for a Mach status nothing here asks for - a channel
/// that broke under us - and there is no way to ask the kernel for one; and
/// `answeredByAStranger`, which is a question of who answered and is held with the others
/// like it, in `SenderTests`.
@Suite struct UnreachableTests {
    @Test func nothingListeningIsSaidByName() async {
        let name = aPortNobodyElseUses()
        await #expect(throws: InsertFailure.unreachable(.nothingIsListening(port: name))) {
            try await inserter(name, timeout: .seconds(1)).insert("hello", into: .cursorInFront)
        }
    }

    /// A request nobody ever takes, which is a different failure from an answer that never
    /// comes back, and is said as one.
    ///
    /// The far end is a port whose queue is suspended - the name resolves, so this is not
    /// "nothing is listening", and nothing ever dequeues, so the queue behind it fills and
    /// the send has nowhere left to go. Filled by sending until a send says so rather than by
    /// counting to the limit, which is the kernel's number and not this suite's. Nothing here
    /// can be hurried by a busy machine either: a queue nobody drains does not drain later.
    /// [LAW:no-ambient-temporal-coupling]
    @Test func aRequestThatIsNeverTakenIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let held = DispatchQueue(label: name)
        held.suspend()
        // Resumed before the port goes, because a suspended queue released is a crash; the
        // port then drains and answers what was queued, to nobody.
        defer { held.resume() }
        let port = try InsertionPort(portName: name, senders: try OwnProcess.identity(), build: aBuild, queue: held, told: { _ in }) {
            .inserted(characters: $0.text.count, into: anEditor)
        }

        let budget = Duration.milliseconds(200)
        let filled = try await onAThreadOfItsOwn {
            var remote = mach_port_t()
            try #require(lt_bootstrap_look_up(name, &remote) == KERN_SUCCESS)
            defer { mach_port_deallocate(mach_task_self_, remote) }
            for _ in 0 ..< 64 {
                let sent = Mach.send(
                    Data("x".utf8), id: 0, to: remote, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
                    replyTo: Mach.noPort, timeout: budget)
                if sent == MACH_SEND_TIMED_OUT { return true }
            }
            return false
        }
        #expect(filled, "the queue behind the port never filled, so no send timeout can be asked for")

        await #expect(throws: InsertFailure.unreachable(.requestWasNotTaken(port: name, after: budget / 4))) {
            try await inserter(name, timeout: budget).insert("hello", into: .cursorInFront)
        }
        withExtendedLifetime(port) {}
    }

    /// A send that times out hands its message back with the answer's right in it, and
    /// that right is let go with the rest. Let go, a send-once right says so: the kernel
    /// tells the port it named that no answer is coming. Held, it says nothing, ever.
    @Test func aSendThatTimesOutLetsGoOfTheWayBack() throws {
        let far = try ReceiveRight(sendable: true)
        let reply = try ReceiveRight(sendable: false)
        var filled = false
        for _ in 0 ..< 64 where !filled {
            filled = Mach.send(
                Data("x".utf8), id: 0, to: far.port, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
                replyTo: Mach.noPort, timeout: .zero) == MACH_SEND_TIMED_OUT
        }
        try #require(filled, "the queue never filled, so no send can time out")

        let sent = Mach.send(
            Data("x".utf8), id: 0, to: far.port, disposition: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND),
            replyTo: reply.port, timeout: .zero)

        #expect(sent == MACH_SEND_TIMED_OUT)
        guard case .received(let told) = Mach.receive(on: reply.port, timeout: .zero) else {
            Issue.record("the way back is still held: nothing told the reply port no answer is coming")
            return
        }
        #expect(told.id == Mach.answerAbandoned)
    }

    /// A live input method that does not finish in time is not a missing one, and the two
    /// are not said the same way.
    @Test func anAnswerThatDoesNotArriveIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        // Told nothing, because the answer this port finally sends goes to a sender that
        // stopped listening long before, and is reported after this case has ended. Held at a
        // gate this case opens as it ends, not for a duration: the wait holds a worker of the
        // port's queue, and no longer than the case needs it. [LAW:no-ambient-temporal-coupling]
        let done = DispatchSemaphore(value: 0)
        defer { done.signal() }
        let port = try InsertionPort(portName: name, senders: try OwnProcess.identity(), build: aBuild, queue: DispatchQueue(label: name), told: { _ in }) { request in
            done.wait()
            return .inserted(characters: request.text.count, into: anEditor)
        }

        // Quartered, because the four phases of an insert share the caller's budget and the
        // error names the phase's own bound rather than a number nobody waited. Five seconds
        // a phase rather than the least that works: which phase ran out is the whole of what
        // this case asks, and the runner freeze the budget above is sized against would
        // otherwise fail it in the greeting. The five seconds this case does spend are the
        // last receive, which is the wait under test.
        let timeout = Duration.seconds(20)
        await #expect(throws: InsertFailure.unreachable(.answerDidNotArrive(port: name, after: timeout / 4))) {
            try await inserter(name, timeout: timeout).insert("hello", into: .cursorInFront)
        }
        withExtendedLifetime(port) {}
    }

    /// A far end that never says who it is is not sent the words, and says so rather than
    /// that they may have landed.
    @Test func aGreetingThatIsNotAnsweredIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        // Held at a gate this case opens as it ends, as in `anAnswerThatDoesNotArriveIsSaidByName`.
        let done = DispatchSemaphore(value: 0)
        defer { done.signal() }
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) { _ in
            done.wait()
            return Data()
        }

        let timeout = Duration.seconds(4)
        await #expect(throws: InsertFailure.unreachable(.didNotSayWhoItIs(port: name, after: timeout / 4))) {
            try await inserter(name, timeout: timeout).insert("hello", into: .cursorInFront)
        }
        withExtendedLifetime(port) {}
    }

    /// A far end that takes the words and lets go of the way back is said at once, rather
    /// than waited out as an answer that is merely late.
    @Test func anAnswerAbandonedIsSaidByName() async throws {
        let name = aPortNobodyElseUses()
        let right = try ReceiveRight(sendable: true)
        try #require(lt_bootstrap_register(name, right.port) == KERN_SUCCESS)
        Thread {
            guard case .received(let greeting) = Mach.receive(on: right.port, timeout: aBudgetTheRunnerCannotSpend) else { return }
            _ = greeting.answer(Wire.said(aBuild))
            guard case .received(let words) = Mach.receive(on: right.port, timeout: aBudgetTheRunnerCannotSpend) else { return }
            words.discardReply()
        }.start()

        await #expect(throws: InsertFailure.unreachable(.answerWasAbandoned(port: name))) {
            try await inserter(name).insert("hello", into: .cursorInFront)
        }
        withExtendedLifetime(right) {}
    }

    /// An answer nobody can read is a skew between the two halves, and saying so names the
    /// only thing that fixes it. Never mistaken for a refusal: a refusal is a fact about
    /// the cursor, and this is a fact about the build. Said with where the words were: an
    /// unreadable greeting stopped them, an unreadable answer to them came after they went.
    @Test(arguments: [(Wire.greeting, Words.notSent), (Wire.insert, Words.mayHaveLanded)])
    func anAnswerNobodyCanReadIsSaidByName(garbled: mach_msg_id_t, words: Words) async throws {
        let name = aPortNobodyElseUses()
        let port = try InsertionPort(portName: name, queue: DispatchQueue(label: name), told: { _ in }) {
            $0.id == garbled ? Data("nonsense".utf8) : Wire.said(aBuild)
        }

        await #expect(throws: InsertFailure.unreachable(.answerWasNotReadable(port: name, bytes: 8, words: words))) {
            try await inserter(name).insert("hello", into: .cursorInFront)
        }
        withExtendedLifetime(port) {}
    }
}
