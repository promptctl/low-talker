import AppKit
import Dictation
import LowTalkerCore

/// The small panel near the bottom of the screen while a press is on its way, or while words
/// no cursor took are held: listening, with what the engine has read of the press so far, then
/// transcribing, then gone once the press's outcome is reported - unless an insert failed, and
/// then it says why and holds the words until a cursor takes them, the person places them with
/// the Insert button below it, or dismisses them with the circle on its corner.
///
/// It never takes focus from the app the words are going to. A borderless panel cannot become
/// key, and a non-activating one is ordered in without activating this app, so a click on the
/// circle or the button leaves the person where they were, and Insert reaches their cursor.
/// Every click on the face goes through it to whatever is under it, so the text field it asks
/// for is clickable even beneath it.
///
/// [LAW:one-source-of-truth] It draws `Dictation.Activity` and `Held` and keeps nothing of its own.
@MainActor
final class HUD {
    private static let width: CGFloat = 440
    /// The width the lines wrap to, inside the face's margins.
    private static let lineWidth = width - 32
    /// At most this many lines of what was heard. Past them the oldest words give way, since the
    /// newest are the ones the person is watching.
    private static let heardLines = 4
    private static let cornerRadius: CGFloat = 12
    /// The side of the circle's panel, which is centred on the circle.
    private static let circleSide: CGFloat = 24

    private let dismiss: @MainActor () -> Void
    private let insert: @MainActor () -> Void

    init(dismiss: @escaping @MainActor () -> Void, insert: @escaping @MainActor () -> Void) {
        self.dismiss = dismiss
        self.insert = insert
    }

    private lazy var panel: NSPanel = {
        let panel = Self.floating(width: Self.width, height: 60)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.contentView = face
        return panel
    }()

    /// The circle, in a panel of its own: a window takes every click on its face whatever its
    /// views answer, so a circle inside the face's panel would make the whole face take clicks.
    /// Its own panel also lets it hang past the corner the face's rounded clip would cut away.
    private lazy var corner: NSPanel = {
        let corner = Self.floating(width: Self.circleSide, height: Self.circleSide)
        corner.contentView = close
        return corner
    }()

    /// The Insert button, in a panel of its own for the same reason, hanging below the face so
    /// it covers none of the words.
    private lazy var below: NSPanel = {
        let size = place.fittingSize
        let below = Self.floating(width: size.width, height: size.height)
        below.contentView = place
        return below
    }()

