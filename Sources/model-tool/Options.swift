import ArgumentParser
import Foundation
import LowTalkerCore
import ModelInstall
import Synchronization

/// Which models and which store, for every subcommand that works on models.
///
/// [LAW:one-source-of-truth] The default store is the one `make app` copies each bundle's
/// models out of, and the default models are the ones a bundle carries, so a download here is
/// what the next build carries.
struct ModelOptions: ParsableArguments {
    @Option(help: "One model: a folder name in the whisperkit-coreml repo, or a Parakeet model. Defaults to every model a bundle carries.")
    var model: Model?

    var models: [Model] { model.map { [$0] } ?? Model.carried }

    @Option(name: .customLong("models-dir"), help: "Where models are stored. Defaults to low-talker's store under Application Support, which `make app` copies a bundle's model out of.", transform: URL.init(fileURLWithPath:))
    var modelsDirectory: URL?

    func store() throws -> ModelStore {
        try modelsDirectory.map(ModelStore.init(directory:)) ?? ModelStore.applicationSupport()
    }
}

extension Model: ExpressibleByArgument {}

/// [LAW:parse-dont-validate] Models at commits are revisions on huggingface.co, a URL with an
/// http or https scheme is a published base, and anything else is a path to a store, so
/// the one flag cannot be read two ways and a revision cannot be asked of a copy.
extension ModelSource: ExpressibleByArgument {
    public init?(argument: String) {
        if let revisions = ModelRevisions(argument) {
            self = .huggingFace(revisions)
        } else if let url = URL(string: argument), ["http", "https"].contains(url.scheme) {
            self = .published(url)
        } else {
            self = .store(ModelStore(directory: URL(fileURLWithPath: argument)))
        }
    }

    public var defaultValueDescription: String { description }
}

/// Narrates an install on stderr, one line each time the phase's own words change, so
/// a download prints once per whole percent. Stdout stays the subcommand's own, which is
/// what the scripts read.
final class PhaseReporter: Sendable {
    private let lastLine = Mutex<String?>(nil)

    func report(_ phase: ModelStore.InstallPhase) {
        let line = phase.description
        let changed = lastLine.withLock { last in
            defer { last = line }
            return line != last
        }
        if changed {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
}
