import CoreML
import Foundation
@testable import LowTalkerCore
import LowTalkerCoreFakes
import Synchronization
import TestProbes
import Testing

/// A Parakeet network whose joint reads from a script: a token at each sample it names, a blank
/// everywhere else. Each frame's feature is the sample it starts at, counted from the pass's
/// first, so a script names where words sound whatever window they fall in. Its encoder returns
/// a frame per 80 ms and one more starting at the window's last sample, as the published
/// encoder's length does: 16,000 samples are 13 frames.
struct ScriptedNetwork: ParakeetNetwork {
    /// The token sounding at a sample, and the duration index the joint gives it.
    var spoken: [Int: (token: Int, duration: Int)] = [:]
    /// What the joint answers at a frame the script leaves silent.
    var silence = JointStep(token: ParakeetWindow.blank, probability: 1, duration: 1)
    var probability: Float = 0.5
    /// Every token the predictor was fed, and the prediction each joint call was handed.
    let log = Log()

    final class Log: Sendable {
        let fed = Mutex<[Int]>([])
        let handed = Mutex<[Float]>([])
    }

    var startState: PredictorState { PredictorState(hidden: [], cell: []) }

    func encode(_ samples: ArraySlice<Float>) throws -> EncodedWindow {
        EncodedWindow(frames: stride(from: samples.startIndex, through: samples.endIndex, by: ParakeetWindow.frameSamples).map { EncodedFrame(features: [Float($0)]) })
    }

    func predict(_ token: Int, from state: PredictorState) throws -> (Prediction, PredictorState) {
        log.fed.withLock { $0.append(token) }
        return (Prediction(features: [Float(token)]), PredictorState(hidden: state.hidden + [Float(token)], cell: state.cell))
    }

    func joint(_ frame: EncodedFrame, _ prediction: Prediction) throws -> JointStep {
        log.handed.withLock { $0.append(prediction.features[0]) }
        let start = Int(frame.features[0])
        // A frame says its tokens in the order of their samples, and a token already said is not
        // said again by the frame after it.
        guard let said = spoken.sorted(by: { $0.key < $1.key }).first(where: { (start..<start + ParakeetWindow.frameSamples).contains($0.key) && prediction.features[0] != Float($0.value.token) })?.value else {
            return silence
        }
        return JointStep(token: said.token, probability: probability, duration: said.duration)
    }
}

/// A vocabulary of control pieces, words that start with a space, and pieces that continue one.
let vocabulary = try! ParakeetVocabulary(pieces: (0..<ParakeetWindow.blank).map { id in
    switch id {
    case 0: "<unk>"
    case 1: "<|endoftext|>"
    case 300: " one"
    case 301: " two"
    case 302: " three"
    case 303: " four"
    case 304: "teen"
    case 305: "."
    default: " w\(id)"
    }
})

@Suite struct TDTDecodingTests {
    /// A frame per 80 ms, each its own window position.
    static func window(frames: Int, from start: Int = 0) -> EncodedWindow {
        EncodedWindow(frames: (0..<frames).map { EncodedFrame(features: [Float(start + $0 * ParakeetWindow.frameSamples)]) })
    }

    /// The samples `frames` whole frames span.
    static func span(frames: Int, from start: Int = 0) -> Range<Int> {
        start..<start + frames * ParakeetWindow.frameSamples
    }

