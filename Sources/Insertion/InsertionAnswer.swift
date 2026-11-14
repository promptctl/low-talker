import Darwin
import Foundation
import GrammaticalNumber
import Identity

/// Which cursor an insert's words may go to.
///
/// [LAW:types-are-the-program] A dictation's words belong together: its first go to the
/// cursor in front, wherever that is, and every later one only to the app those went to.
/// Which of the two an insert is crosses the wire as this value, so the input method, the
/// one process that knows which app holds the cursor, is the one that refuses the rest once
/// the person has moved. [LAW:single-enforcer]
public enum Destination: Codable, Equatable, Sendable, CustomStringConvertible {
    case cursorInFront
    case app(String)

    /// Whether words bound here may go to a cursor in `application`, which is absent when
    /// no app is in front.
    public func admits(_ application: String?) -> Bool {
        switch self {
        case .cursorInFront: true
        case .app(let bound): bound == application
        }
    }

    public var description: String {
        switch self {
        case .cursorInFront: "the cursor in front"
        case .app(let bound): "the cursor in front only in \(bound)"
        }
    }
}

/// An insert as the input method is asked it: the words, where they may go, and what they
/// replace.
public struct InsertRequest: Codable, Equatable, Sendable {
    public let text: String
    public let destination: Destination
    /// The text immediately before the caret that this commit takes the place of: empty for
    /// every ordinary insert, and what a cancelled dictation's inserts put there when it takes
    /// its own words back, with `text` the earlier dictation among them.
    /// [LAW:dataflow-not-control-flow] One request whose value says what it replaces, nothing
    /// for an insert, rather than a second kind of request.
    public let replacing: String

    public init(_ text: String, into destination: Destination, replacing: String = "") {
        self.text = text
        self.destination = destination
        self.replacing = replacing
    }

    // A field at its default is left out of the JSON and an absent one reads as its default,
    // so an ordinary insert is the same bytes to an input method that knows a field as to one
    // that does not. Every field a later build adds keeps this rule, or the input methods
    // before it refuse every request it writes (`Wire.request(of:)`).
    private enum CodingKeys: CodingKey { case text, destination, replacing }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try fields.decode(String.self, forKey: .text), into: try fields.decode(Destination.self, forKey: .destination),
            replacing: try fields.decodeIfPresent(String.self, forKey: .replacing) ?? "")
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(text, forKey: .text)
        try fields.encode(destination, forKey: .destination)
        try fields.encodeIfPresent(replacing.isEmpty ? nil : replacing, forKey: .replacing)
    }
}

/// What the input method did with the text it was asked to insert.
///
/// The shape the answer crosses the wire in, which is the only reason it is a sum: the far
/// end has to be able to say any of these. Past `InputMethodInserter` a refusal or words
/// not yet taken is thrown like any other failure, because to the caller it is one - the
/// words are not at the cursor now, and nothing here puts them anywhere else.
/// [LAW:types-are-the-program]
public enum InsertionAnswer: Codable, Equatable, Sendable {
    /// Committed into the client in front, replacing what the request named: nothing, for an
    /// ordinary insert.
    ///
    /// `into` is the app whose client took it, which only this end knows: the app asked
    /// seconds earlier, while the person was still speaking, and by the time the words are
    /// ready the person may be somewhere else. An answer that left it out would leave the
    /// caller to name the app from what it remembered, and a log line naming the wrong
    /// window is worse than one naming none. [FRAMING:representation]
    case inserted(characters: Int, into: String)
    /// Not committed, and why.
    case refused(Refusal)
    /// Handed to the client in front, which did not take them within the input method's
    /// bound. Neither of the others: the words are on their way and land if the app
    /// recovers, so this is never a refusal and must never be retried.
    case notYetTaken(characters: Int, into: String)

    /// What the insert that met this answer comes to for its caller: words inserted, or the
    /// failure thrown. [LAW:parse-dont-validate] The wire's sum ends here: past it a refusal or
    /// words not yet taken is a failure thrown like the others, and a caller holds words
    /// inserted or nothing.
    public func outcome() throws(InsertFailure) -> Inserted {
        switch self {
        case .inserted(let characters, let into): return Inserted(characters: characters, into: into)
        case .refused(let refusal): throw .refused(refusal)
        case .notYetTaken(let characters, let into): throw .notYetTaken(NotYetTaken(characters: characters, into: into))
        }
    }
}

