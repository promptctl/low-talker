import Carbon
import Identity
import Foundation
import TextInputSources

/// Where the input method stands once the app has done what it can: switched on and
/// selected, or registered and waiting for a person to switch it on.
public enum InputMethodReadiness: Equatable, Sendable, CustomStringConvertible {
    /// Registered, and switched off: it is not in the Input menu and cannot be selected.
    case switchedOff
    /// The source in use, which is the only state an insert can happen from.
    ///
    /// Kept selected for as long as the delivery is the input method, rather than selected
    /// for each press and put back after it. Measured on 2026-09-22: a source selected from
    /// this background app becomes current at once, but the app in front goes on talking to
    /// the input method it had until its own focus changes - so a press-length selection is
    /// an input method with no client for the length of the press, and every insert refused.
    /// Selected once, the source is what every app picks up as it takes focus. The input
    /// method's controller passes every key through, so typing is unchanged by it.
    case selected

    /// Whether the input method can be asked to insert.
    public var ready: Bool { self == .selected }

    public var description: String {
        switch self {
        case .switchedOff: "registered, switched off"
        case .selected: "selected"
        }
    }
}

/// The input method as the installer package left it in `/Library/Input Methods`:
/// registered with the text input system, switched on when a person allows it, and selected.
///
/// [LAW:one-source-of-truth] The package is the one writer of the input method's files; the
/// app reads the bundle the package installed and never copies, links, replaces or stops one.
/// A sandboxed app could not do otherwise: every file it writes carries a quarantine it cannot
/// remove, and the text input system refuses an input method written that way.
///
/// [LAW:decomposition] The Text Input Sources framework as this program uses it, and nothing
/// about dictation: what it answers is where the input source stands.
public struct InstalledInputMethod: Sendable {
    /// The folder the package installs into, which is `/Library/Input Methods` unless a test
    /// says otherwise.
    public let directory: URL

    public init(directory: URL = Self.systemDirectory) {
        self.directory = directory
    }

    /// Where the installer package puts the input method: the one standard folder the text
    /// input system lists input methods from that a package, and not the app, writes to.
    /// scripts/make-pkg spells the same path as its install location.
    public static let systemDirectory = URL(fileURLWithPath: "/Library/Input Methods")

