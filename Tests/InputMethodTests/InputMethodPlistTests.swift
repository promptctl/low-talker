import AppKit
import Identity
import Foundation
import InputMethod
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The bundle the input method is built as carries every name macOS files it under, and
/// each is `AppIdentity`'s.
///
/// Read off the plist xcodegen actually writes rather than off project.yml's text, because
/// what ships is what xcodegen makes of it. [LAW:behavior-not-structure]
///
/// Writing that plist is the build's job and not this suite's. [LAW:effects-at-boundaries]
/// A case that generated it would be a unit test deleting `App/Generated` and rewriting
/// `LowTalker.xcodeproj` in the working tree - underneath whatever build is already running
/// there, and leaving the directory deleted on a machine with no xcodegen on PATH. `make
/// test` runs xcodegen first, the way `make app` does, and the cases here only read.
@Suite struct InputMethodPlistTests {
    private static func plist() throws -> [String: Any] {
        let url = repository.appending(path: "App/Generated/\(AppIdentity.displayName)-InputMethod-Info.plist")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The names `AppIdentity` decides, in the three keys macOS reads them from.
    @Test func theBundleIsNamedByAppIdentity() throws {
        let plist = try Self.plist()
        // The identifier is absent here on purpose: this key holds the literal
        // `$(PRODUCT_BUNDLE_IDENTIFIER)`, and the value Xcode substitutes for it is read
        // where it resolves, by `InputMethodBuildSettingsTests`. [LAW:single-enforcer]
        #expect(plist["InputMethodConnectionName"] as? String == AppIdentity.inputMethodConnectionName)

        let modes = try #require(plist["ComponentInputModeDict"] as? [String: Any])
        let list = try #require(modes["tsInputModeListKey"] as? [String: Any])
        let mode = try #require(list[AppIdentity.inputSourceIdentifier] as? [String: Any],
                                "no mode under \(AppIdentity.inputSourceIdentifier); the plist declares \(Array(list.keys))")
        #expect(mode["TISInputSourceID"] as? String == AppIdentity.inputSourceIdentifier)
        // A mode nobody can see is a source that never appears in the Input menu, and
        // nothing says so. [LAW:no-silent-failure]
        #expect(mode["tsInputModeIsVisibleKey"] as? Bool == true)
        #expect(modes["tsVisibleInputModeOrderedArrayKey"] as? [String] == [AppIdentity.inputSourceIdentifier])
    }

    /// What macOS needs to launch the bundle as an input method at all: the class it asks
    /// the Objective-C runtime for, and a process that shows no UI of its own.
    @Test func theBundleIsLaunchableAsAnInputMethod() throws {
        let plist = try Self.plist()
        // One fact in two places - the string macOS resolves at launch, and the name the
        // class actually answers to. A rename on either side alone is a bundle that
        // launches and then cannot serve. [LAW:one-source-of-truth]
        #expect(plist["InputMethodServerControllerClass"] as? String == NSStringFromClass(DictationInputController.self))
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["TISIntendedLanguage"] as? String == "en")
    }

    /// The Input menu draws a glyph beside the name, and the plist names the file it draws.
    /// Held to a file that is actually in the tree, because a renamed asset leaves the key
    /// pointing at nothing and the menu simply draws no icon - nothing fails, nothing says
    /// so. [LAW:no-silent-failure]
    @Test func theBundleCarriesTheIconTheMenuDraws() throws {
        let plist = try Self.plist()
        let named = try #require(plist["tsInputMethodIconFileKey"] as? String)
        #expect(plist["TISIconIsTemplate"] as? Bool == true)
        let modes = try #require(plist["ComponentInputModeDict"] as? [String: Any])
        let list = try #require(modes["tsInputModeListKey"] as? [String: Any])
        let mode = try #require(list[AppIdentity.inputSourceIdentifier] as? [String: Any])
        #expect(mode["tsInputModeMenuIconFileKey"] as? String == named)
        #expect(FileManager.default.fileExists(atPath: repository.appending(path: "App/InputMethods/\(named)").path),
                "the plist names \(named), which App/InputMethods does not hold")
    }
}

/// The input method is sandboxed, and a sandboxed process registers and looks up only the
/// names its entitlements list - so each name it answers on is listed, and the one it tells
/// the app on, and nothing else is.
///
/// Read off the entitlements xcodegen writes, for the reason `InputMethodPlistTests` reads
/// the plist. A name missing here is an input method that
/// launches and never answers - the text input system's connection unopened, or the app's
/// inserts refused as no input method running. [LAW:no-silent-failure]
/// Compared whole, as `AppEntitlementsTests` compares the app's: an entitlement added without
/// a measured failure behind it is a finding (IMK rule 2).
@Suite struct InputMethodEntitlementsTests {
    @Test func theSandboxAdmitsExactlyTheNamesTheInputMethodRegistersAndLooksUp() throws {
        let url = repository.appending(path: "App/Generated/\(AppIdentity.displayName)-InputMethod.entitlements")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? NSDictionary)
        #expect(entitlements == [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.temporary-exception.mach-register.global-name":
                [AppIdentity.inputMethodConnectionName, AppIdentity.inputMethodPortName],
            "com.apple.security.temporary-exception.mach-lookup.global-name": [AppIdentity.hotkeyPortName],
        ] as NSDictionary)
    }
}
