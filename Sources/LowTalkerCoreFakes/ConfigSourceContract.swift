import LowTalkerCore

/// A config source's semantics, stated once. Each statement runs one fresh source and says every
/// way it disagreed; nothing, when it agreed. `FakeConfigFile` runs it, and so does
/// `ConfigFileSource` on a file of its own. [LAW:one-source-of-truth]
public struct ConfigSourceContract: Sendable {
    public enum Statement: CaseIterable, Sendable, CustomStringConvertible {
        /// No file reads as the defaults, which is a fresh install and not a failure.
        case noFileReadsAsTheDefaults
        /// A save after the reloads began is the next change, adopted.
        case aSaveIsAdopted
        /// A save that cannot be read keeps the config running, and says why.
        case aRefusedSaveKeepsWhatRuns
        /// A save that reads as the last one did says nothing.
        case aSaveThatChangesNothingSaysNothing

        public var description: String {
            switch self {
            case .noFileReadsAsTheDefaults: "no file reads as the defaults"
            case .aSaveIsAdopted: "a save is adopted"
            case .aRefusedSaveKeepsWhatRuns: "a refused save keeps what runs"
            case .aSaveThatChangesNothingSaysNothing: "a save that changes nothing says nothing"
            }
        }
    }

    /// A fresh source with no file, and the way to save one: the text, or nil for no file.
    public typealias Subject = (source: any ConfigSource, save: @Sendable (String?) throws -> Void)

    public let subject: @Sendable () throws -> Subject

    public init(subject: @escaping @Sendable () throws -> Subject) {
        self.subject = subject
    }

    /// One mode, heard on `chord`.
    public static func file(chord: String) -> String {
        """
        [[modes]]
        name = "dictation"
        chord = { modifiers = ["\(chord)"] }
        """
    }

    public static let onRightCommand = file(chord: "rightCommand")
    public static let onLeftControl = file(chord: "leftControl")
    /// TOML that stops being TOML part way through a table header.
    public static let notTOML = "model = \"base.en\"\n[[modes\n"
    /// An encoder that counts words, so every mode here is told.
    public static let prompting = PromptEncoder(limit: 1000) { text in text.split(separator: " ").map { _ in 0 } }

    public func disagreements(with statement: Statement) async throws -> [String] {
        let (source, save) = try subject()
        let launch = RunningConfig(reading: source.read(prompting: Self.prompting))
        if statement == .noFileReadsAsTheDefaults {
            return launch == .adopted(.default) ? [] : ["with no file, read \(launch)"]
        }
        var reloads = source.reloads(after: launch, prompting: Self.prompting).makeAsyncIterator()
        // Settled on a file of its own first, so what follows is heard as a save and not as the
        // reading the reloads take as they come up.
        try save(Self.onRightCommand)
        let running = try Config(toml: Self.onRightCommand, prompting: Self.prompting)
        guard let settled = await reloads.next(), settled == .adopted(running) else {
            return ["the first save was not adopted"]
        }
        switch statement {
        case .noFileReadsAsTheDefaults:
            preconditionFailure("answered above")
        case .aSaveIsAdopted:
            try save(Self.onLeftControl)
            let next = await reloads.next()
            let saved = try Config(toml: Self.onLeftControl, prompting: Self.prompting)
            return next == .adopted(saved) ? [] : ["a save reloaded as \(next.map(String.init(describing:)) ?? "nothing")"]
        case .aRefusedSaveKeepsWhatRuns:
            try save(Self.notTOML)
            let next = await reloads.next()
            guard case .kept(let kept, _)? = next, kept == running else {
                return ["a refused save reloaded as \(next.map(String.init(describing:)) ?? "nothing")"]
            }
            return []
        case .aSaveThatChangesNothingSaysNothing:
            try save(Self.onRightCommand)
            try save(Self.onLeftControl)
            let next = await reloads.next()
            let saved = try Config(toml: Self.onLeftControl, prompting: Self.prompting)
            return next == .adopted(saved) ? [] : ["after a save that changed nothing, the next reload was \(next.map(String.init(describing:)) ?? "nothing")"]
        }
    }
}
