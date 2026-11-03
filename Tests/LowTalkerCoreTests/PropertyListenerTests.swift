import CoreAudio
import Foundation
import Synchronization
@testable import LowTalkerCore
import TestProbes
import Testing

/// Each change here is a private aggregate device made or destroyed, which moves the
/// system's device list without touching any device the Mac uses: no microphone is needed,
/// and nothing is left changed.
///
/// Every CoreAudio call here is made on a thread of its own, never on the main thread. The
/// first starts the HAL, which loads every plug-in bundle, and on the 3-core CI runner that held
/// the main thread for seconds - long enough to fail every timed wait in the suites running
/// beside it (low-unfiled-50ff.cis). And a main thread inside CoreAudio while another thread is
/// in it too is the one arrangement here that can wait on itself: a CI run of this suite froze
/// with both tests under way. Serialized, so the two never call CoreAudio at once.
@MainActor @Suite(.serialized) struct PropertyListenerTests {
    /// No status can show a removal happened, since one that matched nothing answers `noErr`
    /// too. So the test is a change a removed and a live listener could both hear, and only
    /// the live one does.
    ///
    /// Both listeners reach the main queue in the order CoreAudio delivers to them. So by
    /// the time the live one has heard the second change, a removed one still registered
    /// would have heard the first. The device is destroyed only once its making is heard,
    /// so the two changes cannot arrive as one.
    @Test(.timeLimit(.minutes(1))) func aRemovedListenerHearsNoLaterChange() async throws {
        let heard = Count()
        let remove = try await onAThreadOfItsOwn { try listen(to: Self.devices, on: Self.system, refused: AudioHardwareError.deviceWatchFailed) { heard.value += 1 } }
        #expect(await onAThreadOfItsOwn { remove() } == noErr)
        // A change CoreAudio delivered before the removal can still land after it, and by the
        // end of this turn of the main queue it has.
        await withCheckedContinuation { turned in DispatchQueue.main.async { turned.resume() } }
        let heardBeforeRemoval = heard.value

        let (changes, change) = AsyncStream.makeStream(of: Void.self)
        let removeLive = try await onAThreadOfItsOwn { try listen(to: Self.devices, on: Self.system, refused: AudioHardwareError.deviceWatchFailed) { change.yield() } }
        var heardLive = changes.makeAsyncIterator()
        do {
            let aggregate = try await onAThreadOfItsOwn { try Self.makeAggregate() }
            _ = await heardLive.next()
            try #require(await onAThreadOfItsOwn { AudioHardwareDestroyAggregateDevice(aggregate) } == noErr)
            _ = await heardLive.next()
        } catch {
            // Removed on the way out too, so a failure leaves no listener behind.
            _ = await onAThreadOfItsOwn { removeLive() }
            throw error
        }
        _ = await onAThreadOfItsOwn { removeLive() }
        #expect(heard.value == heardBeforeRemoval)
    }

    /// A device being torn down calls its listeners synchronously on the queue they were
    /// added with, and a removal waits out that call. Here the main thread serves nothing
    /// while the device goes and while the removal runs, as it does when it waits on the
    /// readying queue for an input that queue is letting go of. Delivered on the main queue,
    /// this removal never returned.
    @Test func aRemovalWaitsOnNothingTheMainThreadDoes() async throws {
        let aggregate = try await onAThreadOfItsOwn { try Self.makeAggregate() }
        let alive = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let remove = try await onAThreadOfItsOwn { try listen(to: alive, on: aggregate, refused: AudioHardwareError.deviceWatchFailed) {} }
        try Self.destroyAndRemoveHoldingMain(aggregate, remove)
    }

    /// The part that holds the main thread. The main thread serves nothing here, which is what
    /// is measured, but it is never inside CoreAudio: it waits while threads of their own call it.
    private static func destroyAndRemoveHoldingMain(_ aggregate: AudioObjectID, _ remove: @escaping @Sendable () -> OSStatus) throws {
        let destroyed = DispatchSemaphore(value: 0)
        let status = Mutex(noErr)
        Thread.detachNewThread {
            status.withLock { $0 = AudioHardwareDestroyAggregateDevice(aggregate) }
            destroyed.signal()
        }
        // The listener is removed however the destroy ends, so a failed test leaves none behind.
        // On a thread of its own: with the main thread held, a global queue's block waited 8.3 s
        // to start on the 3-core CI runner under the full suite (the removal took 1.3 ms).
        defer {
            let removed = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = remove()
                removed.signal()
            }
            #expect(removed.wait(timeout: .now() + 5) == .success)
        }
        try #require(destroyed.wait(timeout: .now() + 5) == .success)
        try #require(status.withLock { $0 } == noErr)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// What a listener on the main actor has heard.
    @MainActor private final class Count {
        var value = 0
    }

    private nonisolated static let system = AudioObjectID(kAudioObjectSystemObject)

    private nonisolated static let devices = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private nonisolated static func makeAggregate() throws -> AudioObjectID {
        let description = [
            kAudioAggregateDeviceUIDKey: "low-audio-fr3-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
        ] as CFDictionary
        var aggregate = AudioObjectID(0)
        try #require(AudioHardwareCreateAggregateDevice(description, &aggregate) == noErr)
        return aggregate
    }
}
