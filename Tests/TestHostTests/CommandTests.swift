import Foundation
@testable import test_host
import Testing

struct CommandTests {
    @Test func eachLineIsTheCommandItNamesUnderItsId() throws {
        #expect(try Command.parse(#"{"id":2,"read":"input"}"#) == Command(id: 2, field: .input, act: .read))
        #expect(try Command.parse(#"{"id":3,"hold":"textarea","text":"alpha bravo","selection":[6,5],"maxLength":10}"#)
            == Command(id: 3, field: .textarea, act: .hold(text: "alpha bravo", selection: NSRange(location: 6, length: 5), maxLength: 10)))
    }

    /// A hold with no maxLength, or a null one, keeps whatever is typed.
    @Test(arguments: [#"{"id":4,"hold":"text-view","text":"","selection":[0,0]}"#, #"{"id":4,"hold":"text-view","text":"","selection":[0,0],"maxLength":null}"#])
    func aHoldWithoutAMaxLengthKeepsEverything(line: String) throws {
        #expect(try Command.parse(line) == Command(id: 4, field: .textView, act: .hold(text: "", selection: NSRange(location: 0, length: 0), maxLength: nil)))
    }

    /// A selection counts UTF-16 units, as NSRange and the page's `selectionStart` do: the emoji is two.
    @Test func aSelectionCountsUTF16Units() throws {
        #expect(try Command.parse(#"{"id":5,"hold":"textarea","text":"a👍","selection":[3,0]}"#)
            == Command(id: 5, field: .textarea, act: .hold(text: "a👍", selection: NSRange(location: 3, length: 0), maxLength: nil)))
    }

    @Test(arguments: [
        (#"{"id":1,"read":"notes"}"#, "names no field"),
        (#"{"read":"input"}"#, "names no id"),
        (#"{"id":true,"read":"input"}"#, "names no id"),
        (#"{"id":1,"hold":"input","text":"","selection":[9223372036854775807,1]}"#, "selection"),
        (#"{"id":1,"hold":"input","text":"a","selection":[1,9223372036854775807]}"#, "selection"),
        (#"{"id":1,"hold":"input","text":"a","selection":[false,true]}"#, "selection"),
        (#"{"id":1,"hold":"input","text":"","selection":[0,0],"maxLength":true}"#, "maxLength"),
        (#"{"id":1,"focus":"text-view"}"#, "names no command"),
        (#"{"id":1,"hold":"input","text":"","selection":[0,0],"read":"input"}"#, "names more than one command"),
        (#"{"id":1,"hold":"input","text":"alpha"}"#, "selection"),
        (#"{"id":1,"hold":"input","text":"alpha","selection":[4,2]}"#, "selection"),
        (#"{"id":1,"hold":"input","selection":[0,0]}"#, "names no text"),
        (#"{"id":1,"hold":"input","text":"","selection":[0,0],"maxLength":-1}"#, "maxLength"),
        (#"{"id":1,"hold":"text-view","text":"","selection":[0,0],"maxLength":10}"#, "text-view has no maxLength"),
        ("read input", "not a JSON object"),
        (#"{"id":1,"hold":"input","text":"","selection":[0,0],"maxlength":10}"#, "names maxlength, which a hold has not"),
        (#"{"id":1,"read":"input","text":""}"#, "names text, which a read has not"),
    ])
    func aLineItCannotActOnSaysWhyAndQuotesIt(line: String, reason: String) {
        #expect {
            try Command.parse(line)
        } throws: { error in
            let description = String(describing: error)
            return description.contains(reason) && description.hasSuffix(line)
        }
    }
}
