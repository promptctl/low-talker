import AppKit
import Identity
import Onboarding
import os

/// The guided setup's window: one requirement at a time, explained in plain words before
/// the person presses the button that makes macOS ask.
///
/// [LAW:one-source-of-truth] It draws `Readiness` and keeps nothing of its own but the walk's
/// skipped steps. Every page is drawn from a reading taken as it is drawn: when the window
/// opens, when it comes back to the front - which is when a person returns from System
/// Settings - and after every request. A grant made anywhere clears its step at the next of
/// those, with no relaunch.
///
/// [LAW:effects-at-boundaries] It asks macOS for nothing itself. `ask` is the app's, and the
/// window calls it only from the button a person pressed. Drawing reads and does nothing
/// else; the moments a grant may just have arrived - a request answered, the window coming
/// back to the front, and Check Again - hand the reading they drew to `settle`, the app's.
@MainActor
final class SetUpWindow: NSObject, NSWindowDelegate {
    /// The list as it stands now.
    private let read: () -> Readiness
    /// Asks macOS for one row's grant, and answers with how the request ended.
    private let ask: (Requirement.Row) async -> Request
    /// Told the reading taken after a request and on coming back to the front, the moments
    /// a grant may have arrived.
    private let settle: (Readiness) -> Void
    /// The app's log, where each request says how it ended.
    private let log: Logger

    private var walk = GuidedSetup()
    /// What the last request said went wrong, shown on the step it was made from.
    private var failure: (row: Requirement.Row, reason: String)?
    private var asking = false
    /// The steps whose request was made in this walk. macOS shows most of these dialogs once
    /// per app, so a second press of the same button would do nothing; once asked, a step
    /// still unmet offers System Settings instead, and says why.
    private var asked: Set<Requirement.Row> = []

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = GuidedSetup.title.replacingOccurrences(of: "…", with: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = page
        return window
    }()

    private let page: NSStackView = {
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return page
    }()

    private static let width: CGFloat = 520

    init(
        read: @escaping () -> Readiness, ask: @escaping (Requirement.Row) async -> Request,
        settle: @escaping (Readiness) -> Void, log: Logger
    ) {
        self.read = read
        self.ask = ask
        self.settle = settle
        self.log = log
    }

    /// Opens the walk at its first step, with nothing set aside.
    func show() {
        walk = GuidedSetup()
        failure = nil
        asked = []
        window.center()
        comeToFront()
    }

