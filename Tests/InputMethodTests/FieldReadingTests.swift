import Foundation
@testable import InputMethod
import InputMethodFakes
import Testing

/// What a read of the focused field says, over the fake answering as each profile does, and the
/// exact calls it made on the client to say it: each is a call into an app that may be hung.
@MainActor
@Suite struct FieldReadingTests {
    private static func text(_ location: Int, _ length: Int) -> FakeTextInputClient.Call {
        .string(in: NSRange(location: location, length: length))
    }

    private static func field(_ profile: ClientProfile, holding text: String, selecting range: NSRange) -> FakeTextInputClient {
        let field = FakeTextInputClient(profile, holding: text)
        field.select(range)
        return field
    }

    /// A caret: nothing selected, and the text either side read in one ask each, the after-read
    /// running past the field's end and answered with what is there.
    @Test func aCaretReadsTheTextEitherSideOfIt() {
        let field = Self.field(.appKitAnsweringWhatIsThere, holding: "alpha bravo", selecting: NSRange(location: 6, length: 0))

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .readable(DocumentContext(selection: NSRange(location: 6, length: 0), selected: "", before: "alpha ", after: "bravo")))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(0, 6), Self.text(6, 1_000)])
        #expect(event == .readable(selection: NSRange(location: 6, length: 0), before: 6, after: 5, asks: 2))
    }

    /// A client answering nothing for a range past its end has the after-read searched for the
    /// longest range that answers, which is the text to the end, under each profile that does.
    @Test(arguments: [ClientProfile.appKit, .webKitTextArea])
    func aFieldShorterThanTheBoundIsSearchedToItsEnd(_ profile: ClientProfile) {
        let field = Self.field(profile, holding: "alpha bravo", selecting: NSRange(location: 6, length: 0))

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .readable(DocumentContext(selection: NSRange(location: 6, length: 0), selected: "", before: "alpha ", after: "bravo")))
        let searched = [1_000, 500, 250, 125, 62, 31, 15, 7, 3, 5, 6].map { Self.text(6, $0) }
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(0, 6)] + searched)
        #expect(event == .readable(selection: NSRange(location: 6, length: 0), before: 6, after: 5, asks: 12))
    }

    /// A selection is read whole, and the text before it and after it.
    @Test func aSelectionIsReadWithTheTextAroundIt() {
        let field = Self.field(.appKitAnsweringWhatIsThere, holding: "alpha bravo charlie", selecting: NSRange(location: 6, length: 5))

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .readable(DocumentContext(selection: NSRange(location: 6, length: 5), selected: "bravo", before: "alpha ",
                                                     after: " charlie")))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(6, 5), Self.text(0, 6), Self.text(11, 1_000)])
        #expect(event == .readable(selection: NSRange(location: 6, length: 5), before: 6, after: 8, asks: 3))
    }

    /// A field longer than the bound each way is read a bound's worth either side, in one ask each.
    @Test func aFieldLongerThanTheBoundIsReadToTheBound() {
        let field = Self.field(.appKit, holding: String(repeating: "a", count: 3_000), selecting: NSRange(location: 1_500, length: 0))

        let (reading, event) = FieldReading.read(from: field)

        let bound = String(repeating: "a", count: 1_000)
        #expect(reading == .readable(DocumentContext(selection: NSRange(location: 1_500, length: 0), selected: "", before: bound, after: bound)))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(500, 1_000), Self.text(1_500, 1_000)])
        #expect(event == .readable(selection: NSRange(location: 1_500, length: 0), before: 1_000, after: 1_000, asks: 2))
    }

    /// At the field's start nothing is before the caret, and the client is not asked for it.
    @Test func atTheFieldsStartNothingIsAskedForBeforeTheCaret() {
        let field = Self.field(.appKitAnsweringWhatIsThere, holding: "alpha", selecting: NSRange(location: 0, length: 0))

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .readable(DocumentContext(selection: NSRange(location: 0, length: 0), selected: "", before: "", after: "alpha")))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(0, 1_000)])
        #expect(event == .readable(selection: NSRange(location: 0, length: 0), before: 0, after: 5, asks: 1))
    }

    /// A client giving no document access is asked that and nothing more.
    @Test func aClientWithoutDocumentAccessIsAskedNothingElse() {
        let field = FakeTextInputClient(.webKitInput, holding: "alpha")

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .unreadable(.noDocumentAccess))
        #expect(field.calls == [.givesDocumentAccess])
        #expect(event == .unreadable(.noDocumentAccess, asks: 0))
    }

    /// A client giving document access and NSNotFound for its selection is asked for no text.
    @Test func aSelectionOfNSNotFoundIsUnreadable() {
        let field = FakeTextInputClient(.documentAccessWithoutSelection, holding: "alpha")

        let (reading, event) = FieldReading.read(from: field)

        #expect(reading == .unreadable(.selectionNotFound))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange])
        #expect(event == .unreadable(.selectionNotFound, asks: 0))
    }

    /// A selection past the field's end contradicts the field: the text before it answers nothing,
    /// or less than the selection says is there, whichever the client answers past its end.
    @Test(arguments: [(ClientProfile.appKit, nil), (.appKitAnsweringWhatIsThere, 5)] as [(ClientProfile, Int?)])
    func aSelectionPastTheFieldContradictsIt(_ profile: ClientProfile, answered: Int?) {
        let field = Self.field(profile, holding: "alpha", selecting: NSRange(location: 20, length: 0))

        let (reading, event) = FieldReading.read(from: field)

        let reason = Unreadable.contradicted(asked: NSRange(location: 0, length: 20), answered: answered)
        #expect(reading == .unreadable(reason))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(0, 20)])
        #expect(event == .unreadable(reason, asks: 1))
    }

    /// A client giving a selection and no text over it contradicts itself at the first text asked.
    @Test func aSelectionWithoutTextContradictsIt() {
        let field = FakeTextInputClient(.iTerm2SelectionOnly, holding: "alpha bravo")

        let (reading, event) = FieldReading.read(from: field)

        let reason = Unreadable.contradicted(asked: NSRange(location: 0, length: 11), answered: nil)
        #expect(reading == .unreadable(reason))
        #expect(field.calls == [.givesDocumentAccess, .selectedRange, Self.text(0, 11)])
        #expect(event == .unreadable(reason, asks: 1))
    }

    /// A cursor reads its own client, and only it.
    @Test func aCursorReadsItsClient() throws {
        let field = Self.field(.appKitAnsweringWhatIsThere, holding: "alpha bravo", selecting: NSRange(location: 6, length: 0))
        let cursor = try field.cursor()
        let made = field.calls.count

        #expect(cursor.read() == .readable(DocumentContext(selection: NSRange(location: 6, length: 0), selected: "", before: "alpha ", after: "bravo")))
        #expect(Array(field.calls.dropFirst(made)) == [.givesDocumentAccess, .selectedRange, Self.text(0, 6), Self.text(6, 1_000)])
    }

    /// The event says lengths, ranges and reasons, never the field's text.
    @Test func theEventSaysNoText() {
        let field = Self.field(.appKitAnsweringWhatIsThere, holding: "alpha bravo", selecting: NSRange(location: 6, length: 0))

        let line = FieldReading.read(from: field).event.description

        #expect(line == "readable: selection {6, 0}, 6 units before it and 5 after, in 2 asks for text")
    }
}
