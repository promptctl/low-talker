import Foundation
import LowTalkerCore

/// What a bench run measures: which models, held which ways, how often, told what to expect.
/// Everything but where the fixtures and the models are read from, which is the surface's to
/// say: the app reads them from folders a person picked.
///
/// [LAW:parse-dont-validate] Made only through `init`, which refuses an empty list, a run count
/// under one, and a vocabulary a model refuses without reading a file, so a plan in hand
/// always measures something and no model loads only to fail every hold.
public struct BenchPlan: Equatable, Sendable {
    public let models: [Model]
    public let arrivals: [LatencyHarness.Arrival]
    public let servings: [LatencyHarness.Serving]
    /// How many times each fixture is held, per delivery and serving; the first hold after a
    /// load is reported apart from the median.
    public let runs: Int
    public let vocabulary: Vocabulary

    public init(
        models: [Model],
        arrivals: [LatencyHarness.Arrival],
        servings: [LatencyHarness.Serving],
        runs: Int,
        vocabulary: Vocabulary
    ) throws(BenchOptionsError) {
        guard !models.isEmpty else { throw .nothingChosen("model") }
        guard !arrivals.isEmpty else { throw .nothingChosen("delivery") }
        guard !servings.isEmpty else { throw .nothingChosen("serving") }
        guard runs >= 1 else { throw .tooFewRuns(runs) }
        for model in models {
            do throws(VocabularyError) { _ = try PromptEncoder.withoutFiles(model)?.prompt(for: vocabulary) } catch { throw .vocabulary(error) }
        }
        self.models = models
        self.arrivals = arrivals
        self.servings = servings
        self.runs = runs
        self.vocabulary = vocabulary
    }
}

/// Where a bench run in the app takes its models from.
public enum BenchStore: Equatable, Sendable {
    /// The store the app's bundle carries, which it may always read.
    case carried
    /// A store a person picked, read through its bookmark.
    case folder(URL)
}

/// A bench run as the app's window and `LowTalker --bench` both ask for one.
/// [LAW:one-type-per-behavior] One value from either surface, so the window and the flags
/// cannot offer different options.
public struct BenchOptions: Equatable, Sendable {
    /// A folder of `<name>.wav` beside `<name>.txt`, read through its bookmark.
    public let fixtures: URL
    public let store: BenchStore
    public let plan: BenchPlan

    public init(fixtures: URL, store: BenchStore, plan: BenchPlan) {
        self.fixtures = fixtures
        self.store = store
        self.plan = plan
    }
}

public enum BenchOptionsError: Error, Equatable, CustomStringConvertible {
    case nothingChosen(String)
    case tooFewRuns(Int)
    case vocabulary(VocabularyError)

    public var description: String {
        switch self {
        case .nothingChosen(let what): "choose at least one \(what)"
        case .tooFewRuns(let runs): "runs must be at least 1, not \(runs)"
        case .vocabulary(let error): "\(error)"
        }
    }
}

extension BenchOptions: CustomStringConvertible {
    /// The options as the log line that starts a run states them, `name=value` apart by spaces.
    public var description: String {
        let store = switch store {
        case .carried: "carried"
        case .folder(let folder): folder.path(percentEncoded: false)
        }
        return [
            "fixtures=\(fixtures.path(percentEncoded: false))",
            "store=\(store)",
            "models=\(plan.models.map(\.rawValue).joined(separator: ","))",
            "deliveries=\(plan.arrivals.map(\.rawValue).joined(separator: ","))",
            "servings=\(plan.servings.map(\.rawValue).joined(separator: ","))",
            "runs=\(plan.runs)",
            "vocabulary=\(plan.vocabulary.terms.map(\.description).joined(separator: ","))",
        ].joined(separator: " ")
    }
}
