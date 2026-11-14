import ArgumentParser
import Foundation
import LowTalkerCore

/// `LowTalker --bench`'s flags: every option the Benchmark window has, so a run from the
/// window and one from the app's binary can be asked for alike and their tables compared.
///
/// [LAW:one-type-per-behavior] They parse into the `BenchOptions` the window builds, and
/// nothing else, so the two surfaces cannot drift apart in what they accept.
public struct BenchFlags: ParsableArguments {
    @Argument(help: "A folder of <name>.wav beside <name>.txt, the reference text. Picked once in the Benchmark window.", transform: URL.init(fileURLWithPath:))
    var fixtures: URL

    @Option(name: .customLong("model"), help: "A model the store holds. Repeat for several.")
    var models: [Model] = [.default]

    @Option(name: .customLong("delivery"), help: "How a hold's audio reaches the engine: batch (the whole clip at key-up) or streamed (a microphone buffer at a time). Repeat for both.")
    var arrivals: [LatencyHarness.Arrival] = LatencyHarness.Arrival.allCases

    @Option(name: .customLong("serving"), help: "What else asks the engine during each hold: idle (nothing) or served (a 40 s upload decoding at key-down, another arriving mid-hold, and a stream throughout). Repeat for both.")
    var servings: [LatencyHarness.Serving] = [.idle]

    @Option(help: "How many times to hold each fixture, per delivery. The first hold after a load is reported apart from the median.")
    var runs: Int = 3

    @Option(name: .customLong("models-dir"), help: "A model store picked once in the Benchmark window. Defaults to the store the app carries.", transform: URL.init(fileURLWithPath:))
    var store: URL?

    @Option(name: .customLong("vocabulary"), help: "A name or term the speaker is expected to say, spelled as it should be written. Repeat for several.", transform: Vocabulary.Term.init)
    var terms: [Vocabulary.Term] = []

    public init() {}

    /// The options `arguments` ask for, or the refusal ArgumentParser words for them.
    public static func options(_ arguments: [String]) throws -> BenchOptions {
        let flags = try parse(arguments)
        do {
            let plan = try BenchPlan(models: flags.models, arrivals: flags.arrivals, servings: flags.servings, runs: flags.runs, vocabulary: Vocabulary(flags.terms))
            return BenchOptions(fixtures: flags.fixtures, store: flags.store.map(BenchStore.folder) ?? .carried, plan: plan)
        } catch {
            throw ValidationError("\(error)")
        }
    }
}

/// [LAW:parse-dont-validate] Each spelling is parsed into a case at the command line, so one
/// that names nothing is refused before any model loads.
extension LatencyHarness.Arrival: ExpressibleByArgument {}
extension LatencyHarness.Serving: ExpressibleByArgument {}
extension Model: ExpressibleByArgument {}
