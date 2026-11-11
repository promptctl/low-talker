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
        case .textarea: .webKit(element: "<textarea id=f></textarea>")
        case .input: .webKit(element: "<input id=f>")
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
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw unreadable("not a JSON object")
        }
        guard let id = object["id"] as? Int else { throw unreadable("names no id for its answer") }
        let verbs = ["hold", "read"].filter { object[$0] != nil }
        guard verbs.count == 1, let verb = verbs.first else { throw unreadable("names \(verbs.isEmpty ? "no" : "more than one") command") }
        guard let name = object[verb] as? String, let field = Field(rawValue: name) else {
            throw unreadable("names no field: the fields are \(Field.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let act: Act
        switch verb {
        case "read": act = .read
        default:
            guard let text = object["text"] as? String else { throw unreadable("a hold names no text") }
            guard let selection = object["selection"] as? [Int], selection.count == 2, selection[0] >= 0, selection[1] >= 0,
                  selection[0] + selection[1] <= text.utf16.count
            else { throw unreadable("a hold's selection is not [location, length] within its text") }
            let maxLength: Int?
            switch object["maxLength"] {
            case nil, is NSNull: maxLength = nil
            case let length as Int where length >= 0: maxLength = length
            default: throw unreadable("a hold's maxLength is not a count of UTF-16 units or null")
            }
            // [LAW:no-silent-failure] An AppKit text view has no maxlength, and a case that gave it
            // one would be judged against a field that ignored it.
            if maxLength != nil, case .appKitTextView = field.surface { throw unreadable("\(field.rawValue) has no maxLength") }
            act = .hold(text: text, selection: NSRange(location: selection[0], length: selection[1]), maxLength: maxLength)
        }
        return Command(id: id, field: field, act: act)
    }
}
