import ArgumentParser
import Foundation
import LowTalkerCore
import ModelInstall

/// The model store, for the build: which model is the default, which commits `main` names
/// for it, whether a store holds it whole, and fetching or packing it. `make app`,
/// scripts/sbom, scripts/sign-release and the release and model-cache workflows run it.
///
/// [LAW:one-way-deps] Built from this tree and run only by the build. It is in no product
/// and project.yml never copies it into a bundle, so nothing a person installs can reach
/// ModelInstall through it.
@main
struct ModelTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model-tool",
        abstract: "Name, check, fetch and pack the Whisper model a bundle carries.",
        subcommands: [Status.self, Download.self, Pack.self, Default.self, Revision.self]
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

    /// The Hugging Face commits `main` names for the model now, for scripts: a release
    /// keys its cached store by them and fetches at them with `download --from`, so a
    /// moved upstream is a new entry rather than the old one kept until eviction.
    /// [LAW:one-source-of-truth]
    struct Revision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the Hugging Face commits main names for the model now, as <weights>-<tokenizer>, which `download --from` takes."
        )

        @Option(help: "A model folder name in the whisperkit-coreml repo.")
        var model: Model = .default

        func run() async throws {
            print(try await ModelRevision.upstream(of: model))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether the model is installed. Exits 1 when it is not, so scripts can test."
        )

        @OptionGroup var options: ModelOptions

        func run() throws {
            let store = try options.store()
            print("store: \(store.directory.path)")
            switch try store.presence(of: options.model) {
            case .installed(let installed):
                print("installed: \(installed.folder.path)")
            case .missing:
                print("missing: \(options.model)")
                throw ExitCode(1)
            case .damaged(let damages):
                print("damaged: \(damages.map(\.description).joined(separator: "; "))")
                throw ExitCode(1)
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the model into the store, or finish an install that stopped."
        )

        @OptionGroup var options: ModelOptions

        @Option(name: .customLong("from"), help: "Where to take a model the store lacks: huggingface.co at a revision `revision` printed, an http(s) base URL serving <model>.zip, as `pack` writes them, or a directory holding another model store. Defaults to huggingface.co at the revision `main` names.")
        var source: ModelSource = .huggingFace(nil)

        func run() async throws {
            let reporter = PhaseReporter()
            let installed = try await options.store().install(options.model, from: source, phase: reporter.report)
            print("installed: \(installed.folder.path)")
        }
    }

    /// The archive a published base serves, made from a model this store holds, so a
    /// Mac that cannot reach huggingface.co can install it with `download --from`.
    struct Pack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write <model>.zip, a store holding the installed model alone, for a published base to serve."
        )

        @OptionGroup var options: ModelOptions

        @Option(name: .customLong("to"), help: "The directory to write <model>.zip into.", transform: URL.init(fileURLWithPath:))
        var directory: URL

        func run() async throws {
            let reporter = PhaseReporter()
            let archive = try await options.store().pack(options.model, into: directory, phase: reporter.report)
            print("packed: \(archive.path)")
        }
    }
}
