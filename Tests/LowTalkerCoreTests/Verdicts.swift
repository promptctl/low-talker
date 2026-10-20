@testable import LowTalkerCore

/// Verdicts of a test's own making, on each frame's own samples: the gate judged against the
/// discriminator it is handed, with no model.
struct Verdicts: Discriminator {
    let lookbehind: Int
    let lookahead: Int
    let call: @Sendable (ArraySlice<Float>) -> Verdict

    func verdict(_ window: ArraySlice<Float>) throws -> Verdict {
        call(window.dropFirst(lookbehind).prefix(Utterance.frameCount))
    }

    /// Every frame speech, judged as it fills: the gate as it was before it had a discriminator.
    static let everyFrameSpeech = Verdicts(lookbehind: 0, lookahead: 0) { _ in .speech }

    /// Any frame peaking at or above `level` called something other than speech: a cough the
    /// test makes louder than its speaker.
    static func other(atOrAbove level: Float, lookahead: Int = 0) -> Verdicts {
        Verdicts(lookbehind: 0, lookahead: lookahead) { frame in frame.contains { abs($0) >= level } ? .other : .speech }
    }
}