    /// A token is emitted at its frame and fed to the predictor; a blank is not; decoding starts
    /// from the blank as the start symbol.
    @Test func aTokenIsEmittedAtItsFrameAndFedOn() throws {
        let network = ScriptedNetwork(spoken: [2_560: (300, 1)])
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 4), over: Self.span(frames: 4))
        #expect(decoding.tokens == [.init(id: 300, sample: 2_560, probability: 0.5)])
        #expect(network.log.fed.withLock { $0 } == [ParakeetWindow.blank, 300])
        #expect(decoding.facts == ParakeetPassFacts(samples: 0, windows: 1, frames: 4, blanks: 3, tokens: 1, forcedAdvances: 0))
    }

    /// A duration skips the frames it covers: the joint is asked nothing about them.
    @Test func aDurationSkipsTheFramesItCovers() throws {
        let network = ScriptedNetwork(spoken: [0: (300, 3)])
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 5), over: Self.span(frames: 5))
        // Frame 0 emits and covers frames 1 and 2 (duration 3 frames); frames 3 and 4 are blanks.
        #expect(network.log.handed.withLock { $0.count } == 3)
    }

    /// A blank whose duration is 0 would never move, so it moves one frame.
    @Test func aBlankAlwaysMovesOn() throws {
        let network = ScriptedNetwork(silence: JointStep(token: ParakeetWindow.blank, probability: 1, duration: 0))
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 3), over: Self.span(frames: 3))
        #expect(decoding.facts.blanks == 3)
    }

    /// A frame that keeps emitting at duration 0 is left after `maxSymbolsPerFrame` tokens, and the
    /// count starts again at the next frame.
    @Test func aFrameIsLeftAfterTheMostTokensItMayEmit() throws {
        let network = ScriptedNetwork(silence: JointStep(token: 300, probability: 0.9, duration: 0))
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 2), over: Self.span(frames: 2))
        #expect(decoding.tokens.count == 2 * ParakeetWindow.maxSymbolsPerFrame)
        #expect(decoding.facts.forcedAdvances == 2)
    }

    /// The predictor's state carries across a pass's windows: the second window's joint is handed
    /// the prediction the first window's last token left.
    @Test func thePredictionCarriesAcrossWindows() throws {
        let network = ScriptedNetwork(spoken: [1_280: (301, 1)])
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 2), over: Self.span(frames: 2))
        try decoding.decode(Self.window(frames: 1, from: 2_560), over: Self.span(frames: 1, from: 2_560))
        #expect(network.log.handed.withLock { $0 }.last == 301)
        #expect(decoding.facts.windows == 2)
    }

    /// The encoder's frame starting at a window's end is the next window's first, so it is
    /// decoded once: a token there is emitted once, by the next window.
    @Test func theFrameAtASeamIsDecodedOnce() throws {
        let network = ScriptedNetwork(spoken: [2_560: (300, 1)])
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 3), over: Self.span(frames: 2))
        try decoding.decode(Self.window(frames: 2, from: 2_560), over: Self.span(frames: 2, from: 2_560))
        #expect(decoding.tokens == [.init(id: 300, sample: 2_560, probability: 0.5)])
        #expect(decoding.facts.frames == 4)
    }

    /// A duration that runs past a window's last frame covers the next window's first frames, as
    /// it would any other frames: the joint is asked nothing about them.
    @Test func aDurationCarriesAcrossASeam() throws {
        let network = ScriptedNetwork(spoken: [1_280: (300, 4)])
        var decoding = try TDTDecoding(network: network)
        try decoding.decode(Self.window(frames: 2), over: Self.span(frames: 2))
        try decoding.decode(Self.window(frames: 4, from: 2_560), over: Self.span(frames: 4, from: 2_560))
        // Frame 1 emits and covers frames 2 through 4, the second window's first three.
        #expect(network.log.handed.withLock { $0.count } == 3)
    }

    /// A hold that wants the engine cancels a decode between frames.
    @Test func aCancelledDecodeStopsBetweenFrames() async throws {
        let network = ScriptedNetwork()
        let decoding = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var decoding = try TDTDecoding(network: network)
            try decoding.decode(Self.window(frames: 4), over: Self.span(frames: 4))
        }
        await #expect {
            try await decoding.value
        } throws: { error in
            if case TranscriptionFailure.cancelled = error { true } else { false }
        }
        #expect(network.log.handed.withLock { $0.count } == 0)
    }

    /// A duration index past the model's durations fails the reading by name.
    @Test func aDurationPastTheDurationsIsRefused() throws {
        var decoding = try TDTDecoding(network: ScriptedNetwork(silence: JointStep(token: ParakeetWindow.blank, probability: 1, duration: 5)))
        #expect(throws: ParakeetReadingError.durationOutOfRange(5)) { try decoding.decode(Self.window(frames: 1), over: Self.span(frames: 1)) }
    }

    /// [LAW:nothing-unseen] Every count, zeros included, is on the pass's line.
    @Test func thePassSaysWhatItDid() {
        #expect("\(ParakeetPassFacts(samples: 16_000, windows: 1, frames: 12, blanks: 9, tokens: 3, forcedAdvances: 0))" == "parakeet pass: 16000 samples in 1 windows, 12 frames, 3 tokens, 9 blanks, 0 forced advances")
    }
}

