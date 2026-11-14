import AppKit
import Bench
import GrammaticalNumber
import LowTalkerCore

/// The Benchmark window: every option `LowTalker --bench` takes, a run started and cancelled
/// here, and its table, which copies as the text `LowTalker --bench` prints.
///
/// The IMK rule against windows binds the input method's process, not this one.
///
/// [LAW:one-type-per-behavior] Its controls build the `BenchOptions` the flags parse into,
/// and the run is `BenchRuns`'s, which logs it; the window keeps nothing but what it shows.
@MainActor
final class BenchWindow: NSObject, NSTableViewDataSource {
    private let runs: BenchRuns
    private let carried: ModelStore?
    private let folders = BenchFolders()
    private let defaults = UserDefaults.standard

    /// The rows of the run shown, the one in progress or the last.
    private var rows: [BenchRow] = []

    init(runs: BenchRuns, carried: ModelStore?) {
        self.runs = runs
        self.carried = carried
    }

    // MARK: - what was picked

    /// Remembered by path beside the bookmark that lets the folder be read, so the window
    /// reopens on the folders it last ran over.
    private static let fixturesKey = "bench.fixtures"
    private static let storeKey = "bench.store"

    private var fixtures: URL? {
        defaults.string(forKey: Self.fixturesKey).map(URL.init(fileURLWithPath:))
    }

    private var store: BenchStore {
        defaults.string(forKey: Self.storeKey).map { .folder(URL(fileURLWithPath: $0)) } ?? .carried
    }

