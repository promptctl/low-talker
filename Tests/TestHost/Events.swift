import AppKit

/// What a field holds at one moment, read from the field itself.
struct Reading {
    let field: Field
    let text: String
    let selection: NSRange
    /// The most UTF-16 units the field keeps, as the field itself has it: the element's own
    /// `maxLength` on a page, and none on a text view, which has no such thing.
    let maxLength: Int?
    /// Whether the field's view is the window's first responder and, on a page, its element is the
    /// page's active element: where keys go while the app is active.
    let focused: Bool
}

/// Standard output, one JSON object per line: the only thing the host writes there.
/// [LAW:single-enforcer]
enum Events {
    static func ready() {
        emit(["event": "ready", "fields": Field.allCases.map(\.rawValue), "keepsMaxLength": Field.allCases.filter(\.keepsMaxLength).map(\.rawValue)])
    }

    /// `answering` is the id of the command the reading answers, once that command has taken
    /// effect, or nil for a reading pushed on a change, whatever made the change. Keys reach the
    /// field exactly when it is focused and the app is active, so each reading says both.
    static func field(_ reading: Reading, answering id: Int?) {
        emit([
            "event": "field", "answers": id ?? NSNull(), "name": reading.field.rawValue, "text": reading.text,
            "selection": [reading.selection.location, reading.selection.length], "maxLength": reading.maxLength ?? NSNull(),
            "focused": reading.focused, "active": NSApplication.shared.isActive,
        ])
    }

    static func active(_ active: Bool) { emit(["event": "active", "active": active]) }

    /// Says what went wrong, here and on standard error, and exits 2: a line the host cannot act
    /// on is a runner that is wrong about the host, and going on would answer a question nobody
    /// asked. [LAW:no-silent-failure]
    static func fail(_ message: String) -> Never {
        emit(["event": "error", "message": message])
        FileHandle.standardError.write(Data("test-host: \(message)\n".utf8))
        exit(2)
    }

    private static func emit(_ object: [String: Any]) {
        // Every value here is a string, number, bool, null or array of them, which
        // JSONSerialization always writes.
        let line = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(line + Data("\n".utf8))
    }
}
