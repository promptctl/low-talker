import Foundation
import LowTalkerCore
import Testing

/// The config as the app meets it: what a file says, what an absent file says, and what
/// a file that was written but cannot be understood says instead of running anyway.
@Suite struct ConfigTests {
    static func config(_ toml: String) throws(ConfigError) -> Config {
        try Config(toml: toml, prompting: .countingWords())
    }

    /// Every key at once: the engine choice, the microphone at rest, chords to modes, and a
    /// mode's vocabulary.
    static let full = """
        model = "base.en"

        [microphone]
        at_rest = "open"

        [[modes]]
        name = "dictation"
        chord = { modifiers = ["rightOption"] }

        [[modes]]
        name = "slack"
        chord = { modifiers = ["leftCommand", "leftShift"] }
        vocabulary = ["Kubernetes", "  Anthropic\\n"]

        [[modes]]
        name = "notes"
        chord = { modifiers = ["rightCommand"] }
        """

    @Test func aFullFileParses() throws {
        let config = try Self.config(Self.full)
        #expect(config.model == "base.en")
        #expect(config.microphone == .open)
        #expect(config.modes.map(\.name) == ["dictation", "slack", "notes"])

        let slack = try #require(config.modes.first { $0.name == "slack" })
        #expect(slack.chord == KeyChord(modifiers: .leftCommand, .leftShift))
        #expect(slack.vocabulary.terms.map(\.text) == ["Kubernetes", "Anthropic"])
    }

    /// The whole point of defaults: the app runs with no file written at all.
    @Test func anEmptyFileIsTheDefaults() throws {
        #expect(try Self.config("") == Config.default)
    }

