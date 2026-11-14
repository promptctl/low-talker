import Foundation
import LowTalkerCore
@testable import ModelInstall
import Testing

/// What a revision is, and how the one `main` names is found, from answers captured from
/// huggingface.co. A fetch at a revision needs the network, so it is checked by
/// model-cache.yml's run, not here.
@Suite struct ModelRevisionTests {
    static let weights = ModelRevision.Commit(String(repeating: "a", count: 40))!
    static let tokenizer = ModelRevision.Commit(String(repeating: "b", count: 40))!
    static let head = ModelRevision.Commit(String(repeating: "c", count: 40))!
    static let revision = ModelRevision(of: .default, [.weights: weights, .tokenizer: tokenizer])!
    static let parakeet = ModelRevision(of: .parakeet(.tdtV3), [.weights: weights, .spotterEncoder: tokenizer, .spotterHead: head])!

    @Test func revisionReadsBackFromItsDescription() {
        #expect("\(Self.revision)" == "\(Self.weights)-\(Self.tokenizer)")
        #expect("\(Self.parakeet)" == "\(Self.weights)-\(Self.tokenizer)-\(Self.head)")
        #expect(ModelRevision(of: .default, Self.revision.description) == Self.revision)
        #expect(ModelRevision(of: .parakeet(.tdtV3), Self.parakeet.description) == Self.parakeet)
    }

    /// A revision is read against the model it names, so one model's text is never another's,
    /// and a revision is made only with a commit for every part of its model.
    @Test func aRevisionIsTheModelsOwn() {
        #expect(ModelRevision(of: .parakeet(.tdtV3), Self.revision.description) == nil)
        #expect(ModelRevision(of: .default, Self.parakeet.description) == nil)
        #expect(ModelRevision(of: .parakeet(.tdtV3), [.weights: Self.weights, .tokenizer: Self.tokenizer, .spotterHead: Self.head]) == nil)
        #expect(ModelRevision(of: .default, [.weights: Self.weights]) == nil)
    }

    /// The revisions of several models read back from the one text a cache key and
    /// `download --from` share, in name order whatever order they were given in.
    @Test func revisionsReadBackFromTheirDescription() throws {
        let revisions = try #require(ModelRevisions([Self.parakeet, Self.revision]))
        #expect("\(revisions)" == "large-v3-v20240930_turbo_632MB@\(Self.weights)-\(Self.tokenizer)+parakeet-tdt-0.6b-v3@\(Self.weights)-\(Self.tokenizer)-\(Self.head)")
        #expect(ModelRevisions(revisions.description) == revisions)
    }

    @Test(arguments: ["", "base.en", "base.en@", "@\(String(repeating: "a", count: 40))", "../x@\(String(repeating: "a", count: 40))", "base.en@\(String(repeating: "a", count: 40))+base.en@\(String(repeating: "a", count: 40))"])
    func revisionsRefuseWhatIsNotModelsAtCommits(text: String) {
        #expect(ModelRevisions(text) == nil)
    }

    @Test(arguments: [
        "",
        "\(String(repeating: "a", count: 40))-\(String(repeating: "B", count: 40))",
        "\(String(repeating: "a", count: 39))-\(String(repeating: "b", count: 40))",
        "\(String(repeating: "a", count: 40))-\(String(repeating: "ｂ", count: 40))",
        "\(String(repeating: "a", count: 40))-\(String(repeating: "b", count: 40))-\(String(repeating: "c", count: 40))",
    ])
    func revisionRefusesWhatIsNotAWhisperModelsTwoCommits(text: String) {
        #expect(ModelRevision(of: .default, text) == nil)
    }

