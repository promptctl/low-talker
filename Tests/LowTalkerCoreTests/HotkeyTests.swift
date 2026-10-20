import Dispatch
import Foundation
import LowTalkerCore
import Testing

private struct Refused: Error, Equatable {}

/// A feed a test controls: the handler it was given is the test's to call.
@MainActor
private final class FakeFeed: ModifierFeed {
    final class Installation {
        let handle: @MainActor (KeyEvent) -> Void
        var disposed = false

        init(handle: @escaping @MainActor (KeyEvent) -> Void) {
            self.handle = handle
        }
    }

    private(set) var installations: [Installation] = []
    private let refusal: (any Error)?

    init(refusing refusal: (any Error)? = nil) {
        self.refusal = refusal
    }

    func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
        if let refusal { throw refusal }
        let installation = Installation(handle: handle)
        installations.append(installation)
        return { installation.disposed = true }
    }
}

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

private let rightOption = Mode.dictation

private func at(_ ms: Int64) -> HostTime { HostTime(uptime: .milliseconds(ms)) }

/// Right Option moving at `ms`, with a key last typed at `typed`: long before the run, unless
/// the test says.
private func rightOption(_ direction: KeyEvent.Direction, at ms: Int64, typed: Int64 = -60_000) -> KeyEvent {
    KeyEvent(key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [], time: at(ms),
             lastTyped: at(typed))
}

@MainActor
@Suite struct HotkeyTests {
    @Test func aPressReachesTheHandler() async throws {
        let feed = FakeFeed()
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
        let feed = FakeFeed()
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
        let feed = FakeFeed()
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
        let feed = FakeFeed()
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
        let feed = FakeFeed()
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

    /// A start puts a fresh feed up and takes the last one down.
    @Test func aStartReplacesTheFeedThatWasUp() throws {
        let feed = FakeFeed()
        let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
        try hotkey.start { _ in }
        try hotkey.start { _ in }
        #expect(feed.installations.count == 2)
        #expect(feed.installations[0].disposed)
        #expect(!feed.installations[1].disposed)
        #expect(hotkey.isWatching)
    }

    @Test func aRefusedFeedThrowsFromStart() {
        let hotkey = Hotkey(modes: Config.default.modes, feed: FakeFeed(refusing: Refused()))
        #expect(throws: Refused.self) { try hotkey.start { _ in } }
        #expect(!hotkey.isWatching)
        #expect(hotkey.phase == .idle)
    }

    @Test func releasingTheHotkeyDisposesTheFeed() throws {
        let feed = FakeFeed()
        do {
            let hotkey = Hotkey(modes: Config.default.modes, feed: feed)
            try hotkey.start { _ in }
        }
        #expect(feed.installations[0].disposed)
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