@Suite struct ParakeetWordsTests {
    static func token(_ id: Int, at frame: Int, _ probability: Float = 0.5) -> TDTDecoding.EmittedToken {
        .init(id: id, sample: frame * ParakeetWindow.frameSamples, probability: probability)
    }

    /// A word starts at each space-led piece and runs to the end of its last token's frame; a piece
    /// without a space joins the word before it, as sure as both pieces' probabilities together.
    @Test func piecesGroupIntoTimedWords() throws {
        let words = try vocabulary.words([Self.token(300, at: 1), Self.token(302, at: 4, 0.5), Self.token(304, at: 5, 0.25)], from: 0)
        #expect(Transcript(words: words).text == " one threeteen")
        #expect(words.map(\.time) == [0.08...0.16, 0.32...0.48])
        #expect(words.map(\.confidence.value) == [0.5, 0.125])
    }

    /// The first piece of a window that continues a word still carries the leading space every
    /// transcript word does.
    @Test func aFirstPieceWithNoSpaceStartsAWord() throws {
        #expect(try vocabulary.words([Self.token(304, at: 0)], from: 0).map(\.text) == [" teen"])
    }

    /// A control piece or a probability outside 0...1 fails the reading, naming it, rather than
    /// vanishing from the transcript.
    @Test func whatCannotBeAWordIsRefused() {
        #expect(throws: ParakeetReadingError.controlToken(id: 0, piece: "<unk>")) { try vocabulary.words([Self.token(0, at: 0)], from: 0) }
        #expect(throws: ParakeetReadingError.probabilityOutsideUnitInterval(1.5, piece: " one")) { try vocabulary.words([Self.token(300, at: 0, 1.5)], from: 0) }
        #expect(throws: ParakeetReadingError.tokenOutsideVocabulary(ParakeetWindow.blank)) { try vocabulary.words([Self.token(ParakeetWindow.blank, at: 0)], from: 0) }
    }

    /// A word sounding mostly before the cut is not read, so a control piece in it fails nothing.
    @Test func aWordBeforeTheCutIsNotRead() throws {
        let words = try vocabulary.words([Self.token(0, at: 0), Self.token(300, at: 1), Self.token(304, at: 2), Self.token(301, at: 3)], from: 2 * ParakeetWindow.frameSamples)
        #expect(words.map(\.text) == [" oneteen", " two"])
    }

    /// The vocabulary file is read whole or refused: every id up to the blank, none missing.
    @Test func theVocabularyIsReadWholeOrRefused() throws {
        let whole = Dictionary(uniqueKeysWithValues: (0..<ParakeetWindow.blank).map { (String($0), " p\($0)") })
        _ = try ParakeetVocabulary(json: JSONEncoder().encode(whole))
        var gap = whole
        gap["7"] = nil
        gap["8192"] = " extra"
        #expect(throws: ParakeetLoadError.vocabulary("it has no piece for id 7 of 8192")) { try ParakeetVocabulary(json: JSONEncoder().encode(gap)) }
        #expect(throws: ParakeetLoadError.self) { try ParakeetVocabulary(json: Data("[]".utf8)) }
    }
}

@Suite struct ParakeetWindowTests {
    /// Audio one window holds is one span, from where the pass starts.
    @Test func whatOneWindowHoldsIsOneSpan() {
        #expect(ParakeetWindow.spans(of: [Float](repeating: 0.1, count: 100_000), from: 4_000) == [4_000..<100_000])
    }

