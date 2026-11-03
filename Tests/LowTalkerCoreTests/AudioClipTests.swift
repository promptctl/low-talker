import Foundation
import LowTalkerCore
import Testing

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
}

/// Both fixtures are the same utterance rendered by `say`, then encoded at 16 kHz
/// mono and at 44.1 kHz stereo. The contract under test is that the source encoding
/// is invisible past the load boundary: same speech, same clip.
@Suite struct AudioClipTests {
    static let fixtureDuration: TimeInterval = 2.2585

    @Test(arguments: ["hello-16k-mono", "hello-44k-stereo"])
    func loadsAnyEncodingAsSixteenKilohertzMono(name: String) throws {
        let clip = try AudioClip(contentsOf: fixture(name))
        #expect(abs(clip.duration - Self.fixtureDuration) < 0.01)
        #expect(clip.peak > 0.05, "fixture should contain speech, not silence")
    }

    /// A file longer than the reader will take is refused by the length its header gives,
    /// and one no longer loads whole.
    @Test(arguments: ["hello-16k-mono", "hello-44k-stereo"])
    func refusesAFileLongerThanItTakes(name: String) throws {
        #expect {
            try AudioClip(contentsOf: fixture(name), longest: 2)
        } throws: { error in
            guard case AudioClipError.longerThan(2, let seconds) = error else { return false }
            return abs(seconds - Self.fixtureDuration) < 0.01
        }
        #expect(abs(try AudioClip(contentsOf: fixture(name), longest: 3).duration - Self.fixtureDuration) < 0.01)
    }

    @Test func durationIsSampleCountAtSixteenKilohertz() {
        let clip = AudioClip(samples: Array(repeating: 0, count: 16_000))
        #expect(clip.duration == 1)
        #expect(clip.peak == 0)
    }

    /// The peak is the largest magnitude, and a sample that is not a number has none.
    @Test func thePeakIsTheLargestMagnitudeAndANaNHasNone() {
        #expect(AudioClip(samples: [0.1, -0.6, 0.3]).peak == 0.6)
        #expect(AudioClip(samples: [0.1, .nan, -0.4]).peak == 0.4)
        #expect(AudioClip.peak(of: [0.2, -0.9, 0.5][1...]) == 0.9)
        #expect(AudioClip(samples: []).peak == 0)
    }

    /// The same tone in the left channel only and in the right channel only. A
    /// downmix that dropped or favored either channel could not produce equal peaks.
    @Test func downmixHearsBothChannelsEqually() throws {
        let left = try AudioClip(contentsOf: fixture("tone-left-only"))
        let right = try AudioClip(contentsOf: fixture("tone-right-only"))
        #expect(left.peak > 0.1)
        #expect(abs(left.peak - right.peak) < 0.001)
        #expect(abs(left.duration - 1) < 0.01)
    }

    @Test func emptyFileIsAnEmptyClip() throws {
        let clip = try AudioClip(contentsOf: fixture("empty"))
        #expect(clip.samples.isEmpty)
        #expect(clip.duration == 0)
    }

    @Test func missingFileFailsLoudly() {
        #expect(throws: (any Error).self) {
            try AudioClip(contentsOf: URL(fileURLWithPath: "/nonexistent/clip.wav"))
        }
    }
}

@Suite struct AudioClipWriteTests {
    static func temporaryWav() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lowtalker-\(UUID().uuidString).wav")
    }

    /// Write, then load through the same boundary every engine uses. 16-bit PCM
    /// rounds each sample to the nearest 1/32768.
    @Test func roundTripsThroughAFile() throws {
        let tone = AudioClip(samples: (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })
        let url = Self.temporaryWav()
        defer { try? FileManager.default.removeItem(at: url) }
        try tone.write(to: url)

        let loaded = try AudioClip(contentsOf: url)
        #expect(loaded.samples.count == tone.samples.count)
        let difference = zip(loaded.samples, tone.samples).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(difference <= 1 / 32_768)
    }

    @Test func emptyClipWritesAnEmptyFile() throws {
        let url = Self.temporaryWav()
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioClip(samples: []).write(to: url)
        #expect(try AudioClip(contentsOf: url).samples.isEmpty)
    }

    @Test func unwritableDestinationFailsLoudly() {
        #expect(throws: AudioClipError.self) {
            try AudioClip(samples: [0]).write(to: URL(fileURLWithPath: "/nonexistent/dir/clip.wav"))
        }
    }
}
