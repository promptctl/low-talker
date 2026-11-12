import AppKit
import Dictation
import Identity
import LowTalkerCore

/// The word box on screen: a face near the bottom of the screen, the circle on its corner, and
/// Insert and Copy below it. Copy puts the held words on the clipboard and dismisses them, so the
/// next press does not type them beside the paste.
///
/// It never takes focus from the app the words are going to. A borderless panel cannot become
/// key, and a non-activating one is ordered in without activating this app, so a click on the
/// circle or the button leaves the person where they were, and Insert reaches their cursor.
/// Every click on the face goes through it to whatever is under it, so the text field it asks
/// for is clickable even beneath it.
///
/// [LAW:effects-at-boundaries] `WordBox` decides what it shows and when it is put away; this
/// lays out and orders in what it is given.
@MainActor
final class HUD: WordBoxPanel {
    private static let width: CGFloat = 440
    /// The width the lines wrap to, inside the face's margins.
    private static let lineWidth = width - 32
    /// At most this many lines of what was heard. Past them the oldest words give way, since the
    /// newest are the ones the person is watching.
    private static let heardLines = 4
    private static let cornerRadius: CGFloat = 12
    /// The side of the circle's panel, which is centred on the circle.
    private static let circleSide: CGFloat = 24

    private let circleClicked: @MainActor () -> Void
    private let insert: @MainActor () -> Void
    private let copy: @MainActor () -> Void

    init(circleClicked: @escaping @MainActor () -> Void, insert: @escaping @MainActor () -> Void, copy: @escaping @MainActor () -> Void) {
        self.circleClicked = circleClicked
        self.insert = insert
        self.copy = copy
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

    /// Copy and Insert, in a panel of their own for the same reason, hanging below the face so
    /// they cover none of the words.
    private lazy var below: NSPanel = {
        let size = buttons.fittingSize
        let below = Self.floating(width: size.width, height: size.height)
        below.contentView = buttons
        return below
    }()

    private lazy var buttons: NSStackView = {
        // Copy on the trailing edge, and dimmed rather than hidden where it is not offered, so it
        // never leaves its place and Insert never moves into it: Insert types.
        let buttons = NSStackView(views: [place, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        return buttons
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
        let close = FirstClick { [unowned self] in circleClicked() }
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white, .darkGray])))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.setAccessibilityLabel("Dismiss the held words, and cancel a dictation still listening")
        close.toolTip = "Dismiss the held words. Bring them back from the \(AppIdentity.displayName) menu. A dictation still listening is cancelled, as Escape cancels it, and what it typed is taken back."
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

    private lazy var copyButton: FirstClick = {
        let copyButton = FirstClick { [unowned self] in copy() }
        copyButton.title = "Copy"
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .push
        copyButton.controlSize = .small
        copyButton.setAccessibilityLabel("Copy the held words to the clipboard and dismiss them")
        copyButton.toolTip = "Copy the held words to the clipboard and dismiss them. Bring them back from the \(AppIdentity.displayName) menu."
        return copyButton
    }()

    /// Whether the panel is on screen, which the word box takes an Escape by.
    private(set) var isShown = false

    func hide() {
        isShown = false
        panel.orderOut(nil)
        corner.orderOut(nil)
        below.orderOut(nil)
    }

    /// The panel with this face, centred low on the screen the person is working on.
    func draw(_ face: WordBox.Face) {
        state.stringValue = face.state ?? ""
        state.isHidden = face.state == nil
        // One line per warning, each after the symbol, which says it is a warning.
        let warned = NSMutableAttributedString()
        for (index, reason) in face.warnings.enumerated() {
            let symbol = NSTextAttachment()
            symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            warned.append(NSAttributedString(string: index == 0 ? "" : "\n"))
            warned.append(NSAttributedString(attachment: symbol))
            warned.append(NSAttributedString(string: " \(reason)"))
        }
        warning.attributedStringValue = warned
        warning.isHidden = face.warnings.isEmpty
        heard.stringValue = face.words.truncatingHead { height($0) <= heardHeight }
        // A press with nothing read yet shows only its state, rather than an empty line.
        heard.isHidden = face.words.isBlank
        // With no display attached there is nowhere for the panel to be.
        guard let screen = NSScreen.main?.visibleFrame else { return hide() }
        // Measured through the panel's face, whose constraints hold the content to its width.
        let size = self.face.fittingSize
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.12, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isShown = true
        // The circle's centre sits on the face's top-left arc, as a Notification Center
        // banner's does, and the buttons sit under the face's right edge.
        let onTheArc = Self.cornerRadius * (1 - 1 / 2.squareRoot())
        corner.setFrameOrigin(NSPoint(x: frame.minX + onTheArc - Self.circleSide / 2, y: frame.maxY - onTheArc - Self.circleSide / 2))
        if let controls = face.controls {
            place.isHidden = !controls.insert
            copyButton.isEnabled = controls.copy
            let size = buttons.fittingSize
            below.setFrame(NSRect(x: frame.maxX - size.width, y: frame.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        }
        for control in [corner, below] {
            if face.controls != nil { control.orderFrontRegardless() } else { control.orderOut(nil) }
        }
    }

    /// How tall this text stands, wrapped as what was heard is.
    private func height(_ text: String) -> CGFloat {
        measure.stringValue = text
        return measure.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.lineWidth, height: .greatestFiniteMagnitude)).height
    }
}

/// A button on a panel that is never key: the circle that lets held words go, Copy and Insert.
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
