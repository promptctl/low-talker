import Dictation
import Dispatch
import Foundation
import LowTalkerCore
import TestProbes
import Testing

private struct BadBuffer: Error {}

/// A press the loop refuses at key-down, tapped, over the real loop and the real hotkey started as
/// the app starts it: [LAW:behavior-not-structure] what the person has is whether the next press of
/// the chord listens.
@MainActor
@Suite struct RefusedTapTests {
    /// A feed the test types the chord on.
    private final class Feed: ModifierFeed {
        var handle: (@MainActor (KeyEvent) -> Void)?

        func install(handling handle: @escaping @MainActor (KeyEvent) -> Void) throws -> Disposal {
            self.handle = handle
            return {}
        }
    }

    @MainActor private struct Loop {
        let rig: Rig
        let hotkey: Hotkey
        let feed: Feed

        init() async throws {
            rig = try await Rig(hearing: FakeTranscriber { _ in Transcript(typed: "a") })
            feed = Feed()
            hotkey = Hotkey(modes: Config.default.modes, feed: feed)
            try hotkey.start(feeding: rig.dictation)
        }

        /// Right Option going down or up, `ms` milliseconds after the rig's clock, which the loop's
        /// marks are on.
        func chord(_ direction: KeyEvent.Direction, atMilliseconds ms: Int64) {
            feed.handle?(KeyEvent(
                key: .rightOption, direction: direction, modifiers: direction == .down ? [.rightOption] : [],
                time: HostTime(uptime: rig.now.uptime + .milliseconds(ms)), lastTyped: HostTime(uptime: .seconds(-60))))
        }

        /// Lets the main queue run what the hotkey put on it, and what that put on it in turn.
        func delivered() async {
            for _ in 0..<2 {
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    /// The ticket's repro: the microphone will not open, the chord is tapped, and the person
    /// presses it again to try once more. That press begins one and what is said into it lands.
    @Test(.timeLimit(.minutes(1))) func aRefusedTapLatchesNothingSoTheNextPressListens() async throws {
        let loop = try await Loop()
        loop.rig.hardware.failingToLaunch = BadBuffer()

        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.chord(.up, atMilliseconds: 100)
        await loop.delivered()
        #expect(loop.hotkey.phase == .idle)
        #expect(await loop.rig.report().failure is NoMicrophone)

        loop.rig.hardware.failingToLaunch = nil
        loop.chord(.down, atMilliseconds: 1000)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        loop.chord(.up, atMilliseconds: 1500)
        await loop.delivered()

        #expect(try await loop.rig.session().transcription.transcript.text == "a")
        #expect(loop.rig.inputMethod.inserted == ["a"])
    }

    /// A refused press held to the end of the chord is what it was: the failure is reported and
    /// the next press begins a press.
    @Test(.timeLimit(.minutes(1))) func aRefusedHoldIsReportedAndTheNextPressListens() async throws {
        let loop = try await Loop()
        loop.rig.hardware.failingToLaunch = BadBuffer()

        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.chord(.up, atMilliseconds: 600)
        await loop.delivered()
        #expect(await loop.rig.report().failure is NoMicrophone)

        loop.rig.hardware.failingToLaunch = nil
        loop.chord(.down, atMilliseconds: 1000)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        loop.chord(.up, atMilliseconds: 1500)
        await loop.delivered()
        #expect(try await loop.rig.session().transcription.transcript.text == "a")
    }

    /// A press that was heard and tapped still latches: only a refusal changes what a tap does.
    @Test(.timeLimit(.minutes(1))) func aHeardTapStillLatches() async throws {
        let loop = try await Loop()

        loop.chord(.down, atMilliseconds: 0)
        await loop.delivered()
        loop.rig.speak([1, 2, 3])
        loop.chord(.up, atMilliseconds: 100)
        await loop.delivered()

        #expect(loop.hotkey.phase == .latched(Mode.dictation, since: Rig.origin))
    }
}