/// A failed request told to the person: why it failed, then what became of the words it carried.
///
/// [LAW:one-source-of-truth] The two halves are apart because only the first belongs to every
/// request: an insert's warning is both, and a sender with its own words to account for, as a
/// cancel's take-back has, tells the reason beside its own account of them.
public protocol InsertWarning: CustomStringConvertible {
    /// What happened, and nothing of what it means for the words.
    var reason: String { get }
    /// What became of an insert's words, and how to have them offered again; nil where whoever
    /// sent the request tells it.
    var fate: String? { get }
}

extension InsertWarning {
    public var description: String { ["WARNING: \(reason)", fate].compactMap { $0 }.joined(separator: " ") }
}

/// Words handed to an app that did not take them in time: they land if it recovers.
/// Thrown past `InputMethodInserter` like a refusal, because the words are not at the
/// cursor now, and apart from one, because they may yet be. [LAW:types-are-the-program]
public struct NotYetTaken: Error, Equatable, Sendable, InsertWarning {
    public let characters: Int
    public let into: String

    public init(characters: Int, into: String) {
        self.characters = characters
        self.into = into
    }

    public var reason: String { "\(into) did not take what it was handed in time." }
    public var fate: String? { "The \(counted(characters, "character lands if it recovers; do not dictate it again.", "characters land if it recovers; do not dictate them again."))" }
}

/// Words committed at the cursor: how many, and the app whose client took them.
public struct Inserted: Equatable, Sendable {
    public let characters: Int
    public let into: String

    public init(characters: Int, into: String) {
        self.characters = characters
        self.into = into
    }
}

/// Why the input method did not insert.
///
/// A closed set rather than a string, so a caller can act on a reason and the compiler
/// says which reasons it has not considered; each one is also what the log line says, so
/// there is one spelling of each fact. [LAW:one-source-of-truth]
public enum Refusal: String, Error, Codable, CaseIterable, Equatable, Sendable, InsertWarning {
    /// No text field has focus, so there is nowhere for words to go. Three ways in, with one
    /// fix for the person, which is clicking into a field: no client has focus at all, the
    /// client in front answers that it gives no document access, or its caret is on no
    /// screen. The second is every window without a focused field, since each one still
    /// hands the input method a client and drops what is committed into it: Calculator,
    /// Installer, a web page's body text (measured on studious, low-reliability-z2z.sk9).
    /// The third is the Finder's desktop and file lists, whose type-select buffer gives
    /// document access from no window (low-reliability-z2z.anp). The input method's log
    /// tells the three apart by naming the cursor it held and what its client answered.
    ///
    /// Spelled on the wire as it was before the second way in, so an app from either side
    /// of the change reads it as the same refusal. [LAW:one-type-per-behavior]
    case noTextFieldHasFocus = "noClientHasFocus"
    /// There is a cursor, and it belongs to an app the person has since switched away
    /// from. Its own reason and not `noTextFieldHasFocus`, because the two are fixed
    /// differently: this one is words arriving while the person is somewhere else.
    case cursorIsInAnotherApp
    /// The cursor in front is in another app than the one the dictation's words already
    /// went to. Its own reason and not `cursorIsInAnotherApp`, because nothing is stale
    /// here: the person moved, and the rest of what they said belongs beside the words that
    /// landed, not in whatever they moved to.
    case dictationIsInAnotherApp
    /// The app in front holds cursors and nothing says which one the person is in. Two or more
    /// of its clients are focused at once: TextEdit launched with restored windows activated two,
    /// and the one the words went to was behind the key window (low-reliability-z2z.n8z). Or none
    /// is live, though some are held: an activation in another app, or a key typed into another
    /// window, ruled them out, and macOS did not activate one again. A key typed into one settles
    /// it, and is the cursor arrival that offers the words again, so the fix named is a key that
    /// adds no text.
    case cursorIsNotSettled
    /// The bytes that arrived were not a request this input method reads whole. Answered rather
    /// than dropped, because a sender that hears nothing waits out its whole timeout and learns
    /// nothing. [LAW:no-silent-failure] An app and an input method of one build always read
    /// each other, so this is an input method of another build: one older than a field or a
    /// destination the request carries, or one from before requests were read whole, which
    /// refuses every request this build writes. Spelled on the wire as it was when a request
    /// was bare text, because that is how an input method from then refuses a request it
    /// cannot read, and the app has to read that refusal as one rather than as an answer it
    /// cannot read.
    case requestWasNotReadable = "requestWasNotText"
    /// Another input source is selected, so the text input system hands this input method
    /// no client to type into. Its own reason and not `noTextFieldHasFocus`, because the fix
    /// is the Input menu and not a click into a field, and because selecting this source
    /// again is the cursor arrival that offers the words once more.
    case inputSourceIsNotSelected
    /// The request came from a process that is not this installation's app, signed as the
    /// input method is. Answered rather than ignored, so the sender learns why instead of
    /// waiting out its timeout. This installation's own app never reads it: an input method
    /// signed by another certificate than the app fails the app's own check of who answered
    /// first, and that is the error it reports. [LAW:no-silent-failure]
    case senderIsNotThisInstallationsApp
    /// The input method's main thread did not decide where the words go in time, so nothing
    /// was committed and nothing will be. Every call into an app is made there, IMK's and the
    /// input method's own commits alike, and an app stalled while taking words holds it for
    /// 3 s (measured on low-imk-rules-w3g.3ky) - so an insert into one app is refused this way
    /// while another app's commit holds the main thread.
    case inputMethodIsBusy
    /// A request to take dictated words back, which the client in front would not do or that
    /// would not be right to do: it reports no caret, the caret is not where the words ended, or
    /// the text before it is not the words. Nothing was changed, so the words are still there.
    case wordsCannotBeTakenBack

