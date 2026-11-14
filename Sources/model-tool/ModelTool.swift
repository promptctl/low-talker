import ArgumentParser
import Foundation
import LowTalkerCore
import ModelInstall

/// The model store, for the build: which model is the default and which models a bundle
/// carries, which commits `main` names for them, whether a store holds them whole, and fetching
/// or packing them. `make app`,
/// scripts/sbom, scripts/sign-release and the release and model-cache workflows run it.
///
/// [LAW:one-way-deps] Built from this tree and run only by the build. It is in no product
/// and project.yml never copies it into a bundle, so nothing a person installs can reach
/// ModelInstall through it.
@main
struct ModelTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model-tool",
        abstract: "Name, check, fetch and pack the models a bundle carries.",
        subcommands: [Status.self, Download.self, Pack.self, Default.self, Carried.self, Revision.self]
    )

    /// The model a release carries and a launch loads where nothing names another, by
    /// name and nothing else, for scripts: `scripts/sbom` lists it as a component under
    /// this name, and reading it here rather than copying the constant keeps the SBOM on
    /// the model the code actually loads. [LAW:one-source-of-truth]
    struct Default: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the name of the model the app loads where nothing names another."
        )

        func run() {
            print(Model.default.rawValue)
        }
    }

    /// The models a bundle carries and their parts, one model a line, for scripts: `scripts/sbom` lists each
    /// as a component, read here rather than copied so the SBOM names what the app can load.
    /// [LAW:one-source-of-truth]
    struct Carried: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the models a bundle carries, one a line: its name, then the parts a store installs for it."
        )

        func run() {
            for model in Model.carried { print(([model.rawValue] + model.parts.map(\.rawValue)).joined(separator: " ")) }
        }
    }

    /// The Hugging Face commits `main` names for the models now, for scripts: a release
    /// keys its cached store by them and fetches at them with `download --from`, so a
    /// moved upstream is a new entry rather than the old one kept until eviction.
    /// [LAW:one-source-of-truth]
    struct Revision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the Hugging Face commits main names for the models now, as <model>@<revision> joined by +, which `download --from` takes."
        )

        @Option(help: "One model. Defaults to every model a bundle carries.")
        var model: Model?

        func run() async throws {
            print(try await ModelRevisions.upstream(of: model.map { [$0] } ?? Model.carried))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether each model is installed. Exits 1 when one is not, so scripts can test."
        )

        @OptionGroup var options: ModelOptions

        func run() throws {
            let store = try options.store()
            print("store: \(store.directory.path)")
            // Every model is reported before the exit, so one run names everything missing.
            var whole = true
            for model in options.models {
                switch try store.presence(of: model) {
                case .installed(let installed):
                    print("installed: \(installed.folder.path)")
                case .missing:
                    print("missing: \(model)")
                    whole = false
                case .damaged(let damages):
                    print("damaged: \(model): \(damages.map(\.description).joined(separator: "; "))")
                    whole = false
                }
            }
            if !whole { throw ExitCode(1) }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install each model into the store, or finish an install that stopped."
        )

        @OptionGroup var options: ModelOptions

        @Option(name: .customLong("from"), help: "Where to take a model the store lacks: huggingface.co at the revisions `revision` printed, an http(s) base URL serving <model>.zip, as `pack` writes them, or a directory holding another model store. Defaults to huggingface.co at the revisions `main` names.")
        var source: ModelSource = .huggingFace(nil)

        func run() async throws {
            let reporter = PhaseReporter()
            let store = try options.store()
            for model in options.models {
                let installed = try await store.install(model, from: source, phase: reporter.report)
                print("installed: \(installed.folder.path)")
            }
        }
    }

    /// The archive a published base serves, made from a model this store holds, so a
    /// Mac that cannot reach huggingface.co can install it with `download --from`.
    struct Pack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write <model>.zip for each model, a store holding that installed model alone, for a published base to serve."
        )

        @OptionGroup var options: ModelOptions

        @Option(name: .customLong("to"), help: "The directory to write <model>.zip into.", transform: URL.init(fileURLWithPath:))
        var directory: URL

        func run() async throws {
            let reporter = PhaseReporter()
            let store = try options.store()
            for model in options.models {
                let archive = try await store.pack(model, into: directory, phase: reporter.report)
                print("packed: \(archive.path)")
            }
        }
    }
}