    /// A panel that floats over every app on every Space and is never key.
    private static func floating(width: CGFloat, height: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // An agent app is never active, and a panel that hid on deactivation would never show.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// The panel's face, laid out at the panel's one width.
    private lazy var face: NSVisualEffectView = {
        let face = NSVisualEffectView()
        face.material = .hudWindow
        face.blendingMode = .behindWindow
        face.state = .active
        face.wantsLayer = true
        face.layer?.cornerRadius = Self.cornerRadius
        face.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        face.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: face.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: face.trailingAnchor),
            content.topAnchor.constraint(equalTo: face.topAnchor),
            content.bottomAnchor.constraint(equalTo: face.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        return face
    }()

    private lazy var content: NSStackView = {
        let content = NSStackView(views: [state, warning, heard])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        return content
    }()

    private let state: NSTextField = {
        let state = NSTextField(labelWithString: "")
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        state.textColor = .secondaryLabelColor
        return state
    }()

    /// Why the words are held, beside the system's warning symbol, wrapped to the panel's width.
    private let warning: NSTextField = {
        let warning = NSTextField(wrappingLabelWithString: "")
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = HUD.lineWidth
        return warning
    }()

    /// What was heard, wrapped to the panel's width.
    private let heard: NSTextField = {
        let heard = NSTextField(wrappingLabelWithString: "")
        heard.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        heard.preferredMaxLayoutWidth = HUD.lineWidth
        return heard
    }()

    /// Lays text out as `heard` does, away from the panel, so measuring never shows on it.
    private lazy var measure = heard.cell!.copy() as! NSCell

    /// How tall `heardLines` lines of what was heard stand.
    private lazy var heardHeight = height(Array(repeating: "…", count: Self.heardLines).joined(separator: "\n"))

    private lazy var close: FirstClick = {
        let close = FirstClick { [unowned self] in dismiss() }
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white, .darkGray])))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.setAccessibilityLabel("Dismiss the held words")
        return close
    }()

    private lazy var place: FirstClick = {
        let place = FirstClick { [unowned self] in insert() }
        place.title = "Insert"
        place.bezelStyle = .push
        place.controlSize = .small
        place.setAccessibilityLabel("Insert the held words at the cursor")
        return place
    }()

    func show(_ activity: Dictation.Activity, held: Held?) {
        // A press on its way carries what is held in its own insert, so only a panel with no
        // press asks for a click, and only for words a cursor arriving is offered: not those
        // that may have landed.
        let allHeld = held?.allWords ?? Transcript(words: [])
        let shown: (state: String?, words: Transcript, offer: String) = switch activity {
        case .idle: (nil, allHeld, held?.offered.map { _ in " Click into a text field to insert these words." } ?? "")
        case .listening(let heard): ("Listening", heard, "")
        case .transcribing: ("Transcribing", allHeld, "")
        }
        guard shown.state != nil || held != nil else { return hide() }
        draw(state: shown.state, held: held, words: shown.words, offer: shown.offer)
    }

    private func hide() {
        panel.orderOut(nil)
        corner.orderOut(nil)
        below.orderOut(nil)
    }

    /// The panel with these lines, centred low on the screen the person is working on.
    private func draw(state: String?, held: Held?, words: Transcript, offer: String) {
        self.state.stringValue = state ?? ""
        self.state.isHidden = state == nil
        // One line per warning, each after the symbol, which says it is a warning, so the text
        // drops the word. The offer ends the last.
        let reasons = (held?.warnings ?? []).map { String($0.trimmingPrefix("WARNING: ")) }
        let warned = NSMutableAttributedString()
        for (index, reason) in reasons.enumerated() {
            let symbol = NSTextAttachment()
            symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            warned.append(NSAttributedString(string: index == 0 ? "" : "\n"))
            warned.append(NSAttributedString(attachment: symbol))
            warned.append(NSAttributedString(string: " \(reason)\(index == reasons.count - 1 ? offer : "")"))
        }
        warning.attributedStringValue = warned
        warning.isHidden = held == nil
        heard.stringValue = words.truncatingHead { height($0) <= heardHeight }
        // A press with nothing read yet shows only its state, rather than an empty line.
        heard.isHidden = words.isBlank
        // With no display attached there is nowhere for the panel to be.
        guard let screen = NSScreen.main?.visibleFrame else { return hide() }
        // Measured through the panel's face, whose constraints hold the content to its width.
        let size = face.fittingSize
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.12, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        // The circle's centre sits on the face's top-left arc, as a Notification Center
        // banner's does, and the button sits under the face's right edge. Both are there only
        // while something is held.
        let onTheArc = Self.cornerRadius * (1 - 1 / 2.squareRoot())
        corner.setFrameOrigin(NSPoint(x: frame.minX + onTheArc - Self.circleSide / 2, y: frame.maxY - onTheArc - Self.circleSide / 2))
        below.setFrameOrigin(NSPoint(x: frame.maxX - below.frame.width, y: frame.minY - 6 - below.frame.height))
        for control in [corner, below] {
            switch held {
            case nil: control.orderOut(nil)
            case .some: control.orderFrontRegardless()
            }
        }
    }

    /// How tall this text stands, wrapped as what was heard is.
    private func height(_ text: String) -> CGFloat {
        measure.stringValue = text
        return measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.lineWidth, height: .greatestFiniteMagnitude)).height
    }
}

/// A button on a panel that is never key: the circle that lets held words go, and Insert.
///
/// Answers the first click, though the panel is never key: the panel cannot become key, so
/// every click on it is a first one, and a button that waited for a second would never fire.
private final class FirstClick: NSButton {
    private let clicked: @MainActor () -> Void

    init(_ clicked: @escaping @MainActor () -> Void) {
        self.clicked = clicked
        super.init(frame: .zero)
        target = self
        action = #selector(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func click() { clicked() }
}