    /// The installed input method bundle, found by the identifier it must have and not by
    /// its file name.
    ///
    /// [LAW:one-source-of-truth] The identifier is the fact both halves already agree on -
    /// `AppIdentity.inputMethodBundleIdentifier` names it and project.yml writes it into the
    /// bundle - while the file name is a display name that a rename would silently change.
    public func bundle() throws -> URL {
        let wanted = AppIdentity.inputMethodBundleIdentifier
        // A folder that is not there holds no input method; one that cannot be read says why.
        // [LAW:no-silent-failure]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            contents = []
        }
        for candidate in contents where candidate.pathExtension == "app" {
            if Bundle(url: candidate)?.bundleIdentifier == wanted { return candidate }
        }
        throw InputMethodFailure.notInstalled(identifier: wanted, looked: directory)
    }

    /// Registers the input method and selects it, stopping at `switchedOff` when a person
    /// has not switched it on.
    ///
    /// [LAW:no-silent-failure] Every step that can refuse says which step it was by name,
    /// and the register step is checked against the source list rather than against its own
    /// status: `TISRegisterInputSource` answers `noErr` for bundles it does not take, which
    /// `AppIdentity.inputMethodBundleIdentifier` records being measured. A status believed here
    /// would leave an input method that reads as registered and never answers.
    ///
    /// Async and on the main actor because the answer arrives there. Measured on 2026-09-22:
    /// a process's source list is its own copy, refreshed by a notification its main run loop
    /// delivers, so a register followed by a lookup in the same turn reads the list from
    /// before the register and finds nothing - while a fresh process, asked at that moment,
    /// finds the source. The lookup is therefore awaited, with the main run loop free to take
    /// the refresh, for up to `settling`; a source still absent after that is the silent
    /// refusal and is said as one.
    @MainActor
    @discardableResult
    public func select(settling: Duration = .seconds(3)) async throws -> InputMethodReadiness {
        let source = try await registered(settling: settling)
        // Never switched on here. Switching an input method on is what makes macOS ask the
        // person, in its own dialog, whether this app may, and `select` runs at every
        // launch: a launch must put no system dialog on screen. `switchOn` is the one call
        // that does, and it is made only from the step a person starts. Not a failure: it
        // stops where a person has yet to allow it, and says so.
        guard Self.isSwitchedOn() else { return .switchedOff }
        if !Self.isSelected(source) {
            let selected = TextInputSources.withLock { TISSelectInputSource(source) }
            guard selected == noErr else {
                throw InputMethodFailure.selectRefused(identifier: AppIdentity.inputSourceIdentifier, status: selected)
            }
        }
        // Read back rather than believed, for the reason the lookup above is: the select is
        // answered `noErr` before this process's list says so, and it can be answered
        // `noErr` and not take, as it does while an app holds Secure Event Input.
        guard try await Self.source(named: AppIdentity.inputSourceIdentifier, within: settling, where: Self.isSelected) != nil else {
            throw InputMethodFailure.notSelectedAfterSelecting(identifier: AppIdentity.inputSourceIdentifier)
        }
        return .selected
    }

    /// Switches the input method on, which makes macOS ask the person whether this
    /// app may - the one call in this type that can put a dialog on screen, so it is made only
    /// when a person has asked for it. Registers first, since a source the text input system
    /// does not list cannot be switched on; `select` selects it afterwards.
    ///
    /// Nothing is read back here: macOS may still be showing its dialog when this returns,
    /// so whoever asked reads `isSwitchedOn` when the person is done with it.
    @MainActor
    public func switchOn(settling: Duration = .seconds(3)) async throws {
        let mode = try await registered(settling: settling)
        // The input method's own source, looked for the way the mode's was: this process's
        // list may not hold it yet, and a list read before the refresh arrives is not an
        // answer. [LAW:no-ambient-temporal-coupling]
        guard let inputMethod = try await Self.source(named: AppIdentity.inputMethodBundleIdentifier, within: settling) else {
            throw InputMethodFailure.notInSourceListAfterRegistering(
                identifier: AppIdentity.inputMethodBundleIdentifier, bundle: try bundle())
        }
        // The input method first, which is what macOS asks the person about, then its one
        // mode, which a person who removed it under Input Sources switched off: both must
        // be on before the mode can be selected. [LAW:dataflow-not-control-flow] Each is
        // switched on only where it reads off, so a source already on is left alone.
        for (source, identifier) in [(inputMethod, AppIdentity.inputMethodBundleIdentifier), (mode, AppIdentity.inputSourceIdentifier)]
        where !Self.isEnabled(source) {
            let enabled = TextInputSources.withLock { TISEnableInputSource(source) }
            guard enabled == noErr else {
                throw InputMethodFailure.enableRefused(identifier: identifier, status: enabled)
            }
        }
    }

    /// The installed bundle registered, and the source the text input system lists for it:
    /// the step below switching on, which neither `select` nor `switchOn` may skip and
    /// neither asks anyone about.
    @MainActor
    private func registered(settling: Duration) async throws -> TISInputSource {
        let installed = try bundle()
        // Registered unconditionally: registering a source already known is how the text
        // input system is told which bundle stands behind it, which is what a package that
        // moved the bundle, or replaced it with a new version, needs, and costs nothing on
        // one that did not.
        let status = TextInputSources.withLock { TISRegisterInputSource(installed as CFURL) }
        guard status == noErr else {
            throw InputMethodFailure.registrationRefused(bundle: installed, status: status)
        }
        guard let source = try await Self.source(named: AppIdentity.inputSourceIdentifier, within: settling) else {
            throw InputMethodFailure.notInSourceListAfterRegistering(identifier: AppIdentity.inputSourceIdentifier, bundle: installed)
        }
        return source
    }

    /// Whether the input method is switched on, read from the text input system
    /// alone. What the switch-on step asks of a person, and nothing about the bundle on disk,
    /// so it reads the same whatever process asks.
    ///
    /// Read off the input method's own source, whose identifier is its bundle's, and not off
    /// its mode's. Measured on 2026-09-24: registered and never switched on, the input
    /// method's source reads `enabled=no` while its one mode reads `enabled=yes`, because a
    /// mode declared on by default is on inside an input method that is off. Selecting that
    /// mode is refused with -50. So the mode's flag alone answers nothing about whether a
    /// person allowed the input method. Both are read: the input method's own flag is the
    /// grant, and a mode switched off - as removing the input method under Input Sources
    /// leaves it - is one that cannot be selected either, and is switched on the same way.
    public static func isSwitchedOn() -> Bool {
        [AppIdentity.inputMethodBundleIdentifier, AppIdentity.inputSourceIdentifier]
            .allSatisfy { source(named: $0).map(isEnabled) ?? false }
    }

    /// Whether the input source is the one in use now: the only state in which the input
    /// method is handed a client to type into.
    public static func isSelected() -> Bool {
        source(named: AppIdentity.inputSourceIdentifier).map(isSelected) ?? false
    }

    /// The one source with this identifier, including sources that are switched off.
    ///
    /// `includeAllInstalled` is what makes a disabled source visible at all: the default
    /// list holds only what is enabled, so without it a registered-but-off input method
    /// would read as absent, and `switchOn` would refuse with
    /// `notInSourceListAfterRegistering` instead of switching it on.
    static func source(named identifier: String) -> TISInputSource? {
        let query = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        // [LAW:single-enforcer] Through the lock every Text Input Sources call takes.
        let sources = TextInputSources.withLock {
            TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource]
        }
        return sources?.first
    }

    /// The source, looked for until it appears reading as `holds` says, or `deadline` passes.
    ///
    /// Each miss suspends rather than blocks, which is the point: suspended, the main actor's
    /// run loop is free to deliver the refresh that makes the next look succeed. A blocking
    /// wait here would hold off the very notification it was waiting for.
    /// [LAW:no-ambient-temporal-coupling]
    @MainActor
    static func source(
        named identifier: String, within deadline: Duration, where holds: (TISInputSource) -> Bool = { _ in true }
    ) async throws -> TISInputSource? {
        let clock = ContinuousClock()
        let giveUp = clock.now + deadline
        while true {
            if let found = source(named: identifier), holds(found) { return found }
            if clock.now >= giveUp { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func isEnabled(_ source: TISInputSource) -> Bool { flag(kTISPropertyInputSourceIsEnabled, of: source) }

    static func isSelected(_ source: TISInputSource) -> Bool { flag(kTISPropertyInputSourceIsSelected, of: source) }

    private static func flag(_ property: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TextInputSources.withLock({ TISGetInputSourceProperty(source, property) }) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}

/// A step that refused, named as the step it was.
///
/// [LAW:no-silent-failure] One case per step rather than one message, because what a person
/// does about each is different: an input method that is not installed is a package to run
/// again, and a bundle the text input system would not take is the identifier rule in
/// `AppIdentity.inputMethodBundleIdentifier` being broken by a rename.
public enum InputMethodFailure: Error, Equatable, CustomStringConvertible {
    case notInstalled(identifier: String, looked: URL)
    case registrationRefused(bundle: URL, status: OSStatus)
    /// The register step answered `noErr` and the source is still not in the list, which is
    /// what a bundle macOS silently declines looks like from here.
    case notInSourceListAfterRegistering(identifier: String, bundle: URL)
    case enableRefused(identifier: String, status: OSStatus)
    case selectRefused(identifier: String, status: OSStatus)
    case notSelectedAfterSelecting(identifier: String)

    public var description: String {
        switch self {
        case let .notInstalled(identifier, looked):
            "no input method with identifier \(identifier) is installed in \(looked.path); install LowTalker from its package, which puts it there"
        case let .registrationRefused(bundle, status):
            "the text input system refused to register \(bundle.path): OSStatus \(status)"
        case let .notInSourceListAfterRegistering(identifier, bundle):
            "the text input system took \(bundle.path) without complaint and still lists no source \(identifier); "
                + "the bundle identifier is one macOS declines silently"
        case let .enableRefused(identifier, status):
            "the text input system refused to switch on \(identifier): OSStatus \(status)"
        case let .selectRefused(identifier, status):
            "the text input system refused to select \(identifier): OSStatus \(status)"
        case let .notSelectedAfterSelecting(identifier):
            "\(identifier) was selected and is not the current input source; an app holding secure keyboard entry keeps input methods off"
        }
    }
}
