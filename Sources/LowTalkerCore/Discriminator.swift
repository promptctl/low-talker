import Foundation

/// What tells the speech gate whether the loudest sound in a frame is speech, so a cough, a
/// knock or a clap louder than the speaker sets no range for the speech after it.
///
/// [LAW:no-ambient-temporal-coupling] A verdict reads audio past the frame it judges, so the
/// gate holds each frame until `lookahead` samples past it have arrived, or the utterance has
/// ended; how long that is is the discriminator's fact, not a timer's.
protocol Discriminator: Sendable {
    /// Samples before a frame its verdict reads: zeros before the audio's first sample.
    var lookbehind: Int { get }
    /// Samples after a frame its verdict reads: zeros past the end of an utterance that has ended.
    var lookahead: Int { get }
    /// The verdict on the frame inside `window`: `lookbehind` samples, the frame, then
    /// `lookahead` samples, `Utterance.frame` long in all but the frame.
    func verdict(_ window: ArraySlice<Float>) throws -> Verdict
}

/// Whether the loudest sound in a frame is speech.
enum Verdict: Sendable {
    case speech
    /// A cough, a knock, a clap, a sneeze, the room: anything but speech.
    case other

    /// What a window of a frame with this verdict, peaking at `peak`, adds to the range: its
    /// peak when the frame is speech, nothing otherwise.
    func reference(_ peak: Float) -> Float {
        switch self {
        case .speech: peak
        case .other: 0
        }
    }
}
