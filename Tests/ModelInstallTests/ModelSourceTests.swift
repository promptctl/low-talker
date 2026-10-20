import Foundation
import LowTalkerCore
@testable import ModelInstall
import Testing
@testable import WhisperKit

@Suite struct ModelSourceTests {
    /// The store installs the tokenizer WhisperKit will read at load, and WhisperKit's
    /// choice of it is internal, so the store's mirror is held to WhisperKit's own
    /// functions over every vocabulary and encoder width they tell apart, and one
    /// of each they do not.
    @Test(arguments: [51863, 51864, 51865, 51866, 51867], [0, 384, 512, 768, 1024, 1280, 1536])
    func tokenizerRepoMatchesWhisperKit(logitsDim: Int, encoderDim: Int) {
        let whisperKit = ModelUtilities.tokenizerNameForVariant(ModelUtilities.detectVariant(logitsDim: logitsDim, encoderDim: encoderDim))
        #expect(ModelVariant(logitsDim: logitsDim, encoderDim: encoderDim).tokenizerRepo == whisperKit)
    }

    /// After the store's hub folder, WhisperKit's load looks in the model folder and then
    /// the hub layout under it; the prompt encoder looks in the same places in that order.
    @Test func tokenizerSearchPathsAreWhisperKits() {
        let folder = URL(filePath: "/store/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3")
        #expect(ModelVariant.largev3.tokenizerSearchPaths(in: folder) == [folder, folder.appending(path: "models/openai/whisper-large-v3")])
    }

    /// A task cancelled before it was resumed can end before the caller waits; the
    /// caller that arrives second still hears how it ended.
    @Test(.timeLimit(.minutes(1))) func transferThatEndsBeforeTheCallerWaitsStillAnswersIt() async throws {
        let url = URL(string: "http://127.0.0.1:9/never.zip")!
        let transfer = Archive.Transfer(source: url, destination: FileManager.default.temporaryDirectory.appending(path: "never.zip")) { _ in }
        transfer.urlSession(.shared, task: URLSession.shared.dataTask(with: url), didCompleteWithError: URLError(.cancelled))
        await #expect(throws: URLError(.cancelled)) {
            try await withCheckedThrowingContinuation { transfer.wait($0) }
        }
    }
}
