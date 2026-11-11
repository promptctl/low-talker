import Foundation
import InputMethod

/// One statement of the text client port's contract: a field set up as the case says, one call
/// made through the port, and what the client answers and the field holds after it.
///
/// Stated through the port's own calls plus what the field holds, which is the one reading a real
/// client cannot give. The fake gives it in `make test`, and on studious the test host app gives it
/// for its fields (low-test-layers-sqm.if6), so the same cases run against both, and a case a real
/// client fails is the fake to change. [LAW:one-source-of-truth]
public nonisolated struct ContractCase: Sendable, CustomStringConvertible {
    /// The call the case makes through the port before the client is read.
    public enum Act: Sendable, CustomStringConvertible {
        /// None: the field is read as it was set up.
        case read
        case insert(String, replacementRange: NSRange)

        public var description: String {
            switch self {
            case .read: "read"
            case let .insert(text, range): "insert \(text.debugDescription) at \(range.location == NSNotFound ? "the insertion point" : "\(range)")"
            }
        }
    }

    /// What the client answers once the call is made: whether it gives document access, its
    /// selection, and the text it says is in `readRange`.
    public struct Answers: Sendable, Equatable {
        public let documentAccess: Bool
        public let selection: NSRange
        public let text: String?
    }

    public let profile: ClientProfile
    /// What the field holds before the call, and what of it is selected.
    public let holding: String
    public let selected: NSRange
    public let maxLength: Int?
    public let act: Act
    public let answers: Answers
    public let holds: String

    /// The range every case reads back: the field's first five UTF-16 units.
    public static let readRange = NSRange(location: 0, length: 5)

    public var description: String {
        "\(profile), \(act) into \(holding.debugDescription) with \(selected) selected" + (maxLength.map { " (maxlength \($0))" } ?? "")
    }

    /// Makes the call on `client` and says every way it disagreed with the case; nothing, when it
    /// agreed. `reading` reads what the field holds once the call is made.
    @MainActor
    public func disagreements(of client: any TextInputClient, reading: () -> String) -> [String] {
        switch act {
        case .read: break
        case let .insert(text, range): client.insertText(text, replacementRange: range)
        }
        let answered = Answers(documentAccess: client.givesDocumentAccess(), selection: client.selectedRange(), text: client.string(in: Self.readRange))
        let held = reading()
        return (answered == answers ? [] : ["the client answered \(answered), and the case says \(answers)"])
            + (held == holds ? [] : ["the field holds \(held.debugDescription), and the case says \(holds.debugDescription)"])
    }

    /// The field the case is set up with, as the fake.
    @MainActor
    public func fake() -> FakeTextInputClient {
        let field = FakeTextInputClient(profile, holding: holding, maxLength: maxLength)
        field.select(selected)
        return field
    }
}

public nonisolated extension ContractCase {
    /// Every cell of bem's table (cmt-8694d7d2) the port's calls reach, for each row measured.
    static let measured: [ContractCase] = [ClientProfile.appKit, .webKitTextArea].flatMap(theFullField) + [
        // The none tier, measured as `<input maxlength=10>`: blind, and an explicit range ignored.
        ContractCase(profile: .webKitInput, holding: "", act: .read, answers: blind, holds: ""),
        ContractCase(profile: .webKitInput, holding: "alpha", act: .insert("RNG", replacementRange: NSRange(location: 0, length: 3)), answers: blind, holds: "alphaRNG"),
        ContractCase(profile: .noTextField, holding: "", act: .read, answers: blind, holds: ""),
    ]

    /// What the fake answers where no client was measured, each case for the studious run to
    /// settle (low-test-layers-sqm.8m3): a real client disagreeing with one of these is the guess
    /// corrected, not a client that changed.
    static let unsettled: [ContractCase] = [
        // bem's `<input maxlength=10>` row has no insert: what the field keeps of 30.
        ContractCase(profile: .webKitInput, holding: "", maxLength: 10, act: .insert(thirty, replacementRange: atThePoint), answers: blind, holds: "alpha brav"),
        // bem measured the textarea without `maxlength`: whether one with it still gives document
        // access, and what its reads answer once it has kept 10 of 30 (low-reliability-z2z.rgy).
        ContractCase(profile: .webKitTextArea, holding: "", maxLength: 10, act: .insert(thirty, replacementRange: atThePoint),
                     answers: reads(caret: 10, text: "alpha"), holds: "alpha brav"),
        // sk9 read document access and a real selection where bem read none, and the text over a
        // range under document access is unmeasured.
        ContractCase(profile: .iTerm2, holding: "alpha bravo", act: .insert(" x", replacementRange: atThePoint),
                     answers: reads(caret: 13, text: "alpha"), holds: "alpha bravo x"),
    ]

    private init(profile: ClientProfile, holding: String, selected: NSRange? = nil, maxLength: Int? = nil, act: Act, answers: Answers, holds: String) {
        self.init(profile: profile, holding: holding, selected: selected ?? NSRange(location: holding.utf16.count, length: 0), maxLength: maxLength,
                  act: act, answers: answers, holds: holds)
    }

    private static let atThePoint = NSRange(location: NSNotFound, length: 0)
    private static let thirty = "alpha bravo charlie delta echo"
    private static let blind = Answers(documentAccess: false, selection: NSRange(location: NSNotFound, length: NSNotFound), text: nil)

    private static func reads(caret: Int, text: String) -> Answers { Answers(documentAccess: true, selection: NSRange(location: caret, length: 0), text: text) }

    /// The full and partial tiers alike: reads answer the field, an insert at the insertion point
    /// replaces the selection, and an explicit range is honoured.
    private static func theFullField(_ profile: ClientProfile) -> [ContractCase] {
        [
            ContractCase(profile: profile, holding: "alpha bravo", act: .read, answers: reads(caret: 11, text: "alpha"), holds: "alpha bravo"),
            ContractCase(profile: profile, holding: "alpha bravo", act: .insert(" x", replacementRange: atThePoint),
                         answers: reads(caret: 13, text: "alpha"), holds: "alpha bravo x"),
            ContractCase(profile: profile, holding: "alpha bravo", selected: NSRange(location: 6, length: 5), act: .insert("delta", replacementRange: atThePoint),
                         answers: reads(caret: 11, text: "alpha"), holds: "alpha delta"),
            ContractCase(profile: profile, holding: "alpha bravo", act: .insert("RNG", replacementRange: NSRange(location: 0, length: 3)),
                         answers: reads(caret: 3, text: "RNGha"), holds: "RNGha bravo"),
        ]
    }
}