    /// Longer audio is cut at the quietest frame of each window's last two seconds, and every span
    /// fits the encoder.
    @Test func longAudioIsCutInItsPause() {
        var samples = [Float](repeating: 0.5, count: 400_000)
        let pause = 180 * ParakeetWindow.frameSamples
        for index in pause..<pause + ParakeetWindow.frameSamples { samples[index] = 0 }
        let spans = ParakeetWindow.spans(of: samples, from: 0)
        #expect(spans == [0..<pause, pause..<400_000])
        #expect(spans.allSatisfy { $0.lowerBound % ParakeetWindow.frameSamples == 0 })
        #expect(spans.allSatisfy { $0.count <= ParakeetWindow.samples })
    }

    /// With no pause to find, the cut still falls within the window's last two seconds.
    @Test func audioWithNoPauseIsStillCutToFit() {
        let spans = ParakeetWindow.spans(of: [Float](repeating: 0.5, count: 700_000), from: 0)
        #expect(spans.count == 3)
        #expect(spans.allSatisfy { $0.count <= ParakeetWindow.samples })
        #expect(spans.dropLast().allSatisfy { $0.count >= ParakeetWindow.samples - AudioClip.sampleCount(for: 2) - ParakeetWindow.frameSamples })
        #expect(spans.last?.upperBound == 700_000)
    }
}

@Suite struct ParakeetReaderTests {
    static let cut = 20 * ParakeetWindow.frameSamples
    static let samples = [Float](repeating: 0.1, count: cut + 8 * ParakeetWindow.frameSamples)
    /// The prefix a pass starts from: " two", confirmed over the frame at the cut.
    static let prefix = [Transcript.Word(text: " two", time: AudioClip.duration(for: cut)...AudioClip.duration(for: cut + ParakeetWindow.frameSamples), confidence: 0.5)]

    static func read(_ spoken: [Int: (token: Int, duration: Int)], prefix: [Transcript.Word] = Self.prefix) throws(TranscriptionFailure) -> [Transcript.Word] {
        try ParakeetReader(network: ScriptedNetwork(spoken: spoken), vocabulary: vocabulary).read(Hearing.Pass(samples: samples, arrived: 0, prefix: prefix))
    }

    /// A pass reads from half a second before its cut, so the first confirmed word is heard with the
    /// sound before it, and returns the words from the cut on: the prefix first, as Hearing reads it.
    @Test func aPassReadsFromItsLeadInAndReturnsFromItsCut() throws {
        let words = try Self.read([Self.cut - 5 * ParakeetWindow.frameSamples: (300, 1), Self.cut: (301, 1), Self.cut + 3 * ParakeetWindow.frameSamples: (302, 1)])
        #expect(words.map(\.text) == [" two", " three"])
        #expect(words.first?.time.lowerBound == AudioClip.duration(for: Self.cut))
    }

    /// Parakeet hears its prefix again rather than being told it, so a prefix heard another way
    /// is still the prefix as told, and not a new word after it.
    @Test func aPrefixHeardAnotherWayIsTheOneTold() throws {
        let words = try Self.read([Self.cut: (303, 1), Self.cut + 3 * ParakeetWindow.frameSamples: (302, 1)])
        #expect(words.map(\.text) == [" two", " three"])
    }

    /// The last prefix word takes the punctuation this pass hears on it, though the punctuation
    /// sounds after the prefix's end.
    @Test func thePrefixTakesThePunctuationThisPassHears() throws {
        let words = try Self.read([Self.cut: (301, 1), Self.cut + ParakeetWindow.frameSamples: (305, 1), Self.cut + 3 * ParakeetWindow.frameSamples: (302, 1)])
        #expect(words.map(\.text) == [" two.", " three"])
    }

    /// A new word the joint emits on the prefix's last frame, after the prefix's last word, is a
    /// new word and not a hearing of the prefix.
    @Test func aWordOnThePrefixsLastFrameAfterItIsNew() throws {
        let words = try Self.read([Self.cut: (301, 0), Self.cut + 1: (302, 1)])
        #expect(words.map(\.text) == [" two", " three"])
    }

