import AVFoundation
import Grants
import GrantsFakes
import Synchronization
import Testing

@Suite struct MicrophonePermissionTests {
    @Test(arguments: [
        (AVAuthorizationStatus.notDetermined, MicrophoneAuthorization.Withheld.notDetermined),
        (.denied, .denied),
        (.restricted, .restricted),
    ])
    func everyWayOfSayingNoIsWithheldWithItsReason(status: AVAuthorizationStatus, reason: MicrophoneAuthorization.Withheld) {
        let permission = MicrophonePermission(authority: FakeMicrophoneAuthority(status: status))
        #expect(permission.current == .withheld(reason))
        #expect(throws: reason) { try permission.current.grant() }
    }

    @Test func authorizedIsAGrant() throws {
        let permission = MicrophonePermission(authority: FakeMicrophoneAuthority(status: .authorized))
        guard case .granted(let grant) = permission.current else {
            Issue.record("authorized did not parse as granted")
            return
        }
        #expect(try permission.current.grant() == grant)
    }

    /// The request reports the user's decision, not the Bool: denied and restricted
    /// both answer false at the prompt and are told apart afterwards.
    @Test(arguments: [AVAuthorizationStatus.authorized, .denied, .restricted])
    func requestReportsTheDecision(decision: AVAuthorizationStatus) async {
        let authority = FakeMicrophoneAuthority(status: .notDetermined, decision: decision)
        let answer = await MicrophonePermission(authority: authority).request()
        #expect(answer == MicrophonePermission(authority: FakeMicrophoneAuthority(status: decision)).current)
    }

    /// The stream opens with where things stand and then yields each change, so a
    /// switch flipped in System Settings reaches the app without a relaunch.
    @Test func changesYieldTheCurrentValueThenEachChange() async throws {
        let authority = FakeMicrophoneAuthority(status: .notDetermined)
        var changes = MicrophonePermission(authority: authority).changes(every: .milliseconds(1)).makeAsyncIterator()

        #expect(await changes.next() == .withheld(.notDetermined))
        authority.set(.denied)
        #expect(await changes.next() == .withheld(.denied))
        authority.set(.authorized)
        #expect(await changes.next() == .granted(try MicrophonePermission(authority: authority).current.grant()))
        // Reads that see no change yield nothing: the next value out is the next change.
        authority.set(.restricted)
        #expect(await changes.next() == .withheld(.restricted))
    }
}

/// The authority's contract against its one fake, which every suite that stands in TCC uses.
@Suite struct MicrophoneAuthorityContractTests {
    static let fake = MicrophoneAuthorityContract { FakeMicrophoneAuthority(status: $0, decision: $1) }

    @Test(arguments: MicrophoneAuthorityContract.Statement.allCases)
    func theFakeKeepsTheStatement(_ statement: MicrophoneAuthorityContract.Statement) async {
        #expect(await Self.fake.disagreements(with: statement) == [])
    }
}
