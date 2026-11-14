/// How each model the app carries is told a vocabulary, read before any of them is resident,
/// so a config's modes are checked against the model the config names.
///
/// [LAW:types-are-the-program] One result per model: a model whose check did not load refuses
/// only a config that names it, and a model the app does not carry has no check at all, which
/// is the config's refusal to name it.
public struct Prompting: Sendable {
    public let encoders: [Model: Result<PromptEncoder, PromptsUnavailable>]

    public init(_ encoders: [Model: Result<PromptEncoder, PromptsUnavailable>]) {
        self.encoders = encoders
    }

    /// The models this covers, in name order, as a refusal lists them.
    public var models: [Model] {
        encoders.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// `model`'s encoder, or why a config naming it cannot be checked.
    public func encoder(for model: Model) throws(ConfigError) -> PromptEncoder {
        guard let encoder = encoders[model] else { throw .modelNotCarried(model, carried: models) }
        do { return try encoder.get() } catch { throw .prompts(model, error) }
    }

    /// What came of reading every model's check at launch, as the log says it.
    ///
    /// [LAW:nothing-unseen] The read is a unit of work at launch, and the reading of the
    /// config waits on it, so how long it took and each model it failed for are both told.
    public struct Load: Sendable, CustomStringConvertible {
        public let after: Duration
        public let prompting: Prompting

        public init(after: Duration, prompting: Prompting) {
            self.after = after
            self.prompting = prompting
        }

        public var description: String {
            let failures = prompting.models.compactMap { model -> String? in
                guard case .failure(let failure) = prompting.encoders[model] else { return nil }
                return "; \(model): \(failure)"
            }
            return "prompt tokenizers: read in \(Int((after / .milliseconds(1)).rounded())) ms\(failures.joined())"
        }
    }
}
