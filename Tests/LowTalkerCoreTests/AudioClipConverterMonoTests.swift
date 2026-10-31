import AVFoundation
import LowTalkerCore
import Testing

/// The built-in microphone delivers one channel at 48 kHz, which the stereo fixture above
/// never exercises. The contract is that a mono device's buffers convert like any others.
@Suite struct AudioClipConverterMonoTests {
    static var mono: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)! }

    @Test(arguments: [480, 1_024, 4_096, 4_800])
    func aMonoBufferConvertsAtEveryDeviceBufferSize(frames: AVAudioFrameCount) throws {
        let converter = try AudioClip.Converter(from: Self.mono)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: Self.mono, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.1 }
        let samples = try converter.convert(buffer)
        #expect(samples.count > 0)
    }
}
