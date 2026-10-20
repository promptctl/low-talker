import Foundation
import WhisperKit

/// Which tokenizer a model folder decodes with, and where WhisperKit looks for it.
///
/// [LAW:one-source-of-truth] WhisperKit decides both, internally and after the Neural
/// Engine load, so they are mirrored here, once, defaults included. The store installs
/// the tokenizer this names, and `PromptEncoder` loads it, so the installer, the
/// config's vocabulary check, and the engine all read one `tokenizer.json`.
/// `ModelSourceTests` holds the variant to WhisperKit's own functions over every input
/// they distinguish.
extension ModelVariant {
    /// The Whisper size a model folder holds, read off its `config.json` the way
    /// WhisperKit reads it off the loaded model: the vocabulary size is the decoder's
    /// logits and `d_model` the encoder's embedding.
    package init(logitsDim: Int, encoderDim: Int) {
        self = switch logitsDim {
        case 51865: [384: .tiny, 512: .base, 768: .small, 1024: .medium, 1280: .largev2][encoderDim] ?? .base
        case 51864: [384: .tinyEn, 512: .baseEn, 768: .smallEn, 1024: .mediumEn][encoderDim] ?? .baseEn
        case 51866: .largev3
        default: .base
        }
    }

    package init(modelConfig data: Data) throws {
        struct Config: Decodable {
            let vocab_size: Int
            let d_model: Int
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        self.init(logitsDim: config.vocab_size, encoderDim: config.d_model)
    }

    /// The hub repo WhisperKit fetches this size's tokenizer from.
    package var tokenizerRepo: String {
        "openai/whisper-\(description)"
    }

    /// Where WhisperKit's load looks for this size's tokenizer besides the store's hub
    /// folder, in its order: the model folder itself, then the hub layout under it.
    package func tokenizerSearchPaths(in modelFolder: URL) -> [URL] {
        [modelFolder, HubApiWrapper(downloadBase: modelFolder).localRepoLocation(HubApiWrapper.Repo(id: tokenizerRepo))]
    }
}
