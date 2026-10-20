import Foundation
@testable import LowTalkerCore
import Testing

extension PromptEncoder {
    /// One token per word, so a test counts the prompt by eye; the limit is the most
    /// any test's vocabulary is told unless it says otherwise.
    static func countingWords(limit: Int = 1000) -> PromptEncoder {
        PromptEncoder(limit: limit) { text in text.split(separator: " ").map { _ in 0 } }
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

    /// [LAW:nothing-unseen] The load's event, both ways it ends.
    @Test func theLoadIsToldHowLongItTookOrWhyItFailed() {
        #expect("\(PromptEncoder.Load.loaded(after: .milliseconds(412)))" == "prompt tokenizer: loaded in 412 ms")
        #expect("\(PromptEncoder.Load.failed(PromptsUnavailable(why: "no config.json")))" == "prompt tokenizer: the model's tokenizer did not load, so no mode's vocabulary can be checked: no config.json")
    }
}
