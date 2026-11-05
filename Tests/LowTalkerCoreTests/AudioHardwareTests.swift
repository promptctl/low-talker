import AVFoundation
@testable import LowTalkerCore
import Testing

@Suite struct AudioHardwareTests {
    /// A CoreAudio stamp counts the machine's raw ticks, so 1.5 s of them comes back as
    /// 1.5 s - which catches reading them as nanoseconds only where the timebase makes
    /// the two differ, since where it is 1:1 they are the same arithmetic. Built with
    /// `hostTime(forSeconds:)`; 1.5 round-trips exactly, where most literals do not.
    @Test func aStampInHostTicksBecomesTheSecondsItStandsFor() throws {
        let parsed = try HostTime(AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.5)))
        #expect(parsed.uptime == .seconds(1.5))
    }

    /// AVFoundation may hand out a time placed only among samples. Nothing can say when
    /// those were captured, so the buffer fails the engine rather than being guessed at.
    @Test func aTimeWithNoHostClockBehindItIsRefused() {
        let placedOnlyAmongSamples = AVAudioTime(sampleTime: 4410, atRate: 44100)
        #expect(throws: AudioHardwareError.bufferWithoutTime) { try HostTime(placedOnlyAmongSamples) }
    }

    /// The IOProc is handed a raw stamp rather than an `AVAudioTime`, and it
    /// reads the same ticks the same way.
    @Test func aRenderStampInHostTicksBecomesTheSecondsItStandsFor() throws {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = AVAudioTime.hostTime(forSeconds: 1.5)
        stamp.mFlags = .hostTimeValid
        #expect(try HostTime(stamp).uptime == .seconds(1.5))
    }

    /// A stamp carries its host time in a field that is populated whether or not a host
    /// clock stood behind it; only the flag says which. Here the field holds a usable
    /// 1.5 s and the stamp is still refused, which is what makes the flag the authority.
    @Test func aRenderStampFlaggedWithoutAHostClockIsRefused() {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = AVAudioTime.hostTime(forSeconds: 1.5)
        stamp.mFlags = .sampleTimeValid
        #expect(throws: AudioHardwareError.bufferWithoutTime) { try HostTime(stamp) }
    }
}
