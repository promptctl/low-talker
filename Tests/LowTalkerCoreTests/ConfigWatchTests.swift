import Foundation
import LowTalkerCore
import Testing

/// The config kept current with its file: what a save does to the config the app is
/// already running on, and what a save it cannot understand does not do to it.
@Suite struct ConfigWatchTests {
    static func file(chord: String) -> String {
        """
        [[modes]]
        name = "dictation"
        chord = { modifiers = ["\(chord)"] }
        """
    }

    static let onRightCommand = file(chord: "rightCommand")
    static let onLeftControl = file(chord: "leftControl")
    /// TOML that stops being TOML part way through a table header.
    static let notTOML = "model = \"base.en\"\n[[modes\n"

    static func config(_ toml: String) throws -> Config {
        try Config(toml: toml, prompting: .countingWords())
    }

    // MARK: - What a reading does to the running config

    // These hand `next(reading:)` a reading rather than a filesystem, so every rule about
    // what a save does is settled without a file, a watch, or a wait.

    /// A save whose mode the engine cannot be told is refused and the running config kept,
    /// and the `config:` event says which mode and the limit.
    @Test func aSaveWithAVocabularyTooLongKeepsTheRunningConfig() throws {
        let running = try Self.config(Self.onRightCommand)
        let tooLong = """
            [[modes]]
            name = "names"
            vocabulary = ["One", "Two", "Three"]
            """
        let next = RunningConfig.adopted(running).next(reading: Result { () throws(ConfigError) in try Config(toml: tooLong, prompting: .countingWords(limit: 2)) })
        #expect(next == .kept(running, because: .vocabulary(mode: "names", .tooLong(tokens: 3, limit: 2))))
        #expect(next?.description == #"the last save was refused, so the config before it still runs: mode "names": the vocabulary is 3 prompt tokens and the engine keeps at most 2"#)
    }

    @Test func aReadingThatSaysWhatTheLastOneSaidIsNotReported() throws {
        let last = RunningConfig.adopted(try Self.config(Self.onRightCommand))
        #expect(last.next(reading: last.config) == nil)
    }

    @Test func aDifferentConfigIsAdopted() throws {
        let last = RunningConfig.adopted(try Self.config(Self.onRightCommand))
        let saved = try Self.config(Self.onLeftControl)
        #expect(last.next(reading: .success(saved)) == .adopted(saved))
    }

    /// The rule this type exists for: a save that cannot be understood costs the author
    /// nothing, because what they were running goes on running, and the refusal is named.
    @Test func aRefusedReadingKeepsTheRunningConfigAndNamesWhy() throws {
        let running = try Self.config(Self.onRightCommand)
        let reload = RunningConfig.adopted(running).next(reading: .failure(.noModes))
        #expect(reload == .kept(running, because: .noModes))
        #expect(reload?.config == .success(running))
        #expect(reload?.refusal == .noModes)
    }

    /// A refusal that still stands is not news.
    @Test func aFileRefusedTwiceOverIsOneRefusal() throws {
        let refused = try #require(RunningConfig.adopted(try Self.config(Self.onRightCommand)).next(reading: .failure(.noModes)))
        #expect(refused.next(reading: .failure(.noModes)) == nil)
    }

    /// The author breaks the file and then undoes the edit. The config is the one already
    /// running, so comparing configs alone would say nothing happened - but the refusal
    /// standing against it has been lifted, and the menu has to stop saying it.
    @Test func undoingABadSaveIsReportedEvenThoughTheConfigIsUnchanged() throws {
        let running = try Self.config(Self.onRightCommand)
        let refused = try #require(RunningConfig.adopted(running).next(reading: .failure(.noModes)))
        let undone = refused.next(reading: .success(running))
        #expect(undone == .adopted(running))
        #expect(undone?.refusal == nil)
    }

    /// A file refused at launch leaves nothing to keep; fixing it is the first adoption.
    @Test func aFileRefusedAtLaunchIsAdoptedOnceItReads() throws {
        let launch = RunningConfig(reading: .failure(.noModes))
        #expect(launch == .refused(.noModes))
        #expect(launch.config == .failure(.noModes))
        #expect(launch.next(reading: .failure(.modeUnnamed)) == .refused(.modeUnnamed))
        let fixed = try Self.config(Self.onRightCommand)
        #expect(launch.next(reading: .success(fixed)) == .adopted(fixed))
    }