    public var reason: String {
        switch self {
        case .noTextFieldHasFocus: "No text field has focus."
        case .cursorIsInAnotherApp: "The cursor is in an app that is not in front."
        case .dictationIsInAnotherApp: "You moved to another app while dictating."
        case .cursorIsNotSettled: "The input method cannot tell which window or field of the app in front has the cursor."
        case .requestWasNotReadable:
            "The input method is from another build of \(AppIdentity.displayName) and could not read what it was asked."
        case .inputSourceIsNotSelected: "\(AppIdentity.displayName) is not the selected input source, so it cannot type."
        case .senderIsNotThisInstallationsApp:
            "The input method takes words only from the app, signed by the certificate that signed it, and this process is not that app."
        case .inputMethodIsBusy: "An app is not answering, and it held the input method up past its time limit."
        case .wordsCannotBeTakenBack:
            "The app in front would not give the dictated words back, or they are no longer where they were left."
        }
    }

    /// Only a take-back is refused as `wordsCannotBeTakenBack`, which the cancel tells. Moving to
    /// another app is refused only once some of the dictation has landed, so it is the press that
    /// stopped which says what became of its words, and the refusal names only the cause.
    public var fate: String? {
        switch self {
        case .noTextFieldHasFocus, .cursorIsInAnotherApp, .senderIsNotThisInstallationsApp, .inputMethodIsBusy,
             .cursorIsNotSettled, .requestWasNotReadable, .inputSourceIsNotSelected:
            Self.notInserted(offeredAgainWhen: remedy)
        case .dictationIsInAnotherApp, .wordsCannotBeTakenBack: nil
        }
    }

    /// What the person does to have the refused words offered again, where they have one to make.
    public var remedy: String? {
        switch self {
        case .cursorIsNotSettled: "press an arrow key where you want it"
        case .requestWasNotReadable: Self.reinstall
        case .inputSourceIsNotSelected: "select \(AppIdentity.displayName) in the Input menu"
        case .noTextFieldHasFocus, .cursorIsInAnotherApp, .dictationIsInAnotherApp, .senderIsNotThisInstallationsApp,
             .inputMethodIsBusy, .wordsCannotBeTakenBack: nil
        }
    }

    /// A refusal commits nothing, so an insert's words are not at the cursor; `fix` is what offers
    /// them again, where the person has one to make.
    static func notInserted(offeredAgainWhen fix: String?) -> String {
        fix.map { "Your dictation was not inserted; \($0) and it is offered again." } ?? "Your dictation was not inserted."
    }

    /// The remedy for words an input method of another build would not insert, whether it could
    /// not read the request or refused it for a reason this build has no name for.
    static let reinstall = "reinstall \(AppIdentity.displayName)"
}

/// Where the words were when the channel failed, which is what decides whether saying them
/// again could put them at the cursor twice.
///
/// A property of the moment, not of the failure: the same fault before the words were sent
/// and after is one case holding each of these, never two spellings of it.
/// [LAW:one-source-of-truth]
public enum Words: Equatable, Sendable, CustomStringConvertible {
    /// The channel failed before the words were sent.
    case notSent
    /// The words went out, and nothing came back to say what became of them.
    case mayHaveLanded