    /// A pass that starts at the utterance's first sample has no lead-in to read before it, and
    /// decodes no frame past its audio.
    @Test func aPassFromTheStartReadsFromTheStart() throws {
        let reader = ParakeetReader(network: ScriptedNetwork(spoken: [0: (300, 1)]), vocabulary: vocabulary)
        let (tokens, facts) = try reader.decode([Float](repeating: 0.1, count: 12_800), from: 0)
        #expect(tokens.map(\.id) == [300])
        #expect(facts == ParakeetPassFacts(samples: 12_800, windows: 1, frames: 10, blanks: 9, tokens: 1, forcedAdvances: 0))
    }

    /// A reading the network cannot make into words fails the pass as unreadable.
    @Test func aPassFailsAsItsReading() {
        #expect {
            _ = try Self.read([Self.cut + 3 * ParakeetWindow.frameSamples: (0, 1)], prefix: [])
        } throws: { error in
            if case TranscriptionFailure.unreadable(.parakeet(.controlToken(id: 0, _))) = error { true } else { false }
        }
    }
}

@Suite struct ParakeetTranscriberTests {
    /// A tone a second and a half long, its words spoken across it.
    static let speech = AudioClip(samples: (0..<24_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / AudioClip.sampleRate)) })
    static let network = ScriptedNetwork(spoken: [1_280: (300, 1), 5_120: (301, 1), 8_960: (302, 1), 12_800: (303, 1)])

    static let contract = EngineContract(engine: { turns in
        let engine = ParakeetTranscriber(model: .parakeet(.tdtV3), network: network, vocabulary: vocabulary, turns: turns)
        return (engine, engine.served)
    }, speech: speech, refused: Vocabulary([try! Vocabulary.Term("Fryslie")]))

    @Test(.timeLimit(.minutes(1)), arguments: EngineContract.Statement.allCases)
    func theEngineKeepsTheStatement(_ statement: EngineContract.Statement) async throws {
        #expect(try await Self.contract.disagreements(with: statement) == [])
    }

    /// The whole road through the engine: the clip's words, in order, each once.
    @Test func aClipIsHeardAsItsWords() async throws {
        let engine = ParakeetTranscriber(model: .parakeet(.tdtV3), network: Self.network, vocabulary: vocabulary, turns: EngineTurns())
        let heard = try await engine.transcribe(Self.speech, expecting: .empty)
        #expect(heard.transcript.text == " one two three four")
    }

    /// Parakeet takes no vocabulary: a term is refused as the config refuses it, naming the model.
    @Test func aVocabularyIsRefusedNamingTheModel() async {
        let engine = ParakeetTranscriber(model: .parakeet(.tdtV3), network: Self.network, vocabulary: vocabulary, turns: EngineTurns())
        let result = await Result { () async throws(TranscriptionFailure) in try await engine.transcribe(Self.speech, expecting: Vocabulary([try! Vocabulary.Term("Fryslie")])) }
        guard case .failure(.vocabulary(.engineTakesNone(.parakeet(.tdtV3)))) = result else {
            Issue.record("a term was answered \(result)")
            return
        }
    }
}

/// The adapter over four stub models built by scripts/make-parakeet-stubs with the published
/// names, element types and shapes, and arithmetic that shows each input reaching its output.
@Suite struct CoreMLParakeetTests {
    static func stubs() throws -> URL {
        try #require(Bundle.module.url(forResource: "parakeet-stub", withExtension: nil, subdirectory: "Fixtures"))
    }

    /// The audio and its length reach the encoder: a second of audio is 13 frames of 80 ms, each
    /// frame's features its own index.
    @Test func aWindowIsEncodedIntoItsFrames() async throws {
        let network = try await CoreMLParakeet(folder: Self.stubs(), computeUnits: .cpuOnly)
        let window = try network.encode([Float](repeating: 0.25, count: 16_000)[...])
        #expect(window.frames.count == 13)
        #expect(window.frames[5].features.count == 1024)
        #expect(Set(window.frames[5].features) == [5])
    }