    /// The three questions, answered as huggingface.co answered them on 2026-10-04 (siblings
    /// cut to the ones near the default model, blob ids left out): the weights' commit, their config at that
    /// commit, and the commit of the tokenizer repo the config picks.
    @Test func upstreamAsksForTheWeightsThenTheTokenizerTheirConfigPicks() async throws {
        let weights = "0f63a7800b00dd0226abd051b906c246e1907482"
        let tokenizer = "06f233fe06e710322aca913c1bc4249a0d71fce1"
        let answers = [
            "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/revision/main?blobs=true": """
                {"id": "argmaxinc/whisperkit-coreml", "sha": "\(weights)", "siblings": [
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo/config.json", "size": 2244},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/config.json", "size": 2244},
                  {"rfilename": "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin", "size": 421968768,
                   "lfs": {"sha256": "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1", "size": 421968768, "pointerSize": 134}}]}
                """,
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/\(weights)/openai_whisper-large-v3-v20240930_turbo_632MB/config.json": """
                {"d_model": 1280, "model_type": "whisper", "vocab_size": 51866}
                """,
            "https://huggingface.co/api/models/openai/whisper-large-v3/revision/main?blobs=true": """
                {"id": "openai/whisper-large-v3", "sha": "\(tokenizer)", "siblings": [{"rfilename": "tokenizer.json", "size": 2480617}]}
                """,
        ]
        let revision = try await ModelRevision.upstream(of: "large-v3-v20240930_turbo_632MB") { url in
            try Data(#require(answers[url.absoluteString], "asked \(url)").utf8)
        }
        #expect(revision == ModelRevision(of: "large-v3-v20240930_turbo_632MB", "\(weights)-\(tokenizer)"))
    }

    /// Parakeet's revision is the commit of its repo and of each repo its spotter's halves come
    /// from, each asked once; answered as huggingface.co answered on 2026-11-14 (siblings cut).
    @Test func upstreamOfParakeetIsEachRepoCommit() async throws {
        let commit = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
        let encoder = "9bc92ead6e8f17eca92a869fd578ae76842b82ba"
        let head = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
        let answers = [
            "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/revision/main?blobs=true": """
                {"id": "FluidInference/parakeet-tdt-0.6b-v3-coreml", "sha": "\(commit)", "siblings": [{"rfilename": "parakeet_v3_vocab.json", "size": 151122}]}
                """,
            "https://huggingface.co/api/models/FluidInference/parakeet-tdt-ctc-110m-coreml/revision/main?blobs=true": """
                {"id": "FluidInference/parakeet-tdt-ctc-110m-coreml", "sha": "\(encoder)", "siblings": [{"rfilename": "parakeet_vocab.json", "size": 18136}]}
                """,
            "https://huggingface.co/api/models/FluidInference/parakeet-ctc-110m-coreml/revision/main?blobs=true": """
                {"id": "FluidInference/parakeet-ctc-110m-coreml", "sha": "\(head)", "siblings": [{"rfilename": "tokenizer.json", "size": 360106}]}
                """,
        ]
        let revision = try await ModelRevision.upstream(of: .parakeet(.tdtV3)) { url in
            try Data(#require(answers[url.absoluteString], "asked \(url)").utf8)
        }
        #expect(revision == ModelRevision(of: .parakeet(.tdtV3), "\(commit)-\(encoder)-\(head)"))
    }

    /// Parakeet's manifest is the files of the four models the engine loads and its vocabulary,
    /// at the repo's top, and none of the repo's other conversions; the listing is cut from
    /// huggingface.co's at 7dd20fe6 on 2026-11-14.
    @Test func parakeetsManifestTakesOnlyTheFilesTheEngineLoads() throws {
        let listing = try JSONDecoder().decode(Hub.Revision.self, from: Data("""
            {"sha": "\(Self.weights)", "siblings": [
              {"rfilename": "README.md", "size": 4285},
              {"rfilename": "Decoder.mlmodelc/weights/weight.bin", "size": 23604992},
              {"rfilename": "Encoder.mlmodelc/weights/weight.bin", "size": 445187200},
              {"rfilename": "Encoder_v2.mlmodelc/model.mil", "size": 1002653},
              {"rfilename": "Encoder_v2.mlmodelc/weights/weight.bin", "size": 594211328},
              {"rfilename": "JointDecision.mlmodelc/coremldata.bin", "size": 534},
              {"rfilename": "JointDecisionv2.mlmodelc/coremldata.bin", "size": 591},
              {"rfilename": "Preprocessor.mlmodelc/metadata.json", "size": 2841},
              {"rfilename": "mlpackages/Decoder.mlpackage/Manifest.json", "size": 617},
              {"rfilename": "parakeet_v3_vocab.json", "size": 151122},
              {"rfilename": "parakeet_vocab.json", "size": 151122}]}
            """.utf8))
        let store = URL(filePath: "/store")
        let manifest = try listing.manifest(of: nil, in: store.appending(path: "models/FluidInference/parakeet-tdt-0.6b-v3-coreml"), store: store, matching: ParakeetModel.hubGlobs(ParakeetModel.tdtV3.source(of: .weights)!.files))
        #expect(manifest == (try Manifest(folder: "models/FluidInference/parakeet-tdt-0.6b-v3-coreml", files: [
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992),
            .init(path: "Encoder_v2.mlmodelc/model.mil", size: 1002653),
            .init(path: "Encoder_v2.mlmodelc/weights/weight.bin", size: 594211328),
            .init(path: "JointDecision.mlmodelc/coremldata.bin", size: 534),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841),
            .init(path: "parakeet_v3_vocab.json", size: 151122),
        ])))
    }

    /// The spotter's head is the CTC head and the tokenizer of its repo, and none of the repo's
    /// 6-bit encoder, its mel model, or the conversion code beside them; the listing is cut from
    /// huggingface.co's at accdafd8 on 2026-11-14.
    @Test func theSpotterHeadsManifestTakesOnlyTheHeadAndItsTokenizer() throws {
        let listing = try JSONDecoder().decode(Hub.Revision.self, from: Data("""
            {"sha": "\(Self.head)", "siblings": [
              {"rfilename": "AudioEncoder.mlmodelc/weights/weight.bin", "size": 100778304},
              {"rfilename": "CtcHead.mlmodelc/model.mil", "size": 3605},
              {"rfilename": "CtcHead.mlmodelc/weights/weight.bin", "size": 1051842},
              {"rfilename": "CtcHead.mlpackage/Manifest.json", "size": 617},
              {"rfilename": "MelSpectrogram.mlmodelc/model.mil", "size": 12584},
              {"rfilename": "convert/parakeet-tdt-ctc-110m/coreml/convert-parakeet.py", "size": 26577},
              {"rfilename": "tokenizer.json", "size": 360106},
              {"rfilename": "vocab.json", "size": 16086}]}
            """.utf8))
        let store = URL(filePath: "/store")
        let folder = "models/FluidInference/parakeet-ctc-110m-coreml"
        let manifest = try listing.manifest(of: nil, in: store.appending(path: folder), store: store, matching: ParakeetModel.hubGlobs(ParakeetModel.tdtV3.source(of: .spotterHead)!.files))
        #expect(manifest == (try Manifest(folder: folder, files: [
            .init(path: "CtcHead.mlmodelc/model.mil", size: 3605),
            .init(path: "CtcHead.mlmodelc/weights/weight.bin", size: 1051842),
            .init(path: "tokenizer.json", size: 360106),
        ])))
    }

    @Test func variantFolderIsTheOneFolderMatchingTheModel() throws {
        let files = ["openai_whisper-large-v3/config.json", "openai_whisper-large-v3_turbo/config.json", "README.md"]
        #expect(try ModelRevision.variantFolder(of: "large-v3", among: files) == "openai_whisper-large-v3")
    }

    /// WhisperKit narrows a name two folders end in to the openai one.
    @Test func variantFolderPrefersOpenAIWhenTwoFoldersMatch() throws {
        let files = ["distil-whisper_large-v3/config.json", "openai_whisper-large-v3/config.json"]
        #expect(try ModelRevision.variantFolder(of: "large-v3", among: files) == "openai_whisper-large-v3")
    }

    @Test func variantFolderRefusesAModelNoFolderHolds() {
        #expect(throws: ModelInstallError.noVariantFolder(model: "tiny", matches: [])) {
            try ModelRevision.variantFolder(of: "tiny", among: ["openai_whisper-large-v3/config.json"])
        }
    }

    /// A listing without sizes cannot say what whole is, so it is refused rather than
    /// read as files of no particular size.
    @Test func listingWithoutSizesIsRefused() {
        let listing = #"{"sha": "\#(Self.weights)", "siblings": [{"rfilename": "config.json"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Hub.Revision.self, from: Data(listing.utf8))
        }
    }

    /// The weights' manifest is every file under the variant folder, at the sizes the hub lists,
    /// under paths relative to that folder.
    @Test func manifestTakesTheHubSizesOfTheSelectedFiles() throws {
        let listing = try JSONDecoder().decode(Hub.Revision.self, from: Data("""
            {"sha": "\(Self.weights)", "siblings": [
              {"rfilename": "README.md", "size": 5},
              {"rfilename": "openai_whisper-test/config.json", "size": 2244},
              {"rfilename": "openai_whisper-test/AudioEncoder.mlmodelc/weights/weight.bin", "size": 421968768}]}
            """.utf8))
        let store = URL(filePath: "/store")
        let manifest = try listing.manifest(of: "openai_whisper-test", in: store.appending(path: "models/argmaxinc/whisperkit-coreml"), store: store, matching: ["*"])
        #expect(manifest == (try Manifest(folder: "models/argmaxinc/whisperkit-coreml/openai_whisper-test", files: [
            .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", size: 421968768),
            .init(path: "config.json", size: 2244),
        ])))
    }

    /// The tokenizer's manifest is the named files at the repo's top, whichever of
    /// them the revision holds.
    @Test func manifestTakesTheNamedFilesAtTheRepoTop() throws {
        let listing = try JSONDecoder().decode(Hub.Revision.self, from: Data("""
            {"sha": "\(Self.tokenizer)", "siblings": [
              {"rfilename": "model.safetensors", "size": 9},
              {"rfilename": "tokenizer.json", "size": 2480617},
              {"rfilename": "config.json", "size": 1272}]}
            """.utf8))
        let store = URL(filePath: "/store")
        let manifest = try listing.manifest(of: nil, in: store.appending(path: "models/openai/whisper-test"), store: store, matching: ["config.json", "tokenizer.json", "chat_template.json"])
        #expect(manifest == (try Manifest(folder: "models/openai/whisper-test", files: [
            .init(path: "config.json", size: 1272),
            .init(path: "tokenizer.json", size: 2480617),
        ])))
    }
}
