import Identity
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The app runs under App Sandbox with the microphone, folders a person picks for the bench,
/// and two Mach names, and nothing else.
///
/// Read off the plist xcodegen renders, so a port named wrongly in project.yml fails here
/// rather than as a sandbox denial at the first hotkey press.
/// Compared whole: an entitlement added without a measured failure behind it is a finding.
/// Whether what is signed can reach the network is `scripts/variant`'s, which reads the
/// signature every route to an entitlement ends in.
@Suite struct AppEntitlementsTests {
    @Test func theAppIsSandboxedWithOnlyTheMicrophonePickedFoldersAndItsTwoPorts() throws {
        let url = repository.appending(path: "App/Generated/\(AppIdentity.displayName).entitlements")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.lastPathComponent) has not been generated; run `make test`, which runs xcodegen - `swift test` alone does not")
        let entitlements = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? NSDictionary)
        #expect(entitlements == [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.device.audio-input": true,
            "com.apple.security.files.user-selected.read-only": true,
            "com.apple.security.temporary-exception.mach-register.global-name": [AppIdentity.hotkeyPortName],
            "com.apple.security.temporary-exception.mach-lookup.global-name": [AppIdentity.inputMethodPortName],
        ] as NSDictionary)
    }
}
