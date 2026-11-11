import AVFoundation
import CoreAudio
@testable import LowTalkerCore
import Synchronization
import Testing

/// The shape a device's IOProc hands over: what a device may offer when its microphone is
/// readied, and what each render's buffer list may be against that. Both are tables, so each
/// row is a test.
@Suite struct InputLayoutTests {
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
        let layout = try InputLayout.parse(streams).get()
        #expect(layout.buffers == buffers)
        #expect(layout.channels == buffers.reduce(0, +))
        #expect(layout.sampleRate == 48_000)
    }

    @Test func eachBuffersFirstChannelIsWhereTheRingTakesIt() throws {
        let layout = try InputLayout.parse([Self.stream(channels: 1), Self.stream(channels: 2)]).get()
        #expect(layout.offsets == [0, 1])
    }

    @Test func noInputStreamIsRefused() {
        #expect(InputLayout.parse([]) == .failure(.noStream))
    }

    @Test func aStreamThatIsNotLinearPCMIsRefusedByName() {
        let id = kAudioFormatMPEG4AAC
        #expect(InputLayout.parse([Self.stream(channels: 1, id: id)]) == .failure(.notLinearPCM(formatID: id)))
    }

    @Test func aStreamThatIsNotThirtyTwoBitFloatIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, float: false, bits: 16)]) == .failure(.notFloat32(bits: 16)))
        #expect(InputLayout.parse([Self.stream(channels: 1, float: true, bits: 64)]) == .failure(.notFloat32(bits: 64)))
    }

    @Test func aStreamThatIsNotPackedIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, packed: false)]) == .failure(.notPacked))
    }

    @Test func aBigEndianStreamIsRefused() {
        var stream = Self.stream(channels: 1)
        stream.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(InputLayout.parse([stream]) == .failure(.bigEndian))
    }

    @Test func streamsAtDifferentRatesAreRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 1, rate: 48_000), Self.stream(channels: 1, rate: 44_100)]) == .failure(.mixedSampleRates(48_000, 44_100)))
    }

    @Test func aDeviceWithNoChannelsIsRefused() {
        #expect(InputLayout.parse([Self.stream(channels: 0)]) == .failure(.noChannels))
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

    static let stereoAndMono = InputLayout(buffers: [2, 1], sampleRate: 48_000)

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

    // MARK: how a render becomes the one channel the pipeline hears

    /// The next slice of `ring`, as the one channel it pops as.
    static func popped(_ ring: SliceRing, frames: Int) -> [Float] {
        let popped = AVAudioPCMBuffer(pcmFormat: SliceRing.format(sampleRate: 48_000)!, frameCapacity: AVAudioFrameCount(frames))!
        _ = ring.pop(into: popped)
        return Array(UnsafeBufferPointer(start: popped.floatChannelData![0], count: Int(popped.frameLength)))
    }

    @Test func anInterleavedBufferPopsAsTheMeanOfItsChannels() throws {
        let layout = InputLayout(buffers: [2], sampleRate: 48_000)
        let ring = SliceRing(channels: 2, frames: 8, entries: 4)
        // Frames (0, 100), (1, 101), (2, 102): left counts up from 0, right from 100.
        let list = List([(2, 6)])
        for frame in 0..<3 {
            list.pointer[0].mData!.assumingMemoryBound(to: Float.self)[frame * 2] = Float(frame)
            list.pointer[0].mData!.assumingMemoryBound(to: Float.self)[frame * 2 + 1] = Float(100 + frame)
        }
        ring.push(list.base, layout: layout, frames: 3, stamp: AudioTimeStamp())
        #expect(Self.popped(ring, frames: 8) == [50, 51, 52])
    }

    @Test func twoBuffersOfDifferentWidthsPopAsTheMeanOfEveryChannelAcrossTheWrap() throws {
        // Buffer 0 is stereo interleaved, buffer 1 mono: channels 0 and 1, then 2.
        let layout = InputLayout(buffers: [2, 1], sampleRate: 48_000)
        let ring = SliceRing(channels: 3, frames: 5, entries: 8)
        // Four frames, then four more: the second wraps the five-frame ring.
        for round in 0..<2 {
            let list = List([(2, 8), (1, 4)])
            for frame in 0..<4 {
                let value = Float(round * 4 + frame)
                list.pointer[0].mData!.assumingMemoryBound(to: Float.self)[frame * 2] = value
                list.pointer[0].mData!.assumingMemoryBound(to: Float.self)[frame * 2 + 1] = value + 30
                list.pointer[1].mData!.assumingMemoryBound(to: Float.self)[frame] = value + 60
            }
            ring.push(list.base, layout: layout, frames: 4, stamp: AudioTimeStamp())
            #expect(Self.popped(ring, frames: 5) == (0..<4).map { Float(round * 4 + $0) + 30 })
        }
    }

    /// A device of any channel count is heard, an audio interface or a 16-channel loopback with
    /// the voice on its last channel included: what it pops as is a shape the converter reads,
    /// carrying that channel at its share of the mix.
    @Test(arguments: [1, 2, 3, 4, 16])
    func everyChannelCountIsHeardOnItsLastChannel(channels: Int) throws {
        let layout = InputLayout(buffers: [channels], sampleRate: 48_000)
        let ring = SliceRing(channels: channels, frames: 8, entries: 4)
        let list = List([(channels, 4 * channels)])
        for frame in 0..<4 {
            for channel in 0..<channels {
                list.pointer[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + channel] = channel == channels - 1 ? Float(channels) : 0
            }
        }
        ring.push(list.base, layout: layout, frames: 4, stamp: AudioTimeStamp())
        #expect(Self.popped(ring, frames: 8) == [1, 1, 1, 1])
        _ = try AudioClip.Converter(from: try #require(SliceRing.format(sampleRate: layout.sampleRate)))
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
