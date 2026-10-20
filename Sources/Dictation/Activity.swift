import LowTalkerCore

extension Dictation {
    /// What the loop is doing with presses now, as the status item and the HUD show it: a microphone
    /// open for a press, a press's chord down with nothing hearing it, presses ended and still
    /// on their way to the cursor, or none of these.
    ///
    /// [LAW:one-source-of-truth] Read off the loop's own press and queue, so the icon cannot
    /// say listening over a press that was refused its microphone, or ready over words still
    /// on their way.
    public enum Activity: Sendable, Equatable, CustomStringConvertible {
        case idle
        /// A press's microphone is open, and `heard` is the text the engine has read of it so
        /// far, confirmed then tentative. Wins over `transcribing`: the press being spoken
        /// is the one the person is watching for.
        case listening(heard: Transcript)
        /// A press is open and nothing is hearing it, for the reason `why` says, so the
        /// person learns it before speaking into it. Wins over `transcribing` as `listening` does.
        case refused(why: String)
        /// A press has ended and its outcome is not yet reported.
        case transcribing

        /// The activity whose face the icon wears over `readiness`. A press ended before the
        /// engine is ready is waiting on the load, or will fail with it, so the load's face is
        /// the true one until then. [LAW:one-source-of-truth] The one precedence both the
        /// glyph and the description read.
        private func shown(over readiness: EngineReadiness) -> Activity {
            switch (self, readiness) {
            case (.transcribing, .preparing), (.transcribing, .failed): .idle
            default: self
            }
        }

        /// What the status item draws: this activity while there is one, and the engine's
        /// readiness when there is none. [LAW:dataflow-not-control-flow]
        public func glyph(over readiness: EngineReadiness) -> EngineReadiness.StatusGlyph {
            switch shown(over: readiness) {
            case .idle: readiness.statusGlyph()
            case .listening: .symbol("waveform")
            case .refused: .symbol("exclamationmark.triangle")
            case .transcribing: .symbol("text.cursor")
            }
        }

        /// What the icon says to VoiceOver, and to an agent reading the menu bar over
        /// Accessibility, for the app named `name`.
        public func iconDescription(for name: String, over readiness: EngineReadiness) -> String {
            switch shown(over: readiness) {
            case .idle: readiness.iconDescription(for: name)
            case .listening: "\(name): listening"
            case .refused: "\(name): not listening"
            case .transcribing: "\(name): transcribing"
            }
        }

        /// The activity without the words, which are what the user dictated, so a log may
        /// carry it in the clear.
        public var description: String {
            switch self {
            case .idle: "idle"
            case .listening(let heard): "listening, \(heard.words.count) words heard"
            case .refused(let why): "refused: \(why)"
            case .transcribing: "transcribing"
            }
        }
    }
}
