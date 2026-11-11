import AVFoundation
import CoreAudio
@testable import LowTalkerCore
import Synchronization
import Testing

/// The shape a device's IOProc hands over: what a device may offer when its microphone is
/// readied, and what each render's buffer list may be against that. Both are tables, so each
/// row is a test.
@Suite struct InputLayoutTests {
    /// What most devices name for stereo: their first two channels.
    static let stereo = StereoChannels.named(1, 2)

    /// A virtual format as a device presents one.
    static func stream(
        channels: UInt32,
        rate: Double = 48_000,
        interleaved: Bool = true,
        float: Bool = true,
        bits: UInt32 = 32,
        packed: Bool = true,
        id: AudioFormatID = kAudioFormatLinearPCM
    ) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = 0
        if float { flags |= kAudioFormatFlagIsFloat }
        if packed { flags |= kAudioFormatFlagIsPacked }
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        return AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: id,
            mFormatFlags: flags,
            mBytesPerPacket: interleaved ? 4 * channels : 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? 4 * channels : 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bits,
            mReserved: 0
        )
    }

    // MARK: what a device offers

    @Test(arguments: [
        ([stream(channels: 1)], [1]),
        ([stream(channels: 2)], [2]),
        ([stream(channels: 3)], [3]),
        ([stream(channels: 1), stream(channels: 2)], [1, 2]),
        // A non-interleaved stream of k channels is k buffers of one.
        ([stream(channels: 2, interleaved: false)], [1, 1]),
        ([stream(channels: 1), stream(channels: 2, interleaved: false)], [1, 1, 1]),
    ])
    func aFloatPackedInputIsAcceptedAsTheBuffersTheIOProcWillBeHanded(streams: [AudioStreamBasicDescription], buffers: [Int]) throws {
        let layout = try InputLayout.parse(streams, stereo: Self.stereo).get()
        #expect(layout.buffers == buffers)
        #expect(layout.channels == buffers.reduce(0, +))
        #expect(layout.sampleRate == 48_000)
    }

    @Test func eachHeardChannelIsFoundInItsBufferAndLane() throws {
        let layout = try InputLayout.parse([Self.stream(channels: 1), Self.stream(channels: 2)], stereo: .named(3, 1)).get()
        #expect(layout.heard == [InputLayout.Lane(buffer: 1, lane: 1), InputLayout.Lane(buffer: 0, lane: 0)])
    }

    @Test func noInputStreamIsRefused() {
        #expect(InputLayout.parse([], stereo: Self.stereo) == .failure(.noStream))
    }

    @Test func aStreamThatIsNotLinearPCMIsRefusedByName() {
        let id = kAudioFormatMPEG4AAC
        #expect(InputLayout.parse([Self.stream(channels: 1, id: id)], stereo: Self.stereo) == .failure(.notLinearPCM(formatID: id)))
    }

    @Test func aStreamThatIsNotThirtyTwoBitFloatIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, float: false, bits: 16)], stereo: Self.stereo) == .failure(.notFloat32(bits: 16)))
        #expect(InputLayout.parse([Self.stream(channels: 1, float: true, bits: 64)], stereo: Self.stereo) == .failure(.notFloat32(bits: 64)))
    }

    @Test func aStreamThatIsNotPackedIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, packed: false)], stereo: Self.stereo) == .failure(.notPacked))
    }

    @Test func aBigEndianStreamIsRefused() {
        var stream = Self.stream(channels: 1)
        stream.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(InputLayout.parse([stream], stereo: Self.stereo) == .failure(.bigEndian))
    }

    @Test func streamsAtDifferentRatesAreRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, rate: 48_000), Self.stream(channels: 1, rate: 44_100)], stereo: Self.stereo) == .failure(.mixedSampleRates(48_000, 44_100)))
    }

    @Test func aDeviceWithNoChannelsIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 0)], stereo: Self.stereo) == .failure(.noChannels))
    }

    // MARK: what a render hands over

    /// A buffer list in memory of its own, so a test can make the shapes a device should not:
    /// a size that is not whole frames, a size with no memory behind it, buffers of other widths.
    final class List {
        let pointer: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        /// `buffers`: each buffer's channel count and its sample count, the samples counting up.
        init(_ buffers: [(channels: Int, samples: Int)], bytes override: [Int: Int] = [:], nullData: Set<Int> = []) {
            pointer = AudioBufferList.allocate(maximumBuffers: buffers.count)
            var next: Float = 0
            for (index, buffer) in buffers.enumerated() {
                let memory = UnsafeMutablePointer<Float>.allocate(capacity: max(buffer.samples, 1))
                for i in 0..<buffer.samples { memory[i] = next; next += 1 }
                storage.append(memory)
                pointer[index] = AudioBuffer(
                    mNumberChannels: UInt32(buffer.channels),
                    mDataByteSize: UInt32(override[index] ?? buffer.samples * MemoryLayout<Float>.size),
                    mData: nullData.contains(index) ? nil : memory
                )
            }
        }

        var base: UnsafePointer<AudioBufferList> { UnsafePointer(pointer.unsafeMutablePointer) }

        deinit {
            storage.forEach { $0.deallocate() }
            free(pointer.unsafeMutablePointer)
        }
    }

    static let stereoAndMono = InputLayout(buffers: [2, 1], sampleRate: 48_000, stereo: stereo)

    @Test func aListOfTheShapeIsItsFramesPerChannel() {
        let list = List([(2, 8), (1, 4)])
        #expect(Self.stereoAndMono.verdict(of: list.base, capacity: 512) == .frames(4))
    }

    @Test func aCycleWithNoFramesIsEmptyAndNotAShapeFault() {
        let list = List([(2, 0), (1, 0)])
        #expect(Self.stereoAndMono.verdict(of: list.base, capacity: 512) == .empty)
    }

    @Test func moreFramesThanTheDeliveryWasSizedForIsOverlong() {
        let list = List([(2, 20), (1, 10)])
        #expect(Self.stereoAndMono.verdict(of: list.base, capacity: 8) == .overlong(frames: 10))
    }

    @Test func aDifferentNumberOfBuffersIsAShapeFault() {
        let list = List([(2, 8)])
        guard case .shape(let mismatch) = Self.stereoAndMono.verdict(of: list.base, capacity: 512) else {
            Issue.record("expected a shape fault")
            return
        }
        #expect(mismatch.expectedBuffers == 2)
        #expect(mismatch.gotBuffers == 1)
    }

    @Test func aBufferOfAnotherWidthIsAShapeFault() {
        let list = List([(2, 8), (2, 8)])
        guard case .shape(let mismatch) = Self.stereoAndMono.verdict(of: list.base, capacity: 512) else {
            Issue.record("expected a shape fault")
            return
        }
        #expect(mismatch.buffer == 1)
        #expect(mismatch.expectedChannels == 1)
        #expect(mismatch.gotChannels == 2)
    }

    @Test func buffersOfUnequalFramesAreAShapeFault() {
        let list = List([(2, 8), (1, 5)])
        guard case .shape(let mismatch) = Self.stereoAndMono.verdict(of: list.base, capacity: 512) else {
            Issue.record("expected a shape fault")
            return
        }
        #expect(mismatch.buffer == 1)
        #expect(mismatch.reason == .unequalFrames(before: 4))
        // The report says what differed: the channels match, so the frames are what it names.
        #expect(mismatch.description == "buffer 1 of 2 held 20 bytes, 5 frames where the buffers before it held 4")
    }

    @Test func aSizeThatIsNotWholeFramesIsAShapeFault() {
        // Two channels of four bytes make eight-byte frames; twelve is a frame and a half.
        let list = List([(2, 8), (1, 4)], bytes: [0: 12])
        guard case .shape(let mismatch) = Self.stereoAndMono.verdict(of: list.base, capacity: 512) else {
            Issue.record("expected a shape fault")
            return
        }
        #expect(mismatch.reason == .partialFrame)
    }

    @Test func aSizeWithNoMemoryBehindItIsAShapeFault() {
        let list = List([(2, 8), (1, 4)], nullData: [1])
        guard case .shape(let mismatch) = Self.stereoAndMono.verdict(of: list.base, capacity: 512) else {
            Issue.record("expected a shape fault")
            return
        }
        #expect(mismatch.reason == .noMemory)
    }

    // MARK: which channels a device is heard on

    @Test(arguments: [
        // A device of one or two channels is heard on all of them, whatever it names.
        (1, StereoChannels.named(1, 1), [1]),
        (2, .named(1, 2), [1, 2]),
        (2, .named(1, 1), [1, 2]),
        (2, .named(2, 2), [1, 2]),
        (1, .unpublished(-1), [1]),
        (2, .unpublished(-1), [1, 2]),
        // An audio interface or a loopback is heard on the channels it names, and no other.
        (16, .named(1, 2), [1, 2]),
        (16, .named(3, 4), [3, 4]),
        (16, .named(5, 5), [5]),
        // A wider device that names a channel it lacks, or none at all, is heard on its first two.
        (16, .named(0, 0), [1, 2]),
        (16, .named(3, 17), [1, 2]),
        (16, .unpublished(-1), [1, 2]),
    ])
    func aDeviceIsHeardOnTheChannelsItNamesForStereo(count: Int, stereo: StereoChannels, heard: [Int]) {
        #expect(HeardChannels(of: count, stereo: stereo).channels == heard)
    }

    /// The record says which channels are heard, and why when they are not the ones named.
    @Test func theRecordSaysWhichChannelsAreHeardAndWhy() {
        #expect(HeardChannels(of: 1, stereo: .named(1, 1)).description == "heard on channel 1")
        #expect(HeardChannels(of: 2, stereo: .unpublished(-1)).description == "heard on channels 1 and 2")
        #expect(HeardChannels(of: 16, stereo: .named(2, 1)).description == "heard on channels 2 and 1")
        #expect(HeardChannels(of: 16, stereo: .named(0, 0)).description == "heard on channels 1 and 2, its first: it names channels 0 and 0 for stereo")
        #expect(HeardChannels(of: 16, stereo: .unpublished(-1)).description == "heard on channels 1 and 2, its first: it names no channels for stereo (status -1)")
    }

    /// The pair is watched where naming another would change what is heard: a wider device that
    /// names one, in range or not.
    @Test(arguments: [
        (2, StereoChannels.named(1, 2), false),
        (2, .unpublished(-1), false),
        (16, .named(3, 4), true),
        (16, .named(0, 0), true),
        (16, .unpublished(-1), false),
    ])
    func thePairIsWatchedWhereItDecidesWhatIsHeard(count: Int, stereo: StereoChannels, watched: Bool) {
        #expect(HeardChannels(of: count, stereo: stereo).followsStereo == watched)
    }

    // MARK: how a render becomes the ring's planar samples

    /// The next slice of `ring`, one array per channel it holds.
    static func popped(_ ring: SliceRing, layout: InputLayout, frames: Int) throws -> [[Float]] {
        let popped = AVAudioPCMBuffer(pcmFormat: try #require(layout.format), frameCapacity: AVAudioFrameCount(frames))!
        _ = ring.pop(into: popped)
        return (0..<Int(popped.format.channelCount)).map { Array(UnsafeBufferPointer(start: popped.floatChannelData![$0], count: Int(popped.frameLength))) }
    }

    /// A render of `layout` whose channel `channel`, numbered from 1, holds `value(channel, frame)`.
    static func push(_ ring: SliceRing, layout: InputLayout, frames: Int, _ value: (Int, Int) -> Float) {
        let list = List(layout.buffers.map { ($0, $0 * frames) })
        var first = 1
        for (index, width) in layout.buffers.enumerated() {
            for frame in 0..<frames {
                for lane in 0..<width {
                    list.pointer[index].mData!.assumingMemoryBound(to: Float.self)[frame * width + lane] = value(first + lane, frame)
                }
            }
            first += width
        }
        ring.push(list.base, layout: layout, frames: frames, stamp: AudioTimeStamp())
    }

    @Test func anInterleavedBufferIsDeinterleavedIntoOneRingPerChannel() throws {
        let layout = InputLayout(buffers: [2], sampleRate: 48_000, stereo: Self.stereo)
        let ring = SliceRing(channels: 2, frames: 8, entries: 4)
        // Left counts up from 0, right from 100.
        Self.push(ring, layout: layout, frames: 3) { channel, frame in Float(100 * (channel - 1) + frame) }
        #expect(try Self.popped(ring, layout: layout, frames: 8) == [[0, 1, 2], [100, 101, 102]])
    }

    /// Only the heard channels reach the ring, wherever they lie: here the second lane of an
    /// interleaved buffer and a mono buffer after it, with the first channel left out, across the
    /// wrap.
    @Test func theHeardChannelsLandInTheirRingsAcrossTheWrapAndNoOther() throws {
        let layout = InputLayout(buffers: [2, 1], sampleRate: 48_000, stereo: .named(2, 3))
        let ring = SliceRing(channels: 2, frames: 5, entries: 8)
        // Four frames, then four more: the second wraps the five-frame ring.
        for round in 0..<2 {
            Self.push(ring, layout: layout, frames: 4) { channel, frame in Float(100 * channel + round * 4 + frame) }
            let expected = (0..<4).map { Float(round * 4 + $0) }
            #expect(try Self.popped(ring, layout: layout, frames: 5) == [expected.map { $0 + 200 }, expected.map { $0 + 300 }])
        }
    }

    /// A device of any channel count is heard, an audio interface or a 16-channel loopback
    /// included: what it pops as is a shape AVAudioFormat describes and the converter reads, and
    /// the converter hands back the mean of its heard channels, as it mixes any stereo input, not
    /// silence, and none of what its other channels carry. Each channel carries its own level, so
    /// hearing one channel of a pair, or one channel twice, reads as a different level.
    @Test(arguments: [
        (1, StereoChannels.named(1, 1), Float(0.5)),
        (2, .named(1, 1), 0.375),
        (3, .named(1, 2), 0.375),
        (4, .named(1, 2), 0.375),
        (16, .named(1, 2), 0.375),
        (16, .named(3, 4), 0.1458),
    ])
    func aDeviceOfAnyChannelCountIsHeardAsTheMeanOfItsHeardChannels(channels: Int, stereo: StereoChannels, level: Float) throws {
        let layout = InputLayout(buffers: [channels], sampleRate: 48_000, stereo: stereo)
        let ring = SliceRing(channels: layout.heard.count, frames: 4_800, entries: 4)
        Self.push(ring, layout: layout, frames: 4_800) { channel, _ in 0.5 / Float(channel) }
        let popped = AVAudioPCMBuffer(pcmFormat: try #require(layout.format), frameCapacity: 4_800)!
        _ = ring.pop(into: popped)
        let converted = try AudioClip.Converter(from: popped.format).convert(popped)
        // Past the resampler's onset, where a step from nothing rings.
        let settled = converted.dropFirst(converted.count / 2)
        #expect(settled.allSatisfy { abs($0 - level) < 0.01 }, "\(settled.min() ?? 0)...\(settled.max() ?? 0)")
    }

    // MARK: what a fault means for the input

    @Test func aShapeThatChangedUnderAPressReplacesTheInput() {
        let shape = ShapeMismatch(reason: .bufferCount, expectedBuffers: 1, gotBuffers: 2, buffer: 0, expectedChannels: 0, gotChannels: 0, gotBytes: 0)
        #expect(HALInput.route(of: AudioHardwareError.inputShapeChanged(shape)) == .replaceInput)
    }

    @Test func everyOtherFaultFailsThePress() {
        let shape = ShapeMismatch(reason: .bufferCount, expectedBuffers: 1, gotBuffers: 2, buffer: 0, expectedChannels: 0, gotChannels: 0, gotBytes: 0)
        // A shape that never matched would be replaced into the same mismatch.
        #expect(HALInput.route(of: AudioHardwareError.shapeNeverMatched(shape)) == .failPress)
        #expect(HALInput.route(of: AudioHardwareError.overlongSlice(frames: 2, capacity: 1)) == .failPress)
        #expect(HALInput.route(of: AudioHardwareError.deliveryFellBehind(dropped: 1)) == .failPress)
        #expect(HALInput.route(of: AudioHardwareError.bufferWithoutTime) == .failPress)
        #expect(HALInput.route(of: CancellationError()) == .failPress)
    }
}
