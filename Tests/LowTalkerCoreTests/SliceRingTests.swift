import AVFoundation
import CoreAudio
@testable import LowTalkerCore
import Synchronization
import Testing

/// The way a render's audio leaves CoreAudio's IO thread: pushed into a ring without waiting,
/// popped and handed over by a thread that may wait. The contract is that every slice arrives
/// once, in order, with its own samples and stamp, and that one the ring had no room for is
/// counted and reported rather than lost quietly.
@Suite struct SliceRingTests {
    /// Computed, not stored: the macOS 15 SDK does not mark AVAudioFormat Sendable. The
    /// pipeline's own format, so the converter hands the samples back as they went in.
    static var format: AVAudioFormat { AudioClip.format }

    /// `frames` frames counting up from `first`, one channel.
    static func slice(from first: Int, frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(first + i) }
        return buffer
    }

    /// One channel, one buffer: what `slice` builds.
    static let mono = InputLayout(buffers: [1], sampleRate: 16_000)

    static func stamp(_ ticks: UInt64, valid: Bool = true) -> AudioTimeStamp {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = ticks
        stamp.mFlags = valid ? .hostTimeValid : []
        return stamp
    }

    static func push(_ ring: SliceRing, from first: Int, frames: Int, at ticks: UInt64) {
        let buffer = slice(from: first, frames: frames)
        // The list points into the buffer, which ARC may release after its last use.
        withExtendedLifetime(buffer) {
            ring.push(buffer.audioBufferList, layout: mono, frames: frames, stamp: stamp(ticks))
        }
    }

    static func deliver(_ delivery: SliceDelivery, from first: Int, frames: Int, at stamp: AudioTimeStamp) {
        let buffer = slice(from: first, frames: frames)
        withExtendedLifetime(buffer) {
            delivery.deliver(buffer.audioBufferList, stamp: stamp)
        }
    }

    /// The next entry as a slice's stamp and samples, or nil when it is anything else.
    static func popSlice(_ ring: SliceRing, into buffer: AVAudioPCMBuffer) -> (ticks: UInt64, samples: [Float])? {
        guard case .slice(let frames, let stamp) = ring.pop(into: buffer) else { return nil }
        #expect(frames == Int(buffer.frameLength))
        return (stamp.mHostTime, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frames)))
    }

    /// Slices come out in the order they went in, each with its own frames and stamp, and
    /// the frames that wrap past the end of the ring come out whole.
    @Test func slicesPopInOrderAcrossTheWrap() throws {
        let ring = SliceRing(channels: 1, frames: 100, entries: 4)
        let popped = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 100)!
        var first = 0
        for round in 0..<5 {
            Self.push(ring, from: first, frames: 30, at: UInt64(round))
            Self.push(ring, from: first + 30, frames: 40, at: UInt64(round) + 100)
            for (offset, frames, ticks) in [(0, 30, UInt64(round)), (30, 40, UInt64(round) + 100)] {
                let slice = try #require(Self.popSlice(ring, into: popped))
                #expect(slice.ticks == ticks)
                #expect(slice.samples == (first + offset..<first + offset + frames).map(Float.init))
            }
            first += 70
        }
        #expect(ring.pop(into: popped) == nil)
        #expect(ring.dropped == 0)
    }

    /// A push that finds no room drops its slice and counts it, and the slices already in the
    /// ring are untouched - by a full ring of frames, and by a full ring of entries.
    @Test func aFullRingDropsAndCounts() throws {
        let ring = SliceRing(channels: 1, frames: 100, entries: 2)
        let popped = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 100)!
        Self.push(ring, from: 0, frames: 60, at: 1)
        Self.push(ring, from: 60, frames: 60, at: 2)  // 120 frames will not fit in 100.
        Self.push(ring, from: 120, frames: 40, at: 3)
        Self.push(ring, from: 160, frames: 1, at: 4)  // Both entries are taken.
        // A fault the ring had no room for says so, which is what lets a delivery try it again.
        #expect(ring.push(.overlongSlice(frames: 1, capacity: 1)) == false)
        #expect(ring.dropped == 3)
        let first = try #require(Self.popSlice(ring, into: popped))
        #expect(first.ticks == 1)
        #expect(first.samples == (0..<60).map(Float.init))
        let second = try #require(Self.popSlice(ring, into: popped))
        #expect(second.ticks == 3)
        #expect(second.samples == (120..<160).map(Float.init))
        #expect(ring.pop(into: popped) == nil)
    }

    /// A fault takes its place in the order the IO thread met it.
    @Test func faultsKeepTheirPlace() throws {
        let ring = SliceRing(channels: 1, frames: 100, entries: 4)
        let popped = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 100)!
        Self.push(ring, from: 0, frames: 10, at: 1)
        ring.push(.overlongSlice(frames: 200, capacity: 100))
        Self.push(ring, from: 10, frames: 10, at: 2)
        #expect(try #require(Self.popSlice(ring, into: popped)).ticks == 1)
        #expect(ring.pop(into: popped) == .fault(.overlongSlice(frames: 200, capacity: 100)))
        let last = try #require(Self.popSlice(ring, into: popped))
        #expect(last.ticks == 2)
        #expect(last.samples == (10..<20).map(Float.init))
    }

    /// What a delivery hands over and reports, collected from its thread.
    final class Collected: Sendable {
        let appended = Mutex<[([Float], HostTime)]>([])
        let failures = Mutex<[String]>([])

        func delivery(_ ring: SliceRing, slice: Int, layout: InputLayout = SliceRingTests.mono) throws -> SliceDelivery {
            try SliceDelivery(
                ring,
                layout: layout,
                slice: slice,
                format: SliceRingTests.format,
                converter: AudioClip.Converter(from: SliceRingTests.format),
                appending: { samples, time in self.appended.withLock { $0.append((samples, time)) } },
                onFailure: { error in self.failures.withLock { $0.append("\(error)") } }
            )
        }
    }

    /// Slices pushed from another thread are converted and handed over in order, dated by
    /// their stamps, and `finish` returns only once the last of them has been.
    @Test func deliveryHandsOverEverySliceBeforeFinishing() throws {
        let collected = Collected()
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 16_000, entries: 64), slice: 160)
        let produced = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for index in 0..<50 {
                Self.deliver(delivery, from: index * 160, frames: 160, at: Self.stamp(UInt64(1_000 + index)))
            }
            produced.signal()
        }
        produced.wait()
        delivery.finish()

        let appended = collected.appended.withLock { $0 }
        #expect(collected.failures.withLock { $0 } == [])
        #expect(appended.map(\.1) == (0..<50).map { try! HostTime(Self.stamp(UInt64(1_000 + $0))) })
        let samples = appended.flatMap(\.0)
        #expect(samples == (0..<50 * 160).map(Float.init))
    }

    /// A device whose buffers never were the shape it was readied under says so as such, once,
    /// whatever follows: replacing its input would read the same properties and mismatch again.
    @Test func aShapeThatNeverMatchedIsReportedOnceAsThat() throws {
        let collected = Collected()
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 1_000, entries: 8), slice: 100)
        let wrong = InputLayoutTests.List([(2, 20)])
        delivery.deliver(wrong.base, stamp: Self.stamp(1))
        delivery.deliver(wrong.base, stamp: Self.stamp(2))
        // A list of the right shape after the fault is not heard either: the press is failed.
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(3))
        delivery.finish()

        let mismatch = ShapeMismatch(reason: .channels, expectedBuffers: 1, gotBuffers: 1, buffer: 0, expectedChannels: 1, gotChannels: 2, gotBytes: 80)
        #expect(collected.failures.withLock { $0 } == ["\(AudioHardwareError.shapeNeverMatched(mismatch))"])
        #expect(collected.appended.withLock { $0 }.isEmpty)
    }

    /// A shape that changed after slices of it were heard is the other fault: the device
    /// renegotiated under the press, and a replacement is the answer.
    @Test func aShapeThatChangedAfterItMatchedIsReportedOnceAsThat() throws {
        let collected = Collected()
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 1_000, entries: 8), slice: 100)
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(1))
        let wrong = InputLayoutTests.List([(2, 20)])
        delivery.deliver(wrong.base, stamp: Self.stamp(2))
        delivery.deliver(wrong.base, stamp: Self.stamp(3))
        delivery.finish()

        let mismatch = ShapeMismatch(reason: .channels, expectedBuffers: 1, gotBuffers: 1, buffer: 0, expectedChannels: 1, gotChannels: 2, gotBytes: 80)
        #expect(collected.failures.withLock { $0 } == ["\(AudioHardwareError.inputShapeChanged(mismatch))"])
        #expect(collected.appended.withLock { $0 }.flatMap(\.0) == (0..<10).map(Float.init))
    }

    /// An oversized render fails the press, and a device whose buffers stay oversized does not
    /// push a fault, and ring the delivery thread, on every cycle after it.
    @Test func anOverlongRenderIsReportedOnce() throws {
        let collected = Collected()
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 1_000, entries: 8), slice: 100)
        for index in 0..<5 {
            Self.deliver(delivery, from: 0, frames: 200, at: Self.stamp(UInt64(index + 1)))
        }
        delivery.finish()

        #expect(collected.failures.withLock { $0 } == ["\(AudioHardwareError.overlongSlice(frames: 200, capacity: 100))"])
        #expect(collected.appended.withLock { $0 }.isEmpty)
    }

    /// A fault the ring had no room for is not reported, so it is tried again, and once there
    /// is room it is reported exactly once: a press must not go silent over a fault dropped
    /// from a full ring.
    @Test func aFaultTheRingHadNoRoomForIsReportedOnceThereIsRoom() throws {
        final class Held: Sendable {
            let heard = Mutex(0)
            let failures = Mutex<[String]>([])
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
        }
        let held = Held()
        let delivery = try SliceDelivery(
            SliceRing(channels: 1, frames: 1_000, entries: 2),
            layout: Self.mono,
            slice: 100,
            format: Self.format,
            converter: AudioClip.Converter(from: Self.format),
            appending: { _, _ in
                // The first slice holds the delivery thread, so the ring's two entries fill behind it.
                if held.heard.withLock({ $0 += 1; return $0 }) == 1 {
                    held.entered.signal()
                    held.release.wait()
                }
            },
            onFailure: { error in held.failures.withLock { $0.append("\(error)") } }
        )
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(1))
        held.entered.wait()
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(2))
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(3))
        Self.deliver(delivery, from: 0, frames: 200, at: Self.stamp(4))
        Self.deliver(delivery, from: 0, frames: 200, at: Self.stamp(5))
        held.release.signal()
        // Slices 2 and 3 leave the ring as the thread takes them, which is the room the fault needs.
        let deadline = ContinuousClock.now + .seconds(5)
        while held.heard.withLock({ $0 }) < 3, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        Self.deliver(delivery, from: 0, frames: 200, at: Self.stamp(6))
        Self.deliver(delivery, from: 0, frames: 200, at: Self.stamp(7))
        delivery.finish()

        let overlong = "\(AudioHardwareError.overlongSlice(frames: 200, capacity: 100))"
        #expect(held.failures.withLock { $0 }.filter { $0 == overlong }.count == 1)
    }

    /// A cycle of no frames is a device's to deliver and is neither heard nor a fault.
    @Test func aCycleOfNoFramesIsNotAFault() throws {
        let collected = Collected()
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 1_000, entries: 8), slice: 100)
        let empty = InputLayoutTests.List([(1, 0)])
        delivery.deliver(empty.base, stamp: Self.stamp(1))
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(2))
        delivery.deliver(empty.base, stamp: Self.stamp(3))
        delivery.finish()

        #expect(collected.failures.withLock { $0 } == [])
        #expect(collected.appended.withLock { $0 }.flatMap(\.0) == (0..<10).map(Float.init))
    }

    /// A slice whose stamp has no host time behind it cannot be placed, and says so; a render
    /// larger than the delivery was sized for is reported as itself; and audio the ring had no
    /// room for is reported as lost.
    @Test func deliveryReportsWhatItCouldNotHandOver() throws {
        let collected = Collected()
        // A ring of 50 frames under slices of up to 100: a slice of 60 is within what the
        // delivery was sized for and more than the ring can hold, so it is dropped however far
        // the thread has got.
        let delivery = try collected.delivery(SliceRing(channels: 1, frames: 50, entries: 8), slice: 100)
        Self.deliver(delivery, from: 0, frames: 10, at: Self.stamp(5, valid: false))
        Self.deliver(delivery, from: 0, frames: 60, at: Self.stamp(6))
        // Last: an oversized render fails the press, and nothing after it is delivered.
        Self.deliver(delivery, from: 0, frames: 150, at: Self.stamp(7))
        delivery.finish()

        #expect(collected.appended.withLock { $0 }.isEmpty)
        let failures = collected.failures.withLock { $0 }
        // As a set: a drop is reported at the end of whichever drain first sees it, which can
        // come before the entry pushed just ahead of it.
        #expect(failures.count == 3)
        #expect(Set(failures) == [
            "\(AudioHardwareError.bufferWithoutTime)",
            "\(AudioHardwareError.overlongSlice(frames: 150, capacity: 100))",
            "\(AudioHardwareError.deliveryFellBehind(dropped: 1))",
        ])
    }
}

extension SliceRing.Entry: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.slice(let a, let x), .slice(let b, let y)): a == b && x.mHostTime == y.mHostTime
        case (.fault(let a), .fault(let b)): a == b
        default: false
        }
    }
}
