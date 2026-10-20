import Bench
import Foundation
import LowTalkerCore

/// `LowTalker --bench …` from a terminal: the Benchmark window's run, printed as its
/// tab-separated table, and nothing else. The process never reaches
/// NSApplicationMain, so it draws no menu-bar item, registers no hotkey port and talks to no
/// input method; it loads the models the run asks for and exits when the run ends.
///
/// Sandboxed like the app it is, it reads the fixtures and a store only through the bookmarks
/// the window's open panels left; a folder the window never had refuses the run by name.
@MainActor
enum BenchTerminal {
    /// The flags after `--bench`. Stdout is the table, stderr narrates each load and what the
    /// engine heard, and the exit status is 0 for a finished run, 1 for a run that failed - a
    /// fixture folder that would not read among them - and ArgumentParser's for bad flags.
    static func run(_ arguments: [String]) -> Never {
        let options: BenchOptions
        do { options = try BenchFlags.options(arguments) } catch { BenchFlags.exit(withError: error) }
        var printedHeader = false
        do {
            // A run of its own in a fresh process, with turns nothing else decodes through, so
            // neither refusal `start` has can arise.
            try BenchRuns(turns: EngineTurns()).start(options.description, work: { emit in
                try await Bench.run(options, folders: BenchFolders(), carried: ModelStore.carried(by: .main), load: Bench.loadInPlace, emit: emit)
            }, events: { event in
                switch event {
                case .loading(let model):
                    printToStandardError("model \(model)")
                case .row(let row):
                    printToStandardError("  \(row.narration)")
                    if !printedHeader { print(row.header) }
                    printedHeader = true
                    print(row.line)
                    // A row can be minutes apart from the next; a reader of the pipe sees each
                    // as it lands rather than all of them at exit.
                    fflush(stdout)
                }
            }, ended: { ending in
                switch ending {
                case .finished: exit(0)
                case .stopped: exit(1)
                case .failed(let reason):
                    printToStandardError("LowTalker --bench: \(reason)")
                    exit(1)
                }
            })
        } catch {
            preconditionFailure("a fresh process has no run going: \(error)")
        }
        // The run's task and its events are main-actor work; this hands the main thread to
        // the queue they run on until `ended` exits.
        dispatchMain()
    }

    private static func printToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
