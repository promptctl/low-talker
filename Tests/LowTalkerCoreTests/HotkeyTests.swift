import Dispatch
import Foundation
import LowTalkerCore
import LowTalkerCoreFakes
import TestProbes
import Testing
import Uptime

private struct Refused: Error, Equatable {}

/// Lets the main queue run what the hotkey put on it.
///
/// The queue is first-in-first-out, so everything queued before this call has run by the
/// time it resumes. Waiting on the queue itself rather than on a duration, so the wait is
/// exactly as long as the work and a slow machine cannot make it flake.
/// [LAW:no-ambient-temporal-coupling]
private func settle() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

extension Hotkey {
    /// A handler that only records what it was told: a press it never refuses.
    fileprivate func start(_ onTransition: @escaping @MainActor (HotkeyDetector.Transition) -> Void) throws {
        try start { transition in onTransition(transition); return nil }
    }
}

private let rightOption = Mode.dictation

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

/// A keyboard whose keys are stamped on a clock that stands at `at(0)`, as `at` counts from.
@MainActor private func keyboard(refusing refusal: (any Error)? = nil) -> FakeModifierFeed {
    FakeModifierFeed(on: ManualHostClock().clock, refusing: refusal)
}

/// Right Option moving at `ms`, with a key last typed at `typed`: long before the run, unless
/// the test says.
private func rightOption(_ direction: KeyEvent.Direction, at ms: Int64, typed: Int64 = -60_000) -> KeyEvent {
    KeyEvent(key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: at(ms),
             lastTyped: at(typed))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandler() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        #expect(hotkey.phase == .held(rightOption, since: at(0)))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
        installation.handle(rightOption(.up, at: 400))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(.released(.hold, at: at(400)))])
    }

    /// The repro of low-unfiled-50ff.28v: Right Option down, A typed under it, Right Option
    /// up, all within 150 ms. The press ends at the release instead of latching open.
    @Test func aChordThatWasATypedKeysModifierLeavesNothingListening() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        installation.handle(rightOption(.up, at: 110, typed: 40))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(.usedAsModifier)])
        #expect(hotkey.phase == .idle)
    }

    /// A latched tap ended by another mode's chord reaches the handler as its end and then the
    /// other mode's beginning, in that order, as `Dictation.press` requires.
    @Test func aSwitchReachesTheHandlerEndedThenBegan() async throws {
        let notes = Mode(name: "notes", chord: KeyChord(modifiers: .rightCommand))
        let feed = keyboard()
        let hotkey = Hotkey(modes: try Modes([rightOption, notes]), feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        installation.handle(rightOption(.up, at: 100))
        installation.handle(KeyEvent(key: .rightCommand, direction: .down, modifiers: [.rightCommand], time: at(1000), lastTyped: at(-60_000)))
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(.released(.tap, at: at(1000))), .began(notes, at: at(1000))])
    }

    /// Every transition leaves by the main queue, never from inside the feed's call, so a
    /// `began` is always ahead of the `ended` that follows it however the two were told.
    /// [LAW:behavior-not-structure] asserted as what the caller can observe - a decision in
    /// hand with the handler not yet run.
    @Test func theHandlerRunsAfterTheEventIsRead() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        #expect(transitions.isEmpty, "the handler ran inside the feed's call")
        await settle()
        #expect(transitions == [.began(rightOption, at: at(0))])
    }

    /// Stopping mid-press ends the press as lapsed at its handler, since its release can
    /// no longer arrive, and a later start begins from rest.
    @Test func stopEndsAnOpenPressAndDisposesTheFeed() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        feed.installations[0].handle(rightOption(.down, at: 0))
        hotkey.stop()
        #expect(feed.installations[0].disposed)
        #expect(!hotkey.isWatching)
        #expect(hotkey.phase == .idle)
        await settle()
        // The ending goes out the same way the beginning did, so it cannot overtake it.
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(.lapsed)])
        hotkey.stop()
        await settle()
        #expect(transitions.count == 2)
    }

    /// A handler that refuses the press it was handed at `began`, as `Dictation` does when no
    /// microphone opens, takes nothing else.
    private func refusing(_ transitions: Box) -> Hotkey.Handler {
        { transition in
            transitions.told.append(transition)
            if case .began = transition { return PressRefusal() }
            return nil
        }
    }

    private final class Box {
        var told: [HotkeyDetector.Transition] = []
    }

    /// The refusal is read while the chord is still down: the tap ends as the chord comes up and
    /// latches nothing.
    @Test func aRefusedPressTappedEndsAtTheReleaseAndLatchesNothing() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        let box = Box()
        try hotkey.start(refusing(box))
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        await settle()
        await settle()
        installation.handle(rightOption(.up, at: 100))
        await settle()
        #expect(box.told == [.began(rightOption, at: at(0)), .ended(.released(.tap, at: at(100)))])
        #expect(hotkey.phase == .idle)
    }

    /// The chord's release was read before the refusal was delivered: the press ends then, once,
    /// after its beginning, so the next press of the chord begins a press.
    @Test func aRefusalDeliveredAfterTheTapLatchedEndsItOnce() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        let box = Box()
        try hotkey.start(refusing(box))
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        installation.handle(rightOption(.up, at: 100))
        await settle()
        await settle()
        #expect(box.told.count == 2)
        #expect(box.told.first == .began(rightOption, at: at(0)))
        guard case .ended(.released(.tap, _)) = try #require(box.told.last) else { Issue.record("the press did not end as a tap: \(box.told)"); return }
        #expect(hotkey.phase == .idle)

        installation.handle(rightOption(.down, at: 1000))
        await settle()
        #expect(box.told.last == .began(rightOption, at: at(1000)))
    }

    /// A start puts a fresh feed up and takes the last one down.
    @Test func aStartReplacesTheFeedThatWasUp() throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        try hotkey.start { _ in }
        try hotkey.start { _ in }
        #expect(feed.installations.count == 2)
        #expect(feed.installations[0].disposed)
        #expect(!feed.installations[1].disposed)
        #expect(hotkey.isWatching)
    }

    @Test func aRefusedFeedThrowsFromStart() {
        let hotkey = Hotkey(modes: Config.default.modes, feed: keyboard(refusing: Refused()))
        #expect(throws: Refused.self) { try hotkey.start { _ in } }
        #expect(!hotkey.isWatching)
        #expect(hotkey.phase == .idle)
    }

    @Test func releasingTheHotkeyDisposesTheFeed() throws {
        let feed = keyboard()
        do {
            let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
            try hotkey.start { _ in }
        }
        #expect(feed.installations[0].disposed)
    }

    /// What the hotkey did is a record a test reads: each transition handed on, and the press the
    /// loop refused at `began`, whose ending is a transition of its own.
    @Test func aTransitionAndARefusedPressAreRecorded() async throws {
        let feed = FakeModifierFeed(on: ManualHostClock(startingAt: at(50)).clock)
        let records = Records()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed) { records.all.append($0) }
        try hotkey.start(refusing(Box()))
        feed.type(rightOption(.down, at: 0))
        await settle()
        await settle()
        feed.type(rightOption(.up, at: 100))
        await settle()
        #expect(records.all == [
            .transition(.began(rightOption, at: at(0))),
            .refused(pressBegunAt: at(0)),
            .transition(.ended(.released(.tap, at: at(100)))),
        ])
    }

    /// A tap that latched before its refusal was read is ended by the refusal, at the moment it
    /// is read on the clock the feed stamps its keys on.
    @Test func aLatchedTapIsEndedWhenItsRefusalIsRead() async throws {
        let feed = FakeModifierFeed(on: ManualHostClock(startingAt: at(250)).clock)
        let records = Records()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed) { records.all.append($0) }
        let told = Box()
        try hotkey.start(refusing(told))
        feed.type(rightOption(.down, at: 0))
        feed.type(rightOption(.up, at: 100))
        await settle()
        await settle()
        #expect(records.all == [
            .transition(.began(rightOption, at: at(0))),
            .refused(pressBegunAt: at(0)),
            .transition(.ended(.released(.tap, at: at(250)))),
        ])
        #expect(told.told == [.began(rightOption, at: at(0)), .ended(.released(.tap, at: at(250)))])
        #expect(hotkey.phase == .idle)
    }

    /// The log line is the record's rendering, and only that.
    @Test func aRecordRendersAsItsLogLine() {
        let began = HotkeyDetector.Transition.began(rightOption, at: at(987_654))
        #expect("\(Hotkey.Record.transition(began))" == "\(began)")
        #expect("\(Hotkey.Record.refused(pressBegunAt: at(987_654)))" == "the press begun at 987654 ms of uptime was refused")
    }

    @MainActor private final class Records {
        var all: [Hotkey.Record] = []
    }
}