    // MARK: - controls

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Benchmark"
        window.isReleasedWhenClosed = false
        window.contentView = page
        return window
    }()

    private lazy var page: NSStackView = {
        let page = NSStackView(views: [
            line("Fixtures:", fixturesLabel, button("Choose…", #selector(chooseFixtures))),
            line("Model store:", storeLabel, button("Choose…", #selector(chooseStore)), button("Use Carried", #selector(useCarried))),
            line("Models:", modelBoxes),
            line("Delivery:", batch, streamed),
            line("Serving:", idle, served),
            line("Runs:", runsLabel, runsStepper),
            line("Vocabulary:", vocabulary),
            line("", runButton, cancelButton, button("Copy Table", #selector(copyTable)), status),
            tableScroll,
        ])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        tableScroll.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -40).isActive = true
        return page
    }()

    private let fixturesLabel = NSTextField(labelWithString: "")
    private let storeLabel = NSTextField(labelWithString: "")
    private let modelBoxes = NSStackView()
    private lazy var batch = check(LatencyHarness.Arrival.batch.rawValue, on: true)
    private lazy var streamed = check(LatencyHarness.Arrival.streamed.rawValue, on: true)
    private lazy var idle = check(LatencyHarness.Serving.idle.rawValue, on: true)
    private lazy var served = check(LatencyHarness.Serving.served.rawValue, on: false)
    private let runsLabel = NSTextField(labelWithString: "3")
    private lazy var runsStepper: NSStepper = {
        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 99
        stepper.integerValue = 3
        stepper.target = self
        stepper.action = #selector(runsChanged)
        return stepper
    }()
    private let vocabulary: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "terms the speaker is expected to say, comma-separated"
        field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return field
    }()
    private lazy var runButton = button("Run", #selector(run))
    private lazy var cancelButton = button("Cancel", #selector(cancel))
    private let status = NSTextField(wrappingLabelWithString: "")

    private lazy var table: NSTableView = {
        let table = NSTableView()
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        return table
    }()

    private lazy var tableScroll: NSScrollView = {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return scroll
    }()

    private func line(_ title: String, _ views: NSView...) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let line = NSStackView(views: [label] + views)
        line.orientation = .horizontal
        line.spacing = 8
        return line
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func check(_ title: String, on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        return box
    }

    // MARK: - showing

    func show() {
        draw()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Everything but the table, from what is picked and whether a run is going.
    private func draw() {
        fixturesLabel.stringValue = fixtures?.path(percentEncoded: false) ?? "none picked"
        switch store {
        case .carried: storeLabel.stringValue = "the one this app carries"
        case .folder(let folder): storeLabel.stringValue = folder.path(percentEncoded: false)
        }
        drawModels()
        runButton.isEnabled = !runs.isRunning
        cancelButton.isEnabled = runs.isRunning
    }

    /// A box per model the store has recorded, checked as the person left it; while none of
    /// the store's models is, the default model, or else the first.
    /// [LAW:no-silent-failure] A store that cannot be listed says why where the boxes go.
    private func drawModels() {
        let checked = Set(checkedModels)
        modelBoxes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        do {
            let recorded = try recordedModels()
            let fallback = recorded.contains(.default) ? Model.default : recorded.first
            let keeps = recorded.contains(where: checked.contains)
            for model in recorded {
                modelBoxes.addArrangedSubview(check(model.rawValue, on: keeps ? checked.contains(model) : model == fallback))
            }
        } catch {
            modelBoxes.addArrangedSubview(NSTextField(labelWithString: "this store cannot be listed: \(error)"))
        }
    }

    /// The models whose boxes are checked, in the order the store lists them.
    private var checkedModels: [Model] {
        modelBoxes.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.state == .on }.compactMap { Model(rawValue: $0.title) }
    }

    private func recordedModels() throws -> [Model] {
        switch store {
        case .carried:
            guard let carried else { throw CarriesNoStore() }
            return try carried.recordedModels()
        case .folder(let folder):
            return try folders.open(folder).reading { try ModelStore(directory: $0).recordedModels() }
        }
    }

    // MARK: - actions

    @objc private func chooseFixtures() {
        pick("Choose a folder of <name>.wav beside <name>.txt", key: Self.fixturesKey)
    }

    @objc private func chooseStore() {
        pick("Choose a model store", key: Self.storeKey)
    }

    @objc private func useCarried() {
        defaults.removeObject(forKey: Self.storeKey)
        draw()
    }

    /// An open panel for a folder, which is the sandbox's way of letting the app read it,
    /// remembered as a bookmark so this process and `LowTalker --bench` can read it again.
    private func pick(_ message: String, key: String) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try folders.remember(folder)
            defaults.set(folder.path(percentEncoded: false), forKey: key)
        } catch {
            status.stringValue = "could not remember \(folder.path(percentEncoded: false)): \(error)"
        }
        draw()
    }

    @objc private func runsChanged() {
        runsLabel.stringValue = "\(runsStepper.integerValue)"
    }

    @objc private func run() {
        do {
            let options = try options()
            rows = []
            table.tableColumns.forEach(table.removeTableColumn)
            table.reloadData()
            status.stringValue = "starting"
            try runs.start(options.description, work: { [folders, carried] emit in
                try await Bench.run(options, folders: folders, carried: carried, load: Bench.loadInPlace, emit: emit)
            }, events: { [weak self] in self?.shown($0) }, ended: { [weak self] in self?.ended($0) })
        } catch {
            status.stringValue = "\(error)"
        }
        draw()
    }

    @objc private func cancel() {
        runs.cancel()
        status.stringValue = "cancelling at the next hold"
    }

    @objc private func copyTable() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BenchRow.table(rows) + "\n", forType: .string)
    }

    /// The options the controls show, or why they are not a run.
    private func options() throws -> BenchOptions {
        guard let fixtures else { throw NothingPicked() }
        let models = checkedModels
        let terms = try vocabulary.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try Vocabulary.Term($0) }
        let plan = try BenchPlan(
            models: models,
            arrivals: [(batch, LatencyHarness.Arrival.batch), (streamed, .streamed)].filter { $0.0.state == .on }.map(\.1),
            servings: [(idle, LatencyHarness.Serving.idle), (served, .served)].filter { $0.0.state == .on }.map(\.1),
            runs: runsStepper.integerValue,
            vocabulary: Vocabulary(terms))
        return BenchOptions(fixtures: fixtures, store: store, plan: plan)
    }

    private struct NothingPicked: Error, CustomStringConvertible {
        var description: String { "choose a fixtures folder first" }
    }

    private func shown(_ event: BenchEvent) {
        switch event {
        case .loading(let model):
            status.stringValue = "loading \(model), minutes the first time on this Mac"
        case .row(let row):
            if table.tableColumns.isEmpty {
                for cell in row.cells {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(cell.name))
                    column.title = cell.name
                    column.width = cell.name == "fixture" ? 180 : 80
                    table.addTableColumn(column)
                }
            }
            rows.append(row)
            table.reloadData()
            status.stringValue = "\(counted(rows.count, "row", "rows")); \(row.narration)"
        }
    }

    private func ended(_ ending: BenchEnding) {
        status.stringValue = BenchRuns.describe(ending, rows: rows.count)
        draw()
    }

    // MARK: - the table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        rows[row].cells.first { $0.name == tableColumn?.identifier.rawValue }?.value
    }
}
