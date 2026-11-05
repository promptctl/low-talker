import AppKit
@testable import InputMethod
import TestProbes
import Testing

/// A controller says its own life in the `imk` log, which is what a measurement of orphaned
/// controllers and of two windows of one app is read from (low-reliability-z2z.vh4). Asked by
/// driving the controller as IMK does and reading what the process logged, because the wording
/// is built by `ControllerLineTests` and nothing else notices a callback that stopped saying it.
///
/// On the main actor like every suite that builds an `IMKInputController`. Each controller is
/// told apart by its own address, so cases that run at once read their own lines.
@Suite @MainActor struct ControllerLogTests {
    private static func address(of controller: DictationInputController) -> String {
        "controller 0x\(String(UInt(bitPattern: ObjectIdentifier(controller)), radix: 16))"
    }

    private static func lines(since: Date, of controller: String) async throws -> [String] {
        try await loggedLines(category: "imk", since: since).filter { $0.hasPrefix(controller) }
    }

    @Test(.timeLimit(.minutes(1))) func aControllerSaysItWasMadeThroughEitherInit() async throws {
        let since = Date.now
        let served = try #require(DictationInputController(server: nil, delegate: nil, client: nil))
        let bare = DictationInputController()

        let servedSaid = try await Self.lines(since: since, of: Self.address(of: served))
        let bareSaid = try await Self.lines(since: since, of: Self.address(of: bare))
        #expect(servedSaid.contains { $0.hasSuffix(" was made") })
        #expect(bareSaid.contains { $0.hasSuffix(" was made") })
    }

    /// A sender that is no text client makes no cursor, and the line says the controller holds none.
    @Test(.timeLimit(.minutes(1))) func anActivationAndADeactivationWithNoClientSaySo() async throws {
        let since = Date.now
        let controller = try #require(DictationInputController(server: nil, delegate: nil, client: nil))

        controller.activateServer(nil)
        controller.deactivateServer(nil)

        let said = try await Self.lines(since: since, of: Self.address(of: controller))
        #expect(said.contains("\(Self.address(of: controller)) activated without a usable client, holding no client"))
        #expect(said.contains("\(Self.address(of: controller)) deactivated, holding no client"))
    }

    @Test(.timeLimit(.minutes(1))) func aControllerSaysItEnded() async throws {
        let since = Date.now
        var named = ""
        autoreleasepool {
            let controller = DictationInputController()
            named = Self.address(of: controller)
        }

        let said = try await Self.lines(since: since, of: named)
        #expect(said.contains("\(named) ended"))
    }
}
