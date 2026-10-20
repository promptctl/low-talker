@testable import LowTalkerCore
import Foundation
import Testing

/// The bundled gate classifier loads, reads a frame with 0.2 s either side, and calls a bench
/// reader's loudest syllable speech.
@Suite struct GateClassifierTests {
    static let bench = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("bench/librispeech")

    @Test func theBundledModelCallsAReadersLoudestSyllableSpeech() async throws {
        let classifier = try await GateClassifier()
        #expect(classifier.lookbehind == 3_200 && classifier.lookahead == 3_200)
        let reader = try AudioClip(contentsOf: Self.bench.appendingPathComponent("2277-149896-0000.wav")).samples
        // Frame 28 holds its loudest syllable: r8 scored it 0.99997 (low-speech-gate-lss.443's probe).
        let frame = 28 * Utterance.frameCount
        let window = reader[(frame - classifier.lookbehind)..<(frame + Utterance.frameCount + classifier.lookahead)]
        #expect(try classifier.verdict(window) == .speech)
    }
}
