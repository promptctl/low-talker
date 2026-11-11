import Foundation

/// A field the host holds, named by what draws it. Each is the field of one profile of the client
/// contract (`ContractCase`): `text-view` the AppKit view TextEdit and Notes show, `textarea` and
/// `input` the elements WebKit, Safari's engine, draws. iTerm2 and a window with no field stay
/// rows measured in place.
nonisolated enum Field: String, CaseIterable, Sendable {
    case textView = "text-view"
    case textarea
    case input

    /// What draws the field: AppKit's text view, or a page holding one element with the id `f`.
    enum Surface {
        case appKitTextView
        case webKit(element: String)
    }

    var surface: Surface {
        switch self {
        case .textView: .appKitTextView
        // No spelling correction: what the field holds is what reached it.
        case .textarea: .webKit(element: "<textarea id=f spellcheck=false></textarea>")
        case .input: .webKit(element: "<input id=f spellcheck=false>")
        }
    }

    /// Whether the field can keep at most a number of UTF-16 units: an element on a page has
    /// `maxlength`, and an AppKit text view has no such thing.
    var keepsMaxLength: Bool {
        switch surface {
        case .appKitTextView: false
        case .webKit: true
        }
    }
}

/// One line a script sends on standard input, parsed once, and the number it chose for the one
/// answer it is owed. [LAW:parse-dont-validate]
nonisolated struct Command: Equatable, Sendable {
    enum Act: Equatable {
        /// The field takes keyboard focus, then keeps at most `maxLength` UTF-16 units of what is typed or
        /// inserted into it, as HTML `maxlength` counts them, and holds `text` with `selection`
        /// selected.
        case hold(text: String, selection: NSRange, maxLength: Int?)
        /// What the field holds now, touching nothing.
        case read
    }

    let id: Int
    let field: Field
    let act: Act

    struct Unreadable: Error, CustomStringConvertible {
        let line: String
        let reason: String
        var description: String { "\(reason): \(line)" }
    }

    /// `{"id":n,"read":"<field>"}` or `{"id":n,"hold":"<field>","text":"...","selection":[location,length],"maxLength":m|null}`.
    static func parse(_ line: String) throws(Unreadable) -> Command {
        func unreadable(_ reason: String) -> Unreadable { Unreadable(line: line, reason: reason) }
        /// A JSON integer. JSONSerialization gives `true` and `false` as NSNumbers too, which `as? Int`
        /// would read as 1 and 0.
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number as? Int
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw unreadable("not a JSON object")
        }
        guard let id = integer(object["id"]) else { throw unreadable("names no id for its answer") }
        let verbs = ["hold", "read"].filter { object[$0] != nil }
        guard verbs.count == 1, let verb = verbs.first else { throw unreadable("names \(verbs.isEmpty ? "no" : "more than one") command") }
        // A key misspelled is a setting the runner meant and the host would never make.
        let keys: Set = verb == "read" ? ["id", "read"] : ["id", "hold", "text", "selection", "maxLength"]
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) { throw unreadable("names \(unknown), which a \(verb) has not") }
        guard let name = object[verb] as? String, let field = Field(rawValue: name) else {
            throw unreadable("names no field: the fields are \(Field.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let act: Act
        switch verb {
        case "read": act = .read
        default:
            guard let text = object["text"] as? String else { throw unreadable("a hold names no text") }
            // The length is checked against what is left past the location, which no Int overflows.
            guard let pair = object["selection"] as? [Any], pair.count == 2, let location = integer(pair[0]), let length = integer(pair[1]),
                  location >= 0, length >= 0, location <= text.utf16.count, length <= text.utf16.count - location
            else { throw unreadable("a hold's selection is not [location, length] within its text") }
            let maxLength: Int?
            switch object["maxLength"] {
            case nil, is NSNull: maxLength = nil
            case let value:
                guard let count = integer(value), count >= 0 else { throw unreadable("a hold's maxLength is not a count of UTF-16 units or null") }
                maxLength = count
            }
            // [LAW:no-silent-failure] A field that keeps no maxLength, given one, would be judged
            // as if it had kept it.
            if maxLength != nil, !field.keepsMaxLength { throw unreadable("\(field.rawValue) has no maxLength") }
            act = .hold(text: text, selection: NSRange(location: location, length: length), maxLength: maxLength)
        }
        return Command(id: id, field: field, act: act)
    }
}
