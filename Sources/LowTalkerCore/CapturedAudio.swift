import Foundation

/// A session's audio, and whether it is all of the audio that session covered.
///
/// [LAW:parse-dont-validate] A clip cannot answer this about itself: one missing the
/// first thirty seconds of what was said looks exactly like one of the last thirty, and
/// the text it transcribes to is a plausible sentence either way. The capture is the one
/// place that knows, holding the ring and having watched the engines come and go, so
/// what crosses out of it carries the knowing. The two cases are the point: there is no
/// way to take the audio of a press without being handed what it is missing.
///
/// [LAW:no-silent-failure] What to do about a partial one is each surface's own
/// decision - `Dictation` refuses to type a fragment - but none can make it by accident.
public enum CapturedAudio: Sendable, Equatable {
    /// Every sample the session covered that the microphone ever captured.
    case whole(AudioClip)
    /// Audio the session covered is not in the clip, and `lost` says by which door.
    case partial(AudioClip, lost: Loss)

    /// What a session's clip is missing.
    ///
    /// [LAW:types-are-the-program] A loss of nothing cannot be made, which is what keeps
    /// `partial` from being able to claim one: holding a `Loss` is itself the proof that
    /// something was lost.
    public struct Loss: Sendable, Equatable {
        /// Samples of the session's own audio the ring had already dropped by the time it
        /// ended, or for a streamed session by the time its stream began: the head of the
        /// clip, gone for good. The first of what was said was overwritten before it could
        /// be handed over.
        public let scrolledOff: Int
        /// Capture restarted while the session was open - the input device changed, or an
        /// engine that failed was replaced - so the audio between the engine that stopped
        /// and the one that took over is missing from the middle of the clip. How much of
        /// it there was is not knowable: ring positions advance only on capture, so a
        /// stretch nothing captured leaves nothing behind to measure.
        public let interrupted: Bool
        /// Why the microphone was not capturing for part of the session, when it was not.
        /// Unknowable in samples for the same reason `interrupted` is - a stretch nothing
        /// captured leaves no positions behind.
        ///
        /// [LAW:types-are-the-program] One reason per loss, and each reason is a different
        /// fact with a different remedy, so the reason is the type rather than a flag the
        /// message has to reconstruct.
        public let unopened: Unopened?

        /// The reasons the microphone was not capturing for a session.
        public enum Unopened: Sendable, Equatable {
            /// The first audio arrived more than `AudioCapture.warmUpAllowance` after the key
            /// went down. What was said before it was never captured. Within the allowance the
            /// delay is warm-up and the clip is whole; past it the head of the clip is a gap.
            case startedLate
            /// The microphone was running for the press and delivered no audio for it.
            case noAudio
            /// The microphone stopped capturing during the press - its engine failed or its
            /// device went away - and had not come back by the time the press ended. When this
            /// holds with another reason, this is the one reported: it is still true after the
            /// press, and the others are not. [LAW:no-silent-failure]
            case stopped
        }

        public init?(scrolledOff: Int, interrupted: Bool, unopened: Unopened? = nil) {
            guard scrolledOff > 0 || interrupted || unopened != nil else { return nil }
            self.scrolledOff = scrolledOff
            self.interrupted = interrupted
            self.unopened = unopened
        }
    }
}

extension CapturedAudio.Loss: CustomStringConvertible {
    /// What happened, one sentence per door that was taken, since one press can lose audio
    /// through more than one of them. Each is a fact about the microphone or the speech,
    /// with no consequence attached: what the loss means for the press is the caller's.
    public var description: String {
        [
            scrolledOff > 0 ? String(format: "The first %.1f s of your speech was lost", AudioClip.duration(for: scrolledOff)) : nil,
            interrupted ? "Your microphone restarted while you were dictating" : nil,
            unopened.map { "\($0)" },
        ].compactMap { $0 }.joined(separator: ". ")
    }
}

extension CapturedAudio.Loss.Unopened: CustomStringConvertible {
    /// Each names the microphone and the consequence for the words, and the remedy where one
    /// is known. Read by a person in the menu, so it says what happened in their terms.
    public var description: String {
        switch self {
        case .startedLate:
            "Your microphone took more than \(String(format: "%g", AudioCapture.warmUpAllowance)) s to start after you pressed the key, so the first part of what you said was not recorded"
        case .noAudio:
            "Your microphone was on but recorded no sound during your dictation. Check the input selected in System Settings > Sound"
        case .stopped:
            "Your microphone stopped during your dictation and did not come back, so the rest of what you said was not recorded. Check the input selected in System Settings > Sound"
        }
    }
}

extension CapturedAudio {
    /// What the microphone delivered for one session, read at its end: through which input,
    /// how much of it, how loud, and how soon after the key went down.
    ///
    /// [LAW:nothing-unseen] Every press that opened a microphone carries one, so the three
    /// ways a press ends with no words read apart on its record alone: nothing arrived, what
    /// arrived was digital silence - a muted input, or one macOS feeds zeros - or what arrived
    /// had a level and the room was quiet.
    public struct Reading: Sendable, Equatable, CustomStringConvertible {
        /// Every input that fed the session, in the order they opened: one, unless a device
        /// change spliced the press, and then the samples below are all of theirs together.
        public let inputs: [MicrophoneInput]
        /// Pipeline samples delivered since the session began, its pre-roll not among them.
        public let samples: Int
        /// The largest sample magnitude among those the ring still holds, where full scale is
        /// 1: zero for none, and for digital silence. A press longer than the ring's retention
        /// is read over its newest stretch.
        public let peak: Float
        /// How long after the key went down the first of them was captured, and nil when none
        /// arrived. Zero for a microphone already running at the key.
        public let firstSample: Duration?

        public init(inputs: [MicrophoneInput], samples: Int, peak: Float, firstSample: Duration?) {
            self.inputs = inputs
            self.samples = samples
            self.peak = peak
            self.firstSample = firstSample
        }

        public var description: String {
            let through = inputs.map(\.description).joined(separator: " then ")
            guard let firstSample else { return "\(through) delivered nothing after the key went down" }
            let level = peak == 0 ? "of digital silence" : String(format: "peaking at %.1f dBFS", 20 * log10(peak))
            return "\(through) delivered \(String(format: "%.1f", AudioClip.duration(for: samples))) s (\(samples) samples) \(level), the first \(Int(firstSample / .milliseconds(1))) ms after the key went down"
        }
    }
}