/// The modifier feed's contract against its one fake, which every suite that types on a keyboard
/// uses.
@MainActor
@Suite struct ModifierFeedContractTests {
    static let fake = ModifierFeedContract { refusing in
        let feed = keyboard(refusing: refusing ? Refused() : nil)
        return ModifierFeedContract.Subject(feed: feed, type: feed.type)
    }

    @Test(arguments: ModifierFeedContract.Statement.allCases)
    func theFakeKeepsTheStatement(_ statement: ModifierFeedContract.Statement) {
        #expect(Self.fake.disagreements(with: statement) == [])
    }
}

/// A chord in the words a person presses it by.
@Suite struct ChordNameTests {
    /// One chord spells one name whichever way its keys were listed, in `Modifier.allCases`
    /// order.
    @Test func aChordIsNamedInWords() throws {
        #expect(Hotkey.named(Hotkey.defaultChord) == "Right Option")
        #expect(Hotkey.named(try #require(KeyChord(modifiers: [.rightCommand, .rightOption]))) == "Right Option+Right Command")
    }
}

/// A key that steers dictation reaches the loop as the end of the press it ended, through the one
/// door every transition leaves by.
@MainActor
extension HotkeyTests {
    @Test func aSteeringKeyEndsALatchedPressThroughTheHandlerInOrder() async throws {
        let feed = keyboard()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        var transitions: [HotkeyDetector.Transition] = []
        try hotkey.start { transitions.append($0) }
        let installation = try #require(feed.installations.first)
        installation.handle(rightOption(.down, at: 0))
        installation.handle(rightOption(.up, at: 100))

        let steered = hotkey.steer(.send(at: at(5000)))
        await settle()

        #expect(steered == .ended(.ended(.released(.tap, at: at(5000)))))
        #expect(transitions == [.began(rightOption, at: at(0)), .ended(.released(.tap, at: at(5000)))])
        #expect(hotkey.phase == .idle)
    }

    @Test func aSteeringKeyBeforeTheHotkeyStartedEndsNothing() {
        let hotkey = Hotkey(modes: Config.default.modes, feed: keyboard())
        #expect(hotkey.steer(.send(at: at(0))) == .nothingOpen)
    }
}
