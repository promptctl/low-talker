import AppKit

/// Holds the fields the client contract runs against, and says what each one holds, so a script
/// reads a field from the field and never from the screen.
///
///     .build/TestHost.app/Contents/MacOS/test-host     (built by `make test-host`)
///
/// Run from inside its bundle, and exec'd directly rather than opened, so it keeps standard input
/// and output: macOS gives a client the bundle's identifier only when there is a bundle, and the
/// input method takes no cursor from a client that names no app. Bringing it to the front is the
/// runner's (`open` on the bundle): macOS refuses a process launched behind another app the
/// activation it asks for itself.
///
/// Standard input takes one command per line, each with an id the runner chose:
/// `{"id":n,"hold":"<field>","text":"...","selection":[location,length],"maxLength":m|null}`
/// gives the field keyboard focus and sets it up; `{"id":n,"read":"<field>"}` touches nothing.
/// Standard output carries one event per line: `ready` once every page has loaded, naming the
/// fields; `field`, the field's whole state read from the field (`Events.field`), with
/// `"answers": n` once command n has taken effect, exactly once per command, and
/// `"answers": null` on every change, whatever made it; `active` when the app becomes or stops
/// being active; `error` before exiting 2. The end of standard input quits it, so it lives as long
/// as the runner holding it.
/// `scripts/testhost.py` is the one client of all this. [LAW:one-source-of-truth]

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let fields: [Field: any HostedField] = Dictionary(uniqueKeysWithValues: Field.allCases.map { field in
    switch field.surface {
    case .appKitTextView: (field, TextViewField(field))
    case let .webKit(element): (field, WebField(field, element: element))
    }
})

let stack = NSStackView(views: Field.allCases.map { field in
    let view = fields[field]!.view
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 360), view.heightAnchor.constraint(equalToConstant: 60)])
    return view
})
stack.orientation = .vertical
stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
window.title = "test-host"
window.contentView = stack
window.center()
window.makeKeyAndOrderFront(nil)

for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
    NotificationCenter.default.addObserver(forName: name, object: application, queue: .main) { _ in MainActor.assumeIsolated { Events.active(active) } }
}

/// Standard input's lines, read on a thread of their own because a read blocks, and acted on one
/// at a time in the order they came, each answered before the next is read.
/// [LAW:no-ambient-temporal-coupling]
let lines = AsyncStream<String> { continuation in
    Thread {
        while let line = readLine() { continuation.yield(line) }
        continuation.finish()
    }.start()
}

Task {
    for field in Field.allCases { await fields[field]!.load() }
    Events.ready()
    for await line in lines {
        let command: Command
        do throws(Command.Unreadable) { command = try Command.parse(line) } catch { Events.fail(error.description) }
        Events.field(await fields[command.field]!.perform(command.act), answering: command.id)
    }
    exit(0)
}

application.run()
