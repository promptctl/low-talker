import Foundation

/// Whether a vocabulary can be told to a model's engine, read from the store with no Core ML
/// load, so a config's modes are checked long before the model is resident.
///
/// [LAW:single-enforcer] Each engine's own rule, the one its engine applies again at each press:
/// Whisper's prompt limit, through the `PromptEncoder` its pipeline makes, and Parakeet's
/// spelling of every term in its spotter's pieces, through the `SpotterTokenizer` its engine
/// spells the terms with.
public struct VocabularyCheck: Sendable {
    private let check: @Sendable (Vocabulary) throws(VocabularyError) -> Void

    public init(_ encoder: PromptEncoder) {
        check = { vocabulary throws(VocabularyError) in _ = try encoder.prompt(for: vocabulary) }
    }

    public init(_ tokenizer: SpotterTokenizer) {
        check = { vocabulary throws(VocabularyError) in _ = try tokenizer.terms(vocabulary) }
    }

    /// Nothing, or why the engine cannot be told `vocabulary`.
    public func check(_ vocabulary: Vocabulary) throws(VocabularyError) {
        try check(vocabulary)
    }

    /// The check for `installed`, from the files its engine reads a vocabulary through.
    ///
    /// [LAW:types-are-the-program] Exhaustive, so an engine added to `Model` says here how it
    /// is told a vocabulary before it compiles.
    public static func load(_ installed: InstalledModel) async throws(PromptsUnavailable) -> VocabularyCheck {
        switch installed.model {
        case .whisperKit:
            return VocabularyCheck(try await PromptEncoder.load(installed))
        case .parakeet:
            let file = installed.folder(of: .spotterHead).appending(path: ParakeetModel.spotterTokenizer)
            let json: Data
            do { json = try Data(contentsOf: file) } catch { throw PromptsUnavailable(why: "\(error)") }
            return VocabularyCheck(try SpotterTokenizer(json: json))
        }
    }
}

/// How each model the app carries is told a vocabulary, read before any of them is resident,
/// so a config's modes are checked against the model the config names.
///
/// [LAW:types-are-the-program] One result per model: a model whose check did not load refuses
/// only a config that names it, and a model the app does not carry has no check at all, which
/// is the config's refusal to name it.
public struct Prompting: Sendable {
    public let checks: [Model: Result<VocabularyCheck, PromptsUnavailable>]

    public init(_ checks: [Model: Result<VocabularyCheck, PromptsUnavailable>]) {
        self.checks = checks
    }

    /// The models this covers, in name order, as a refusal lists them.
    public var models: [Model] {
        checks.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// `model`'s check, or why a config naming it cannot be checked.
    public func check(for model: Model) throws(ConfigError) -> VocabularyCheck {
        guard let check = checks[model] else { throw .modelNotCarried(model, carried: models) }
        do { return try check.get() } catch { throw .prompts(model, error) }
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
                guard case .failure(let failure) = prompting.checks[model] else { return nil }
                return "; \(model): \(failure)"
            }
            return "prompt tokenizers: read in \(Int((after / .milliseconds(1)).rounded())) ms\(failures.joined())"
        }
    }
}