    /// Takes the front, drawn from a reading taken now and again from the one taken as the
    /// window becomes key, so it is never shown stale while the front is on its way.
    ///
    /// The front is asked of LaunchServices, as `open -a` asks for it, not of `NSApp.activate`:
    /// since macOS 14 activation is cooperative, and an app the front was not yielded to is
    /// refused, `ignoringOtherApps` or not. Measured on studious 2026-10-18 (macOS 15.0.1):
    /// once the microphone dialog was answered, both were refused and the app in front before
    /// took it back; LaunchServices was not refused.
    private func comeToFront() {
        let configuration = NSWorkspace.OpenConfiguration()
        // Taking the front back is not the person opening the app, so Recent Items is left alone.
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [log] _, error in
            if let error {
                log.error("setup: LaunchServices refused the front: \(error, privacy: .public)")
            } else {
                log.notice("setup: LaunchServices gave the front")
            }
        }
        window.makeKeyAndOrderFront(nil)
        redrawFromAFreshReading()
    }

    /// Back at the front, most often from System Settings: read again, and hand the
    /// reading on, since this is where a grant made there is first seen.
    func windowDidBecomeKey(_ notification: Notification) {
        let readiness = read()
        draw(readiness)
        settle(readiness)
    }

    // MARK: - drawing

    /// The reading on screen, which skipping and revisiting redraw from: neither changes
    /// anything on the Mac, so neither is worth a fresh reading.
    private var shown = Readiness([])

    /// Reads again, draws it, and hands it on: the Check Again button, which is a moment a
    /// grant may have arrived like any other.
    private func redrawFromAFreshReading() {
        let readiness = read()
        draw(readiness)
        settle(readiness)
    }

    private func draw(_ readiness: Readiness) {
        shown = readiness
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // [LAW:dataflow-not-control-flow] One page or the other, chosen by what the walk
        // reads off the list, never by a mode the window keeps.
        switch walk.current(in: readiness) {
        case .some(let requirement): drawStep(requirement, left: readiness.unmet.count)
        case .none: drawSummary(readiness)
        }
        window.setContentSize(page.fittingSize)
    }

    private func drawStep(_ requirement: Requirement, left: Int) {
        let explanation = requirement.row.explanation
        let row = requirement.row
        // Asked once in this walk and still unmet: macOS will not show most of these
        // dialogs a second time, so the page offers System Settings where the button was.
        // A re-askable row is the exception - its dialog returns on the next press
        // (`Requirement.Row.reAskable`) - so its button stays and it gets neither line.
        let askedAlready = asked.contains(row) && !row.reAskable
        let ask = askedAlready ? nil : button(row.askTitle) { [unowned self] in request(row) }
        add(label(left == 1 ? "1 step left" : "\(left) steps left", size: 11, color: .secondaryLabelColor))
        add(label(requirement.name, size: 20, weight: .semibold))
        add(label("Now: \(requirement.reads)", size: 12, color: .secondaryLabelColor))
        add(label(explanation.why, size: 13))
        add(label("If you skip it: \(explanation.ifSkipped)", size: 12, color: .secondaryLabelColor))
        // The step's own words, for what the explanation cannot know - a grant switched off
        // in System Settings - except words sending the reader to this page.
        if let step = requirement.step, !step.contains(GuidedSetup.title) {
            add(label(requirement.stepLines.joined(separator: " "), size: 12, color: .secondaryLabelColor))
        }
        // Names, on the step itself, what a person cannot see coming: that this row's dialog
        // returns after a No, and where to go when none comes. Only the input method has one.
        // [LAW:no-silent-failure]
        if let note = row.switchOnNote {
            add(label(note, size: 12, color: .secondaryLabelColor))
        }
        if askedAlready {
            add(label("macOS asks only once. If you said no, turn it on in System Settings.", size: 12, color: .secondaryLabelColor))
        }
        if let failure, failure.row == requirement.row {
            add(label(failure.reason, size: 12, color: .systemRed))
        }
        let skip = button("Skip for Now") { [unowned self] in walk.skip(row); failure = nil; draw(shown) }
        // Every step can be read again by hand: a grant made where this window cannot see
        // it arriving - System Settings left open beside it - clears its step here.
        let checkAgain = button("Check Again") { [unowned self] in redrawFromAFreshReading() }
        let openSettings = button(GuidedSetup.openSettingsTitle) { [unowned self] in openSystemSettings(row) }
        // The default is the one button that makes macOS ask, so Return is the person
        // choosing to be asked; once asked, System Settings.
        let primary = ask ?? openSettings
        let others = [checkAgain, openSettings, ask].compactMap { $0 }.filter { $0 !== primary }
        primary.keyEquivalent = "\r"
        primary.isEnabled = !asking
        add(buttonRow([skip] + others + [primary]))
    }

    private func drawSummary(_ readiness: Readiness) {
        let skipped = readiness.unmet
        add(label(skipped.isEmpty ? "\(AppIdentity.displayName) is set up" : "Set aside for now", size: 20, weight: .semibold))
        for requirement in readiness.requirements where requirement.met {
            add(label("✓ \(requirement.name): \(requirement.reads)", size: 13))
        }
        // Each step set aside says what not having it costs, and offers the way back in:
        // declining leaves the walk resumable, never finished for good.
        for requirement in skipped {
            let row = requirement.row
            add(label("\(requirement.name): \(requirement.reads)", size: 13, weight: .semibold))
            add(label(row.explanation.ifSkipped, size: 12, color: .secondaryLabelColor))
            add(buttonRow([button("Set Up \(requirement.name)…") { [unowned self] in walk.revisit(row); draw(shown) }]))
        }
        let done = button("Done") { [unowned self] in window.close() }
        done.keyEquivalent = "\r"
        add(buttonRow([done]))
    }

    private func request(_ row: Requirement.Row) {
        asking = true
        failure = nil
        draw(shown)
        log.notice("setup: asking for \(row.rawValue, privacy: .public)")
        Task {
            let request = await ask(row)
            let level: OSLogType = if case .failed = request { .error } else { .default }
            log.log(level: level, "setup: asked for \(row.rawValue, privacy: .public): \(String(describing: request), privacy: .public)")
            asking = false
            // Only a request that went through counts as asked: the others showed no dialog,
            // so their button stays, beside the reason, to be tried again.
            switch request {
            case .answered where window.isVisible:
                asked.insert(row)
                comeToFront()
            case .answered, .made:
                asked.insert(row)
                redrawFromAFreshReading()
            case .failed(let reason):
                failure = (row, reason)
                redrawFromAFreshReading()
            case .sentToSystemSettings(let reason):
                failure = (row, reason)
                redrawFromAFreshReading()
                openSystemSettings(row)
            }
        }
    }

    /// The step's pane in System Settings, where its words send the person.
    private func openSystemSettings(_ row: Requirement.Row) {
        // [LAW:no-silent-failure] A pane that does not open leaves the step pointing at nothing.
        if !NSWorkspace.shared.open(row.settingsPane) {
            log.error("setup: System Settings did not open \(row.settingsPane, privacy: .public)")
        }
    }

    /// How a request for one step's grant ended, which says where the person is left.
    ///
    /// [LAW:types-are-the-program] Only a dialog answered before the request returned took the
    /// front away, so only `answered` takes it back; the arm that sends the person to System
    /// Settings cannot also pull this window over it.
    enum Request {
        /// macOS showed its dialog and it was answered. Answering hands the front to the app
        /// that had it before this one, so the window takes it back, unless the person closed
        /// it meanwhile.
        case answered
        /// The request went through and took nothing from the front: macOS had nothing left
        /// to ask, or its dialog may still be up when the request returns, as the input
        /// method's may (`InstalledInputMethod.switchOn`).
        case made
        /// Nothing was asked, for the reason shown on the step.
        case failed(String)
        /// macOS will not ask again, and the switch is in System Settings, which opens with
        /// the reason shown on the step behind it.
        case sentToSystemSettings(String)
    }

    // MARK: - pieces

    private func add(_ view: NSView) { page.addArrangedSubview(view) }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.width - 48
        return label
    }

    private func button(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        ActionButton(title: title, action: action)
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

/// A button that runs a closure, so each page can say what its buttons do where it draws
/// them rather than through a selector per button.
@MainActor
private final class ActionButton: NSButton {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func pressed() { run() }
}
