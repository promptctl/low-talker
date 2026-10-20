import Dictation
import Foundation
import LowTalkerCore
import Testing

/// The file the app keeps what is held in, in a directory of its own.
@MainActor
final class HeldFileTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "held-\(UUID())")
    var file: HeldFile { HeldFile(url: directory.appending(path: "held.json")) }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated static let states: [HoldState] = [
        HoldState(held: .unplaced(Held.Part(words: Transcript(words: [Transcript.Word(text: " hello", time: 0.12...0.48, confidence: 0.73), Transcript.Word(text: " there.", time: 0.5...0.9, confidence: 0.91)]), warning: "refused")!)),
        HoldState(held: .unplaced(part(" b", "refused"), unaccounted: part("a", "may have landed"))),
        HoldState(held: .unaccounted(part("a", "may have landed"))),
        HoldState(dismissed: .unplaced(part(" b", "refused"), unaccounted: part("a", "may have landed"))),
        HoldState(held: .unplaced(part("c", "refused")), dismissed: .unaccounted(part("a", "may have landed"))),
    ]

    @Test(arguments: states) func whatIsWrittenIsReadBack(_ state: HoldState) throws {
        try file.write(state)
        #expect(try file.read() == state)
    }

    /// Nothing held or dismissed is no file, and removing a file that is not there is nothing
    /// to fail at.
    @Test func nothingHeldIsNoFile() throws {
        try file.write(HoldState(dismissed: .unaccounted(part("a", "u"))))
        try file.write(HoldState())
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(try file.read() == HoldState())
        try file.write(HoldState())
    }

    /// Not JSON; a warning with no words; words that may have landed with no warning; blank
    /// words; no part at all, held or dismissed; and the shape builds of 2026-10-19 wrote before
    /// words that may have landed were kept.
    @Test(arguments: [
        "not json",
        #"{"warning":"refused"}"#,
        #"{"unaccounted":{"words":[{"text":"a","time":[0,1],"confidence":1}]}}"#,
        #"{"unplaced":{"words":[]},"warning":"refused"}"#,
        "{}",
        #"{"dismissed":{}}"#,
        #"{"unaccounted":"may have landed"}"#,
    ])
    func aFileThatCannotBeReadIsMovedWhereNoWriteReplacesIt(_ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
        let error = try #require(throws: HeldUnreadable.self) { try file.read() }
        guard case .movedTo(let path) = error.kept else {
            Issue.record("left in place: \(error)")
            return
        }
        #expect(try Data(contentsOf: URL(filePath: path)) == Data(text.utf8))
        #expect(try file.read() == HoldState())
    }

    /// A file as this build writes it, so a change to `Transcript` that a later build could not
    /// read it with fails here rather than at the upgrade.
    @Test func aFileAsThisBuildWritesItReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"unplaced":{"words":[{"text":" hello","time":[0.12,0.48],"confidence":0.73}]},"warning":"refused","unaccounted":{"words":[{"text":"a","time":[0,0.1],"confidence":0.5}]},"unaccountedWarning":"may have landed"}"#.utf8).write(to: file.url)
        let hello = Transcript(words: [Transcript.Word(text: " hello", time: 0.12...0.48, confidence: 0.73)])
        let a = Transcript(words: [Transcript.Word(text: "a", time: 0...0.1, confidence: 0.5)])
        #expect(try file.read() == HoldState(held: .unplaced(Held.Part(words: hello, warning: "refused")!, unaccounted: Held.Part(words: a, warning: "may have landed")!)))
    }

    /// A file as this build writes it with words both held and dismissed.
    @Test func aFileWithWordsDismissedReads() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"unaccounted":{"words":[{"text":"a","time":[0,0.1],"confidence":0.5}]},"unaccountedWarning":"may have landed","dismissed":{"unplaced":{"words":[{"text":" hello","time":[0.12,0.48],"confidence":0.73}]},"warning":"refused"}}"#.utf8).write(to: file.url)
        let hello = Transcript(words: [Transcript.Word(text: " hello", time: 0.12...0.48, confidence: 0.73)])
        let a = Transcript(words: [Transcript.Word(text: "a", time: 0...0.1, confidence: 0.5)])
        #expect(try file.read() == HoldState(held: .unaccounted(Held.Part(words: a, warning: "may have landed")!), dismissed: .unplaced(Held.Part(words: hello, warning: "refused")!)))
    }

    /// A field this build does not know is one a later build added, and the rest still reads.
    @Test func aFieldALaterBuildAddsLeavesTheFileReadable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"unaccounted":{"words":[{"text":"a","time":[0,1],"confidence":1}]},"unaccountedWarning":"may have landed","later":{"words":[]}}"#.utf8).write(to: file.url)
        #expect(try file.read() == HoldState(held: .unaccounted(Held.Part(words: Transcript(words: [Transcript.Word(text: "a", time: 0...1, confidence: 1.0)]), warning: "may have landed")!)))
    }

    /// A write that fails removes what stood at the path, so no older state is offered at the
    /// next launch: here a directory the atomic rename cannot replace, and removal can.
    @Test func aWriteThatFailsLeavesNothingKept() throws {
        try FileManager.default.createDirectory(at: file.url.appending(path: "in-the-way"), withIntermediateDirectories: true)
        let error = try #require(throws: HeldUnkept.self) { try file.write(HoldState(held: .unaccounted(part("a", "u")))) }
        guard case .lost = error else {
            Issue.record("not lost: \(error)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    /// A write that cannot remove the older file either says the older state still stands.
    @Test(arguments: [HoldState(held: .unaccounted(part("b", "newer"))), HoldState()])
    func aWriteThatCannotRemoveTheOlderFileSaysItStands(_ state: HoldState) throws {
        try file.write(HoldState(held: .unaccounted(part("a", "older"))))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let error = #expect(throws: HeldUnkept.self) { try file.write(state) }
        guard case .stale? = error else {
            Issue.record("not stale: \(String(describing: error))")
            return
        }
        #expect(try file.read() == HoldState(held: .unaccounted(part("a", "older"))))
    }
}