    public var description: String {
        switch self {
        case .notSent: "Your dictation was not sent."
        case .mayHaveLanded: "Your dictation may have been inserted; do not dictate it again."
        }
    }
}

/// The wire failing to carry an insert, read for the words: which `WireFailure` it was, and at
/// which step of the insert. [LAW:no-silent-failure] Nothing here is retried and nothing is
/// guessed. [LAW:one-source-of-truth] Where the words are is not stored beside the failure: it
/// follows from the step and from whether the message was queued, so no value can say a
/// greeting's failure may have put words at the cursor.
public struct Unreachable: Error, Equatable, Sendable, InsertWarning {
    /// The two messages of an insert: the greeting that asks who holds the name, then the words.
    public enum Step: Equatable, Sendable {
        case greeting
        case words
    }

    public let wire: WireFailure
    public let step: Step

    public init(_ wire: WireFailure, at step: Step) {
        (self.wire, self.step) = (wire, step)
    }

    public var reason: String {
        switch (wire, step) {
        // A greeting dropped unanswered went before any words did, which is a far end not answering.
        case let (.nobodyIsListening(port), .greeting), let (.abandoned(port), .greeting):
            "No input method is answering on \(port); it is not installed or not selected."
        case let (.nobodyIsListening(port), .words): "The input method on \(port) said who it is and went away before the words were sent."
        case let (.notTaken(port, after), _): "The input method on \(port) did not take the request within \(after)."
        case let (.noAnswer(port, after), .greeting): "The input method on \(port) did not say who it is within \(after)."
        case let (.noAnswer(port, after), .words): "The input method on \(port) took the request but did not answer within \(after)."
        case let (.abandoned(port), .words): "The input method on \(port) took the request and went away without answering."
        case let (.answeredByAStranger(port, pid, because, required), _):
            "pid \(pid) answered on \(port) and is not the input method, \(required) - \(because)."
        case let (.failedToSend(port, status), _), let (.failedToReceive(port, status), _):
            "The request to \(port) failed: \(Mach.describe(status))."
        case let (.notReadable(port, bytes), _): "The input method on \(port) answered \(bytes) bytes that are not an answer."
        }
    }

    public var fate: String? { "\(words)" }

    /// Where the words were when the wire failed: unsent at the greeting, and at the words
    /// unsent only until the message was queued.
    public var words: Words { step == .words && wire.queued ? .mayHaveLanded : .notSent }
}

/// Why an insert's words are not at the cursor: everything an `Inserter` throws.
///
/// [LAW:types-are-the-program] A closed set, so whoever holds one has every way an insert
/// fails in front of it, and a new way is a new case the compiler walks every reader to.
public enum InsertFailure: Error, Equatable, Sendable, InsertWarning {
    case refused(Refusal)
    /// Refused for a reason this build has no name for, which only an input method of another
    /// build can give. A refusal commits nothing, whatever its reason, so the words are held
    /// like any refusal's and not taken for words that may have landed.
    case refusedForAnUnknownReason(String)
    case notYetTaken(NotYetTaken)
    case unreachable(Unreachable)
    /// This end could not write down who may answer, so it asked nobody.
    case answererUnreadable(PeerIdentity.Unreadable)

    public var reason: String {
        switch self {
        case .refused(let refusal): refusal.reason
        case .refusedForAnUnknownReason(let code):
            "The input method is from another build of \(AppIdentity.displayName) and refused the request for a reason this app does not know (\(code))."
        case .notYetTaken(let notYetTaken): notYetTaken.reason
        case .unreachable(let unreachable): unreachable.reason
        case .answererUnreadable(let unreadable): "The app could not say which input method may answer it: \(unreadable)."
        }
    }

    public var fate: String? {
        switch self {
        case .refused(let refusal): refusal.fate
        case .refusedForAnUnknownReason: Refusal.notInserted(offeredAgainWhen: remedy)
        case .notYetTaken(let notYetTaken): notYetTaken.fate
        case .unreachable(let unreachable): unreachable.fate
        case .answererUnreadable: "\(Words.notSent)"
        }
    }

    /// What the person does to have the words offered again: only a refusal has one, since every
    /// other failure is the channel's, and no step of theirs mends it.
    public var remedy: String? {
        switch self {
        case .refused(let refusal): refusal.remedy
        case .refusedForAnUnknownReason: Refusal.reinstall
        case .notYetTaken, .unreachable, .answererUnreadable: nil
        }
    }