    /// What a reload says it moved is every setting whose value changed, and only those: a
    /// save that moves the chord, or gives the mode a vocabulary, and leaves the rest names
    /// the modes alone, and one that moves every setting names each.
    @Test func aReloadNamesTheSettingsItMoved() throws {
        let was = try Self.config(Self.onRightCommand)
        #expect(was.settings(changedFrom: was) == [])
        #expect(try Self.config(Self.onLeftControl).settings(changedFrom: was) == [.modes])
        #expect(try Self.config(Self.onRightCommand + "\nvocabulary = [\"Brynleigh\"]").settings(changedFrom: was) == [.modes])
        let everything = try Self.config("""
            microphone = { at_rest = "open" }
            [serve]
            interface = "192.168.1.20"
            token = "t"
            [[modes]]
            name = "dictation"
            chord = { modifiers = ["leftControl"] }
            """)
        #expect(everything.settings(changedFrom: was) == [.modes, .microphone, .serve])
    }

    // MARK: - Against a real file

    // A real directory and a real FSEvents stream, because what these prove is that the
    // watch hears an edit at all, which no fake filesystem could establish. The time limits
    // fail a hung test rather than time anything: each waits on the stream itself.

    /// A directory to write configs into, and the config path inside it, made only when
    /// `existing` says so: a config directory nobody has created yet is the state of a fresh
    /// install, and a watch has to survive it.
    static func scratch(existing: Bool) throws -> (root: URL, directory: URL, file: URL) {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        let directory = root.appending(path: "low-talker")
        try FileManager.default.createDirectory(at: existing ? directory : root, withIntermediateDirectories: true)
        return (root, directory, directory.appending(path: "config.toml"))
    }

    /// A watch on `file` that is already past the read it does as it comes up, so every edit
    /// after this can only have been heard by FSEvents.
    static func watching(_ file: URL, settlingOn settling: String) async throws
        -> (running: Config, reloads: AsyncStream<RunningConfig>.AsyncIterator)
    {
        let launch = RunningConfig(reading: Result { () throws(ConfigError) in try Config.load(file, prompting: .countingWords()) })
        var reloads = RunningConfig.reloads(of: file, after: launch, prompting: .countingWords()).makeAsyncIterator()
        try settling.write(to: file, atomically: true, encoding: .utf8)
        let settled = try config(settling)
        #expect(await reloads.next() == .adopted(settled))
        return (settled, reloads)
    }

    @Test(.timeLimit(.minutes(1)))
    func editingTheChordTakesEffect() async throws {
        let (root, _, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)

        let reload = try #require(await reloads.next())
        #expect(try reload.config.get().modes.chords == [KeyChord(modifiers: .leftControl)])
    }

    /// A syntax error saved mid-edit leaves the app on the config it already had, and names
    /// the line reading stopped on.
    @Test(.timeLimit(.minutes(1)))
    func aSyntaxErrorLeavesTheRunningConfigInPlace() async throws {
        let (root, _, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var (running, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.notTOML.write(to: file, atomically: true, encoding: .utf8)

        let reload = try #require(await reloads.next())
        #expect(reload.config == .success(running))
        // The wording around the line is TOML++'s and is not this test's to pin.
        guard case .kept(_, .notTOML(_, let line)) = reload else {
            Issue.record("expected .kept with a parse fault, got \(reload)")
            return
        }
        #expect(line == 2)
    }

    /// A save that changes nothing is not reported - proven by making a real change after it
    /// and finding that change, rather than the touch, at the head of the stream.
    @Test(.timeLimit(.minutes(1)))
    func aSaveThatChangesNothingIsNotReported() async throws {
        let (root, directory, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try Self.onRightCommand.write(to: file, atomically: true, encoding: .utf8)
        try "not a config".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)

        #expect(await reloads.next() == .adopted(try Self.config(Self.onLeftControl)))
    }

    /// The config directory does not exist when the watch starts, which is a fresh install:
    /// nothing has ever written a config.
    @Test(.timeLimit(.minutes(1)))
    func aConfigDirectoryThatDoesNotExistYetIsStillWatched() async throws {
        let (root, directory, file) = try Self.scratch(existing: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = RunningConfig(reading: Result { () throws(ConfigError) in try Config.load(file, prompting: .countingWords()) })
        #expect(launch == .adopted(.default))

        var reloads = RunningConfig.reloads(of: file, after: launch, prompting: .countingWords()).makeAsyncIterator()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.onRightCommand.write(to: file, atomically: true, encoding: .utf8)
        #expect(await reloads.next() == .adopted(try Self.config(Self.onRightCommand)))

        // The edit that carries the claim: the watch went up on a directory that was not
        // there, and still hears saves in the one made since.
        try Self.onLeftControl.write(to: file, atomically: true, encoding: .utf8)
        #expect(await reloads.next() == .adopted(try Self.config(Self.onLeftControl)))
    }

    /// Deleting the file goes back to the defaults.
    @Test(.timeLimit(.minutes(1)))
    func deletingTheFileGoesBackToTheDefaults() async throws {
        let (root, _, file) = try Self.scratch(existing: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var (_, reloads) = try await Self.watching(file, settlingOn: Self.onRightCommand)

        try FileManager.default.removeItem(at: file)

        #expect(await reloads.next() == .adopted(.default))
    }
}
