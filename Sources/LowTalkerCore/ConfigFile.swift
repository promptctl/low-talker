import Identity
import Foundation
import TOMLKit

public extension Config {
    /// The one file, at the one path: inside the app's container, which App Sandbox makes
    /// the app's home and the only place it reads.
    ///
    /// [LAW:one-source-of-truth] Spelled from the account's own home rather than from
    /// `homeDirectoryForCurrentUser`, which answers the container inside the sandbox and the
    /// real home outside it, so the path is the app's file whichever process asks.
    static var fileURL: URL {
        URL(filePath: String(cString: getpwuid(getuid()).pointee.pw_dir), directoryHint: .isDirectory)
            .appending(path: "Library/Containers/\(AppIdentity.bundleIdentifier)/Data/\(pathInContainer)")
    }

    /// Where the file sits inside the container. project.yml writes it again, as the place
    /// the bundle's container migration moves a pre-sandbox file to; `ContainerMigrationTests`
    /// holds the two equal. [LAW:one-source-of-truth]
    static let pathInContainer = ".config/low-talker/config.toml"

    /// [LAW:parse-dont-validate] The one place config text becomes a Config. What comes
    /// back holds together or this throws naming what does not, so nothing downstream
    /// examines the file again: there is no text left to examine.
    ///
    /// [LAW:effects-at-boundaries] Pure. It opens nothing and reads no clock, so a test
    /// hands it a string rather than a filesystem.
    init(toml: String) throws(ConfigError) {
        var decoder = TOMLDecoder()
        // A key this schema has no place for is a typo the author wants told, not a
        // line quietly doing nothing. [LAW:no-silent-failure]
        decoder.strictDecoding = true
        let file: ConfigFile
        do {
            file = try decoder.decode(ConfigFile.self, from: toml)
        } catch let error as TOMLParseError {
            throw ConfigError.notTOML(error.description, line: error.source.begin.line)
        } catch let error as UnexpectedKeysError {
            // Placed and sorted here rather than where they are printed, so two runs over
            // one bad file name the same keys the same way. [LAW:one-source-of-truth]
            throw ConfigError.unknownKeys(error.keys.values.map(path).sorted())
        } catch let error as DecodingError {
            throw ConfigError.wrongShape(error.sentence)
        } catch {
            throw ConfigError.notUnderstood("\(error)")
        }
        // [LAW:one-source-of-truth] A key the file leaves out falls back to the value in
        // Config.default, which is where the no-file behaviour is written; no default is
        // spelled a second time here to drift from it.
        try self.init(
            model: file.model ?? Config.default.model,
            microphone: file.microphone?.atRest ?? Config.default.microphone,
            modes: file.modes?.map { $0.mode } ?? Array(Config.default.modes),
            serve: try file.serve.map { entry throws(ConfigError) in try entry.binding } ?? Config.default.serve
        )
    }

    /// The config the app runs on: what the file says, or the defaults when there is no
    /// file. Absent a path, the app's own file.
    ///
    /// [LAW:no-silent-failure] Only a file that is not there yields the defaults. One
    /// that exists and cannot be read, or cannot be understood, throws - so a config the
    /// user wrote is never quietly replaced by one they did not.
    static func load(_ url: URL = fileURL) throws(ConfigError) -> Config {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .default
        } catch {
            throw ConfigError.unreadable(path: url.path, why: error.localizedDescription)
        }
        return try Config(toml: text)
    }
}

/// The file's shape, which is not the app's. It exists so the spelling in the file can
/// be the one a person would write, while `Config` stays the shape the app runs on;
/// mapping between them is what parsing this file means.
private struct ConfigFile: Decodable {
    let model: ModelName?
    let microphone: MicrophoneEntry?
    let modes: [ModeEntry]?
    let serve: ServeEntry?
}

/// `[serve] interface = "192.168.1.20"`, `token = "..."`: both, or no table at all.
private struct ServeEntry: Decodable {
    let interface: String?
    let token: String?

    /// [LAW:parse-dont-validate] The pair becomes a `ServeBinding` here, so an interface
    /// without its token is refused while the file is read and exists nowhere after it.
    var binding: ServeBinding {
        get throws(ConfigError) {
            do throws(ServeBindingError) {
                switch (interface, token) {
                case (nil, nil): throw .emptyTable
                case (nil, _?): throw .tokenWithoutInterface
                case (let interface?, nil): _ = try InterfaceAddress(interface); throw .interfaceWithoutToken(interface)
                case (let interface?, let token?): return .interface(try InterfaceAddress(interface), token: try BearerToken(token))
                }
            } catch {
                throw .serve(error)
            }
        }
    }
}

/// `[microphone] at_rest = "shut"`. A table rather than a bare key, so the one setting
/// that decides when the device is open is read under a heading named for the device.
private struct MicrophoneEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case atRest = "at_rest" }

    let atRest: MicrophoneAtRest

    /// Hand-written for the sentence a synthesised decoder would not write: its refusal
    /// names a Swift type the file's author has never heard of, where this one names the
    /// word they wrote. [LAW:no-silent-failure]
    ///
    /// [LAW:single-enforcer] Which words name a resting state is `MicrophoneAtRest`'s to
    /// say, through its own raw value, so a case added there is spellable in the file
    /// without this one being taught about it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .atRest)
        guard let atRest = MicrophoneAtRest(rawValue: name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .atRest,
                in: container,
                debugDescription: "\"\(name)\" is not something the microphone does at rest"
            )
        }
        self.atRest = atRest
    }
}

/// One `[[modes]]` table.
private struct ModeEntry: Decodable {
    let name: String
    let chord: KeyChord?
    let vocabulary: [Vocabulary.Term]?

    /// [LAW:single-enforcer] The chord and each term arrived through their own decoders, so
    /// what each may be is settled where those types live and is not restated here.
    ///
    /// [LAW:one-source-of-truth] A mode the file gives no chord listens for the default
    /// one, which is the chord `Config.default` names.
    var mode: Mode {
        Mode(name: name, chord: chord ?? Hotkey.defaultChord, vocabulary: Vocabulary(vocabulary ?? []))
    }
}

private extension DecodingError {
    /// The same fault in the words the file's author needs: which key, and what is wrong
    /// with it. The type names Swift puts in these errors describe the parser's own
    /// types, which mean nothing to someone editing TOML.
    var sentence: String {
        switch self {
        // TOMLKit's context already ends with the key it could not find; naming it
        // again here would spell it twice.
        case .keyNotFound(_, let context):
            "\(path(context.codingPath)) is missing"
        case .typeMismatch(_, let context):
            "\(path(context.codingPath)) is not the kind of value that key takes"
        case .valueNotFound(_, let context):
            "\(path(context.codingPath)) has no value"
        // The one case a hand-written decoder puts its own reason in, such as KeyChord
        // refusing a chord with nothing in it. That sentence is better than any this
        // file could invent, so it is carried through rather than replaced.
        case .dataCorrupted(let context):
            "\(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            "the config could not be read"
        }
    }

}

/// `modes[0].chord`, the way the file's author wrote it: `[[modes]]` is positional, so
/// an index is a coordinate they can count to, where Swift's own "Index 0" names a
/// CodingKey they have never heard of.
private func path(_ keys: [any CodingKey]) -> String {
    let path = keys.reduce(into: "") { path, key in
        if let index = key.intValue { path += "[\(index)]" }
        else if path.isEmpty { path += key.stringValue }
        else { path += ".\(key.stringValue)" }
    }
    return path.isEmpty ? "the config" : path
}