    /// Whether the words could be at a cursor anyway: handed to an app that had not taken
    /// them yet, or sent with no answer to say what became of them. Offering such words
    /// again is the one way to type them twice. Every other failure came before a client held
    /// them, and the words are nowhere. [LAW:one-source-of-truth] `Words` says it for the
    /// channel; this says it for every failure an `Inserter` throws.
    public var wordsMayHaveLanded: Bool {
        switch self {
        case .notYetTaken: true
        case .unreachable(let unreachable): unreachable.words == .mayHaveLanded
        case .refused, .refusedForAnUnknownReason, .answererUnreadable: false
        }
    }
}

/// The wire, which is the one place either half turns a value into bytes or back.
///
/// Messages cross it told apart by their Mach id: the greeting, empty, which the input
/// method answers with its build once it has admitted the sender; the words; and, the other
/// way, a cursor the input method was just given focus in, carrying its build, which nobody
/// answers, and the two questions it asks about a Return it holds, which the app does.
/// [LAW:single-enforcer]
///
/// A build crosses as JSON, and none crosses as nothing at all, which is how every input
/// method from before builds were compared answers a greeting and tells an arrival.
///
/// The request and the answer are both values with more than one field, so both cross as
/// JSON, which is the codec Swift already writes for them. Both directions are held by
/// tests against the values, never against the bytes: what matters is that what goes in
/// comes out. [LAW:behavior-not-structure]
///
/// The app and the input method may be of different builds, so each reads the other as far
/// as it can and refuses or reports the rest by name. A request is an order, and is done
/// only when read whole: one carrying anything this build does not know is refused, never
/// done as something it is not. An answer is a report, and a refusal in it stays a refusal
/// whatever reason it names. A notice or a question the app does not know is let go, and the
/// input method hears its question was dropped. [LAW:no-silent-failure]
enum Wire {
    static let greeting: mach_msg_id_t = 1
    static let insert: mach_msg_id_t = 2
    // 3 was the modifier keys, which the app now hears itself. Not reused, so an input method
    // from before still running past an install is told as not understood, not misread.
    static let cursorArrived: mach_msg_id_t = 4
    static let overMemoryCeiling: mach_msg_id_t = 5
    /// The questions the input method asks the app about a key it holds, each answered: whether
    /// anything is owed, then whether what is owed settled, and to take an Escape. Retired and not
    /// reused: 8, the Escape cancel question; 9, an Escape told after it was kept; and 10, whether
    /// the word box was open, which 11 replaced by asking and acting in one turn.
    static let owed: mach_msg_id_t = 6
    static let settled: mach_msg_id_t = 7
    static let escape: mach_msg_id_t = 11

    /// The first byte of every request, and one no UTF-8 text contains. An input method built
    /// when a request was its bare text, still running past an install, reads this as bytes
    /// that are not text and refuses them, rather than typing the request out.
    ///
    /// 0xFF was the mark while a request was read by the fields the reader knew, the rest
    /// passed over, so an input method from then would do a request to take words back as one
    /// to insert nothing. It refuses this mark as it refuses any bytes that are not a request.
    static let requestMark: UInt8 = 0xFE

    // The encoder cannot fail on these types: every case holds `Codable` primitives and
    // nothing else. Said here, at the one place it is true, rather than as a throw every
    // caller would carry and none could act on.
    static func request(_ request: InsertRequest) -> Data { Data([requestMark]) + (try! JSONEncoder().encode(request)) }

    /// [LAW:parse-dont-validate] A request read whole, or nothing at all. Whole is the JSON
    /// written again from the request being the JSON that arrived, which a key, a destination
    /// or a value this build does not know cannot pass: it is lost in the reading, and doing
    /// the rest of the request would be doing something the app did not ask.
    static func request(of data: Data) -> InsertRequest? {
        let json = { (data: Data) in (try? JSONSerialization.jsonObject(with: data)) as? NSObject }
        guard data.first == requestMark,
              let request = try? JSONDecoder().decode(InsertRequest.self, from: data.dropFirst()),
              json(data.dropFirst()) == json(Self.request(request).dropFirst())
        else { return nil }
        return request
    }

    static func answer(_ answer: InsertionAnswer) -> Data { try! JSONEncoder().encode(answer) }

    /// The build an input method says, in a greeting's answer and in each arrival.
    static func said(_ build: Build?) -> Data { build.map { try! JSONEncoder().encode($0) } ?? Data() }