    /// The token and the state reach the predictor, and its output and new state come back.
    @Test func aTokenIsPredictedFromItsState() async throws {
        let network = try await CoreMLParakeet(folder: Self.stubs(), computeUnits: .cpuOnly)
        let (prediction, state) = try network.predict(7, from: network.startState)
        #expect(prediction.features == [Float](repeating: 7, count: 640))
        #expect(state.hidden == [Float](repeating: 1, count: ParakeetInterface.stateCount))
        #expect(state.cell == [Float](repeating: 2, count: ParakeetInterface.stateCount))
    }

    /// The frame and the prediction both reach the joint, and its three answers come back.
    @Test func theJointReadsItsFrameAndPrediction() async throws {
        let network = try await CoreMLParakeet(folder: Self.stubs(), computeUnits: .cpuOnly)
        let (prediction, _) = try network.predict(3, from: network.startState)
        let step = try network.joint(EncodedFrame(features: [Float](repeating: 5, count: 1024)), prediction)
        #expect(step == JointStep(token: 5, probability: 0.5, duration: 3))
    }

    /// A model whose interface is not the published one is refused at load, naming what differs.
    @Test func aModelWithAnotherInterfaceIsRefused() throws {
        let joint = try #require(ParakeetInterface.published[ParakeetModel.joint])
        var found = joint.features
        #expect(throws: Never.self) { try joint.check("JointDecision", found) }
        found["duration"] = nil
        #expect(throws: ParakeetLoadError.interface(model: "JointDecision", "it has no feature duration")) { try joint.check("JointDecision", found) }
        found = joint.features
        found["token_id"] = ParakeetInterface.Feature(type: .float32, shape: [1, 1, 1])
        #expect(throws: ParakeetLoadError.interface(model: "JointDecision", "token_id is Float32 [1, 1, 1] where the decoder reads Int32 [1, 1, 1]")) { try joint.check("JointDecision", found) }
    }
}

/// The bench's way to a Parakeet model, over the stubs installed as the store installs the real
/// one: `LoadedEngine(loading:)`, the one load the app and `Bench.loadInPlace` share, and the
/// harness holding a fixture on what it loads. The words are the stubs' arithmetic decoded by
/// the TDT rules: a token per frame index, a duration index of the fed token mod 5, the blank's 2.
@Suite struct InstalledParakeetTests {
    @Test func theBenchHoldsAFixtureOnAnInstalledParakeetModel() async throws {
        let scratch = try ScratchStore(files: [:])
        let folder = scratch.root.appending(components: "models", "FluidInference", "parakeet-tdt-0.6b-v3-coreml")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: CoreMLParakeetTests.stubs(), to: folder)
        // Every id a plain word, so whatever token the stubs' arithmetic emits is read.
        let pieces = Dictionary(uniqueKeysWithValues: (0..<ParakeetWindow.blank).map { (String($0), " w\($0)") })
        try JSONEncoder().encode(pieces).write(to: folder.appending(path: ParakeetModel.vocabulary))
        try Manifest(recording: folder, relativeTo: scratch.root).write(to: scratch.root.appending(components: "installed", "parakeet-tdt-0.6b-v3.json"))
        let store = ModelStore(directory: scratch.root)
        let fixture = try Fixture(name: "second", clip: AudioClip(samples: [Float](repeating: 0.25, count: 16_000)), reference: Self.heard)
        let report = try await LatencyHarness.measure([fixture], arrivals: [.batch], servings: [.idle], reruns: 0, expecting: .empty, on: ContinuousClock()) {
            let turns = EngineTurns()
            let engine = try await LoadedEngine(loading: store.installedModel(Model.parakeet(.tdtV3)), turns: turns)
            #expect(engine.model == .parakeet(.tdtV3))
            return LatencyHarness.Engine(dictation: engine.dictation, served: engine.served, turns: turns)
        }
        let row = try #require(report.fixtures.first)
        #expect(report.fixtures.count == 1)
        #expect(row.transcript.text == " \(Self.heard)")
        #expect(row.wordErrorRate.errors == 0)
    }

    static let heard = "w0 w2 w2 w4 w6 w10 w11 w11 w12 w13 w15"
}
