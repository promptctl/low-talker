import CoreAudio
import Foundation
@testable import LowTalkerCore
import Testing

// Throwaway diagnostic for the macos-26 runner: how long a listener removal on a destroyed
// aggregate takes with the main thread free and with it blocked.
@Suite(.serialized) struct RemovalDiagnosticTests {
    static let alive = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func makeAggregate() -> AudioObjectID {
        let description = [
            kAudioAggregateDeviceUIDKey: "diag-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
        ] as CFDictionary
        var aggregate = AudioObjectID(0)
        let t0 = Date()
        let status = AudioHardwareCreateAggregateDevice(description, &aggregate)
        print("DIAG create status=\(status) took=\(Date().timeIntervalSince(t0))")
        return aggregate
    }

    static func run(_ label: String, sleep: Double) -> Double {
        let aggregate = makeAggregate()
        let remove = try! listen(to: alive, on: aggregate, refused: AudioHardwareError.deviceWatchFailed) {}
        let t0 = Date()
        let destroyed = AudioHardwareDestroyAggregateDevice(aggregate)
        print("DIAG \(label) destroy status=\(destroyed) took=\(Date().timeIntervalSince(t0))")
        Thread.sleep(forTimeInterval: sleep)
        let removed = DispatchSemaphore(value: 0)
        let t1 = Date()
        DispatchQueue.global().async { _ = remove(); removed.signal() }
        let result = removed.wait(timeout: .now() + 60)
        let took = Date().timeIntervalSince(t1)
        print("DIAG \(label) sleep=\(sleep) removal=\(result) took=\(took)")
        return took
    }

    @Test func mainFree() async {
        for sleep in [0.5, 0.0, 3.0] {
            await withCheckedContinuation { done in
                Thread.detachNewThread { _ = Self.run("mainFree", sleep: sleep); done.resume() }
            }
        }
    }

    @MainActor @Test func mainBlocked() {
        for sleep in [0.5, 0.0, 3.0] { _ = Self.run("mainBlocked", sleep: sleep) }
    }
}
