import Foundation
@testable import LowTalkerCore
import LowTalkerCoreFakes
import Testing

extension PromptEncoder {
    /// One token per word, so a test counts the prompt by eye; the limit is the most
    /// any test's vocabulary is told unless it says otherwise.
    static func countingWords(limit: Int = 1000) -> PromptEncoder {
        PromptEncoder(limit: limit) { text in text.split(separator: " ").map { _ in 0 } }
    }
}

extension Prompting {
    /// Every model a test's config names, told through `PromptEncoder.countingWords`.
    static func countingWords(limit: Int = 1000) -> Prompting {
        .counting(limit: limit)
    }
}

@Suite struct PromptEncoderTests {
    @Test func aVocabularyPastTheLimitIsRefusedWithItsSize() throws {
        let vocabulary = Vocabulary(try ["Brynleigh", "Fryslie", "Jaxxon"].map(Vocabulary.Term.init))
        #expect(throws: VocabularyError.tooLong(tokens: 3, limit: 2)) { try PromptEncoder.countingWords(limit: 2).prompt(for: vocabulary) }
        #expect(try PromptEncoder.countingWords(limit: 3).prompt(for: vocabulary).count == 3)
    }

    /// No terms is no prompt, which every engine can be told.
    @Test func theEmptyVocabularyIsNoPrompt() throws {
        #expect(try PromptEncoder.countingWords(limit: 0).prompt(for: .empty) == [])
    }

    /// A store with no model in it fails the load as the model's, never as the config's.
    @Test func aStoreWithNoModelIsUnavailablePrompts() async throws {
        let empty = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        let installed = InstalledModel(model: .default, folder: empty.appending(path: "model"), hub: empty)
        let error = await #expect(throws: PromptsUnavailable.self) { try await PromptEncoder.load(installed) }
        #expect(error?.description.hasPrefix("the model's tokenizer did not load, so no mode's vocabulary can be checked: ") == true)
    }

    /// An engine that hears no vocabulary is told none, and refuses any term by its model's name.
    @Test func anEngineTakingNoVocabularyRefusesEveryTerm() throws {
        let parakeet = PromptEncoder.takingNone(.parakeet(.tdtV3))
        #expect(try parakeet.prompt(for: .empty) == [])
        #expect(throws: VocabularyError.engineTakesNone(.parakeet(.tdtV3))) { try parakeet.prompt(for: Vocabulary([try Vocabulary.Term("Fryslie")])) }
    }

    /// Parakeet's check needs nothing from the store but the model being there: it reads no
    /// tokenizer.
    @Test func aParakeetModelLoadsTheRefusalWithNoTokenizer() async throws {
        let empty = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        let installed = InstalledModel(model: .parakeet(.tdtV3), folder: empty.appending(path: "model"), hub: empty)
        await #expect(throws: VocabularyError.engineTakesNone(.parakeet(.tdtV3))) { try await PromptEncoder.load(installed).prompt(for: Vocabulary([try Vocabulary.Term("Fryslie")])) }
    }

    /// [LAW:nothing-unseen] The read's event: how long it took, and each model it failed for.
    @Test func theReadIsToldHowLongItTookAndWhichModelsFailed() {
        let read = Prompting([.default: .success(.countingWords()), .parakeet(.tdtV3): .failure(PromptsUnavailable(why: "no vocabulary"))])
        #expect("\(Prompting.Load(after: .milliseconds(412), prompting: read))" == "prompt tokenizers: read in 412 ms; parakeet-tdt-0.6b-v3: the model's tokenizer did not load, so no mode's vocabulary can be checked: no vocabulary")
        #expect("\(Prompting.Load(after: .milliseconds(9), prompting: Prompting([.default: .success(.countingWords())])))" == "prompt tokenizers: read in 9 ms")
    }

    /// A model the build does not carry is refused by name, with the ones it does; a model whose
    /// check did not load refuses only the configs that name it.
    @Test func aModelIsCheckedOnlyByItsOwnEncoder() throws {
        let read = Prompting([.default: .success(.countingWords()), .parakeet(.tdtV3): .failure(PromptsUnavailable(why: "no vocabulary"))])
        #expect(throws: ConfigError.modelNotCarried("base.en", carried: [.default, .parakeet(.tdtV3)])) { try read.encoder(for: "base.en") }
        #expect(throws: ConfigError.prompts(.parakeet(.tdtV3), PromptsUnavailable(why: "no vocabulary"))) { try read.encoder(for: .parakeet(.tdtV3)) }
        #expect(try read.encoder(for: .default).prompt(for: .empty) == [])
    }
}