    /// A key the file leaves out is the default for that key alone; naming a model does
    /// not cost you the modes.
    @Test func aKeyLeftOutKeepsItsDefault() throws {
        let config = try Self.config(#"model = "base.en""#)
        #expect(config.model == "base.en")
        #expect(config.modes == Config.default.modes)
    }

    /// The epic's rule, pinned where the only writer of it is: a microphone held while
    /// nobody is dictating is one the user asked for in writing. A file that says nothing
    /// about it - which is every file anyone has written so far, and the absence of a file
    /// too - leaves the device closed.
    @Test func aFileThatAsksForNothingLeavesTheMicrophoneShutAtRest() throws {
        #expect(Config.default.microphone == .shut)
        #expect(try Self.config("").microphone == .shut)
        #expect(try Self.config(#"model = "base.en""#).microphone == .shut)
    }

    /// Asking for it is one line, and it is the line the epic wants a user to have to
    /// write on purpose.
    @Test func aFileCanAskForTheMicrophoneToBeHeld() throws {
        #expect(try Self.config("""
            [microphone]
            at_rest = "open"
            """).microphone == .open)
    }

    /// [LAW:no-silent-failure] A resting state nobody can spell is the one place a typo
    /// would decide whether the device is open, so it is refused in the word the file
    /// wrote rather than falling back to either reading.
    @Test func aWordThatIsNotARestingStateIsRefused() {
        #expect(throws: ConfigError.wrongShape(#"microphone.at_rest: "sometimes" is not something the microphone does at rest"#)) {
            try Self.config("""
                [microphone]
                at_rest = "sometimes"
                """)
        }
    }

    /// A heading with nothing under it is a file whose author meant something by writing
    /// it, and the one thing it cannot be read as is the default they were already getting.
    @Test func aMicrophoneTableThatSaysNothingIsRefused() {
        #expect(throws: ConfigError.wrongShape("microphone.at_rest is missing")) {
            try Self.config("[microphone]")
        }
    }

    /// [LAW:one-source-of-truth] The defaults are the values their own owners name, so
    /// this fails the moment a second spelling of one appears.
    @Test func theDefaultsAreTheValuesTheirOwnersName() {
        #expect(Config.default.model == ModelName.default)
        #expect(Array(Config.default.modes) == [Mode.dictation])
        #expect(Mode.dictation.chord == Hotkey.defaultChord)
        #expect(Mode.dictation.vocabulary == .empty)
    }

    /// The modes as the log names them: each one's name, chord and how many terms it
    /// expects, never the terms, which can be the names of people.
    @Test func modesAreLoggedByNameChordAndTermCount() throws {
        let notes = Mode(name: "notes", chord: KeyChord(modifiers: .rightCommand),
                         vocabulary: Vocabulary([try Vocabulary.Term("Brynleigh Fryslie"), try Vocabulary.Term("Kubernetes")]))
        let modes = try Modes([.dictation, notes])
        #expect("\(modes)" == #"[mode "dictation" (Right Option, 0 vocabulary terms), mode "notes" (Right Command, 2 vocabulary terms)]"#)
    }

    /// [LAW:one-source-of-truth] A mode with no chord listens for the default one, the
    /// chord `Hotkey.defaultChord` names.
    @Test func aModeWithNoChordHearsTheDefaultChord() throws {
        let config = try Self.config("""
            [[modes]]
            name = "dictation"
            """)
        #expect(try #require(config.modes.first).chord == Hotkey.defaultChord)
    }

    /// The input method is told only of the modifier keys, so a chord with another key in
    /// it would never be heard, and a key is nothing a chord can say.
    @Test func aChordWithAKeyIsRefused() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].chord.key"])) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["leftCommand"], key = 2 }
                """)
        }
    }

    /// A chord written under a hotkey source's name, as a config once named one per source,
    /// is refused rather than read as a chord that quietly changes nothing.
    @Test func aChordUnderASourcesNameIsRefused() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].chord.inputMethod"])) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"], inputMethod = { modifiers = ["rightOption"] } }
                """)
        }
    }

    // MARK: - What a file gets told it did wrong

    /// [LAW:no-silent-failure] A file nobody can read is not a file that says nothing.
    @Test func aFileThatIsNotTOMLNamesTheLineItStoppedOn() throws {
        let error = try #require(throws: ConfigError.self) {
            try Self.config("model = \"base.en\"\nthis is not toml\n")
        }
        guard case .notTOML(_, let line) = error else {
            Issue.record("expected notTOML, got \(error)")
            return
        }
        #expect(line == 2)
    }

    /// A misspelled key would otherwise be a line that quietly does nothing.
    @Test func aKeyNothingIsCalledIsNamed() throws {
        let error = try #require(throws: ConfigError.self) {
            try Self.config(#"modle = "base.en""#)
        }
        guard case .unknownKeys(let keys) = error else {
            Issue.record("expected unknownKeys, got \(error)")
            return
        }
        #expect(keys == ["modle"])
    }

    @Test func aValueOfTheWrongKindNamesItsKey() throws {
        let error = try #require(throws: ConfigError.self) { try Self.config("model = 3") }
        #expect("\(error)".contains("model"))
    }

    @Test func aConfigWithNoModesIsRefused() {
        #expect(throws: ConfigError.noModes) { try Self.config("modes = []") }
    }

    @Test func aModeWithoutANameIsRefused() {
        #expect(throws: ConfigError.modeUnnamed) {
            try Self.config("""
                [[modes]]
                name = "  "
                chord = { modifiers = ["rightOption"] }
                """)
        }
    }

    @Test func twoModesWithOneNameAreRefused() {
        #expect(throws: ConfigError.twoModesNamed("dictation")) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightCommand"] }
                """)
        }
    }

    /// Two modes on one chord is a config with no answer to "which mode is this".
    @Test func twoModesOnOneChordAreRefused() {
        #expect(throws: ConfigError.twoModesOnOneChord("second")) {
            try Self.config("""
                [[modes]]
                name = "first"
                chord = { modifiers = ["rightOption"] }

                [[modes]]
                name = "second"
                chord = { modifiers = ["rightOption"] }
                """)
        }
    }

    /// [LAW:single-enforcer] The rule that a chord has at least one modifier belongs to
    /// KeyChord, and the config file gets it without restating it - including the
    /// sentence KeyChord wrote.
    @Test func aChordWithNothingInItIsRefusedInKeyChordsOwnWords() throws {
        let error = try #require(throws: ConfigError.self) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = [] }
                """)
        }
        #expect("\(error)".contains("a chord needs at least one modifier"))
    }

    /// [LAW:single-enforcer] Likewise the rule about what a vocabulary term may be.
    @Test func aVocabularyTermWithNoWordIsRefused() {
        #expect(throws: ConfigError.wrongShape(#"modes[0].vocabulary[0]: vocabulary term "..." has no word in it"#)) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["rightOption"] }
                vocabulary = ["..."]
                """)
        }
    }

    /// Which `[[modes]]` entry is at fault, counted as the file lists them.
    @Test func aMissingKeyNamesTheModeItIsIn() {
        #expect(throws: ConfigError.wrongShape("modes[1].name is missing")) {
            try Self.config("""
                [[modes]]
                name = "dictation"

                [[modes]]
                vocabulary = ["x"]
                """)
        }
    }

    /// Two modes that each leave the chord out both listen for the default chord,
    /// which is one chord for two modes.
    @Test func twoModesLeavingTheChordOutAreRefused() {
        #expect(throws: ConfigError.twoModesOnOneChord("second")) {
            try Self.config("""
                [[modes]]
                name = "first"

                [[modes]]
                name = "second"
                """)
        }
    }

    /// [LAW:single-enforcer] The sentence is ModelName's own, so it speaks of model
    /// names rather than of the Swift type the parser happened to be building.
    @Test func aModelNameThatIsNotOneIsRefusedInItsOwnWords() {
        #expect(throws: ConfigError.wrongShape(#"model: ".." is not a model name: one folder in the model repo, such as base.en"#)) {
            try Self.config(#"model = "..""#)
        }
    }

    /// A modifier that is not one is answered with the ones that are.
    @Test func aModifierThatIsNotOneIsNamedWithTheOnesThatAre() {
        let modifiers = Modifier.allCases.map(\.rawValue).joined(separator: ", ")
        #expect(throws: ConfigError.wrongShape(#"modes[0].chord.modifiers[0]: "banana" is not a modifier: "# + modifiers)) {
            try Self.config("""
                [[modes]]
                name = "dictation"
                chord = { modifiers = ["banana"] }
                """)
        }
    }

    /// A typo is placed like every other fault, so two of them in different modes are
    /// each named where they sit rather than as bare words.
    @Test func typosInDifferentModesAreEachPlaced() {
        #expect(throws: ConfigError.unknownKeys(["modes[0].chrod", "modes[1].vocabualry"])) {
            try Self.config("""
                [[modes]]
                name = "a"
                chord = { modifiers = ["rightOption"] }
                chrod = 1

                [[modes]]
                name = "b"
                chord = { modifiers = ["rightCommand"] }
                vocabualry = ["x"]
                """)
        }
    }

    /// [LAW:no-silent-failure] TOMLKit keys its unexpected-key report by name, so one
    /// misspelling made twice arrives as a single entry - the second is lost before this
    /// package sees it. The file is still refused and the entry that survives says
    /// exactly where it is, so the other surfaces on the next run. Pinned so that a
    /// TOMLKit that starts reporting both fails here rather than going unnoticed.
    @Test func oneMisspellingRepeatedArrivesOncePlaced() {
        let error = #expect(throws: ConfigError.self) {
            try Self.config("""
                [[modes]]
                name = "a"
                chord = { modifiers = ["rightOption"] }
                chrod = 1

                [[modes]]
                name = "b"
                chord = { modifiers = ["rightCommand"] }
                chrod = 2
                """)
        }
        guard case .unknownKeys(let keys)? = error else {
            Issue.record("expected .unknownKeys, got \(String(describing: error))")
            return
        }
        #expect(keys.count == 1)
        #expect(keys.first?.hasSuffix(".chrod") == true)
    }

    /// A mode whose vocabulary the engine cannot be told refuses the file as it is read,
    /// naming the mode, the vocabulary's size and the limit, so no press in it ever begins.
    @Test func aVocabularyTooLongForTheEngineRefusesTheFileByMode() {
        let error = #expect(throws: ConfigError.vocabulary(mode: "names", .tooLong(tokens: 6, limit: 5))) {
            try Config(toml: Self.names(6), prompting: .countingWords(limit: 5))
        }
        #expect(error?.description == #"mode "names": the vocabulary is 6 prompt tokens and the engine keeps at most 5"#)
    }

    @Test func aVocabularyAtTheEnginesLimitIsRead() throws {
        let config = try Config(toml: Self.names(5), prompting: .countingWords(limit: 5))
        #expect(config.modes.map(\.vocabulary.terms.count) == [5])
    }

    /// A mode named "names" whose vocabulary is `count` one-word terms.
    static func names(_ count: Int) -> String {
        """
        [[modes]]
        name = "names"
        vocabulary = [\((1...count).map { "\"Name\($0)\"" }.joined(separator: ", "))]
        """
    }

    // MARK: - Reading the file

    /// No file at all is the one case that yields the defaults.
    @Test func noFileIsTheDefaults() throws {
        let missing = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)/config.toml")
        #expect(try Config.load(missing, prompting: .countingWords()) == Config.default)
    }

    @Test func aFileOnDiskIsWhatTheAppRunsOn() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try Self.full.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Config.load(url, prompting: .countingWords()) == Self.config(Self.full))
    }

    /// [LAW:no-silent-failure] A path that exists but hands back no config text is an
    /// error, never the defaults: running on settings its owner never chose is the one
    /// outcome a config loader must not have.
    @Test func somethingThatIsNotAReadableFileIsNotTheDefaults() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ConfigError.self) { try Config.load(directory, prompting: .countingWords()) }
    }

    /// A file saved in some other encoding is a file whose owner needs to be told which
    /// file, in the words the system used - not handed a Foundation error they have no
    /// use for, and not quietly given somebody else's settings.
    @Test func aFileThatCannotBeReadIsNamedRatherThanReplaced() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "low-talker-\(UUID().uuidString).toml")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = #expect(throws: ConfigError.self) { try Config.load(url, prompting: .countingWords()) }
        guard case .unreadable(let path, _)? = error else {
            Issue.record("expected .unreadable, got \(String(describing: error))")
            return
        }
        #expect(path == url.path)
    }
}