    /// [LAW:parse-dont-validate] The build said, nothing when nothing was said, or nil when
    /// what was said is no build.
    private static func build(of data: Data) -> Build?? {
        guard !data.isEmpty else { return .some(nil) }
        return (try? JSONDecoder().decode(Build.self, from: data)).map(Optional.some)
    }

    /// [LAW:parse-dont-validate] A greeting's answer, or nothing at all. The refusal is an
    /// insert's answer, because the port refuses a sender the same way whichever message
    /// it sent.
    static func greeting(of data: Data) -> Greeting? {
        if build(of: data) != nil { return .admitted }
        guard case .refused(let refusal)? = answer(of: data) else { return nil }
        return .refused(refusal)
    }

    /// Admitted whichever build the input method said, since words go to an input method of
    /// any build, or refused.
    enum Greeting: Equatable {
        case admitted
        case refused(Refusal)
    }

    /// [LAW:parse-dont-validate] An answer or nothing at all.
    ///
    /// An insert naming no app is not refused here: only this installation's input method
    /// is believed, and it refuses one at its own border, in `Client.init?`. [LAW:single-enforcer]
    static func answer(of data: Data) -> InsertionAnswer? {
        try? JSONDecoder().decode(InsertionAnswer.self, from: data)
    }

    /// The reason a refusal names, read for one `answer(of:)` cannot read: a refusal for a
    /// reason this build has no name for. Nil for bytes that are no refusal at all, and for an
    /// answer carrying anything beside its refusal, which may be words that landed.
    static func refusalReason(of data: Data) -> String? {
        struct Reason: Decodable { let _0: String }
        guard let answer = try? JSONDecoder().decode([String: Reason].self, from: data), answer.count == 1 else { return nil }
        return answer["refused"]?._0
    }

    static func overrun(_ overrun: Overrun) -> Data { try! JSONEncoder().encode(overrun) }

    /// A question's payload: the moment the Return went down.
    private struct Stamp: Codable { let timestamp: TimeInterval }

    static func stamp(_ timestamp: TimeInterval) -> Data { try! JSONEncoder().encode(Stamp(timestamp: timestamp)) }

    /// The latest moment a stamp may name: a machine up for 31 years. `HostTime(seconds:)` counts
    /// nanoseconds in an Int64 and traps past 292 years, so a stamp beyond this is not a moment
    /// on the clock whatever its size.
    private static let latestStamp: TimeInterval = 1e9

    /// [LAW:parse-dont-validate] The question a message asks, or nil when it asks none this
    /// app knows. A stamp that is not a moment on the clock is no question.
    static func question(id: mach_msg_id_t, payload: Data?) -> Question? {
        guard let stamp = payload.flatMap({ try? JSONDecoder().decode(Stamp.self, from: $0) }),
              (0...latestStamp).contains(stamp.timestamp) else { return nil }
        return switch id {
        case owed: .owed(at: stamp.timestamp)
        case settled: .settled(at: stamp.timestamp)
        case escape: .escape(at: stamp.timestamp)
        default: nil
        }
    }

    static func owing(_ owing: Owing) -> Data { try! JSONEncoder().encode(owing) }
    static func owing(of data: Data) -> Owing? { try? JSONDecoder().decode(Owing.self, from: data) }
    static func settlement(_ settlement: Settlement) -> Data { try! JSONEncoder().encode(settlement) }
    static func settlement(of data: Data) -> Settlement? { try? JSONDecoder().decode(Settlement.self, from: data) }
    static func dismissal(_ dismissal: Dismissal) -> Data { try! JSONEncoder().encode(dismissal) }
    static func dismissal(of data: Data) -> Dismissal? { try? JSONDecoder().decode(Dismissal.self, from: data) }

    /// [LAW:parse-dont-validate] The notice the input method process `pid` sent, or nil when
    /// the message is none, or its payload is not what its id says. A cursor arrival carries
    /// the build it said, or nothing when it said none.
    static func notice(id: mach_msg_id_t, payload: Data?, from pid: pid_t) -> InputMethodNotice? {
        switch id {
        case cursorArrived: build(of: payload ?? Data()).map { .cursorArrived(CursorArrival(pid: pid, build: $0)) }
        case overMemoryCeiling: payload.flatMap { try? JSONDecoder().decode(Overrun.self, from: $0) }.map { .overMemoryCeiling(pid: pid, $0) }
        default: nil
        }
    }
}
