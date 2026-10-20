import Foundation
import LowTalkerCore
import Testing

/// Where the server listens, as a config's `[serve]` table says it (low-serve-axq.4zr): on
/// loopback anyone is answered, and off it only a caller with the token.
@Suite struct ServeBindingTests {
    static func binding(_ toml: String) throws(ConfigError) -> ServeBinding {
        try Config(toml: toml, prompting: .countingWords()).serve
    }

    @Test func noTableIsLoopback() throws {
        #expect(try Self.binding("") == .loopback)
    }

    /// As `[microphone]` is: a heading written on purpose is not read as the default.
    @Test func anEmptyTableIsRefused() {
        #expect(throws: ConfigError.serve(.emptyTable)) { try Self.binding("[serve]") }
    }

    @Test(arguments: ["192.168.1.20", "100.64.0.7", "fd7a:115c:a1e0::1"])
    func anInterfaceWithItsTokenBinds(address: String) throws {
        let binding = try Self.binding("""
            [serve]
            interface = "\(address)"
            token = "sk-local-token"
            """)
        #expect(binding == .interface(try InterfaceAddress(address), token: try BearerToken("sk-local-token")))
    }

    /// Refused at load, naming the setting: the state the ticket makes unrepresentable.
    @Test func anInterfaceWithoutATokenIsRefusedNamingTheToken() {
        #expect(throws: ConfigError.serve(.interfaceWithoutToken("192.168.1.20"))) {
            try Self.binding("""
                [serve]
                interface = "192.168.1.20"
                """)
        }
        #expect("\(ConfigError.serve(.interfaceWithoutToken("192.168.1.20")))".contains("serve.token is required"))
    }

    /// A token on loopback would guard nothing, since loopback answers every caller, so a
    /// file that sets one is told rather than trusted.
    @Test func aTokenWithoutAnInterfaceIsRefused() {
        #expect(throws: ConfigError.serve(.tokenWithoutInterface)) {
            try Self.binding("""
                [serve]
                token = "sk-local-token"
                """)
        }
    }

    /// Loopback, every interface at once, and loopback written as IPv6: each would put
    /// local callers, who send placeholder keys, behind the token.
    @Test(arguments: ["127.0.0.1", "127.8.0.1", "::1", "0.0.0.0", "::", "::ffff:127.0.0.1", "::ffff:0.0.0.0"])
    func anAddressTakingInLoopbackIsRefused(address: String) {
        #expect(throws: ConfigError.serve(.takesInLoopback(address))) {
            try Self.binding("""
                [serve]
                interface = "\(address)"
                token = "sk-local-token"
                """)
        }
    }

    /// Checked before the missing token, so a typo is named as the typo.
    @Test(arguments: ["en0", "localhost", "192.168.1", ""])
    func aNameIsNotAnAddress(address: String) {
        #expect(throws: ConfigError.serve(.notAnAddress(address))) {
            try Self.binding("""
                [serve]
                interface = "\(address)"
                """)
        }
    }

    @Test(arguments: ["", "has space", "sk-é", "a=b"])
    func aTokenNoHeaderCanCarryIsRefused(token: String) {
        #expect(throws: ConfigError.serve(.tokenUnsendable)) {
            try Self.binding("""
                [serve]
                interface = "192.168.1.20"
                token = "\(token)"
                """)
        }
    }

    @Test func loopbackAdmitsEveryCaller() {
        for authorization in [nil, "", "Bearer anything", "Basic xyz"] {
            #expect(ServeBinding.loopback.admits(authorization: authorization))
        }
    }

    @Test func anInterfaceAdmitsOnlyItsToken() throws {
        let binding = ServeBinding.interface(try InterfaceAddress("192.168.1.20"), token: try BearerToken("sk-local-token"))
        #expect(binding.admits(authorization: "Bearer sk-local-token"))
        #expect(binding.admits(authorization: "bearer sk-local-token"))
        for refused in [nil, "", "Bearer", "Bearer ", "Bearer sk-local-toke", "Bearer sk-local-tokenn", "Bearer sk-local-tokeN", "Basic sk-local-token", "sk-local-token"] {
            #expect(!binding.admits(authorization: refused), "\(refused ?? "nil")")
        }
    }

    @Test func aTokenNeverPrints() throws {
        let binding = ServeBinding.interface(try InterfaceAddress("192.168.1.20"), token: try BearerToken("sk-local-token"))
        #expect(!"\(binding)".contains("sk-local-token"))
        #expect(!String(reflecting: binding).contains("sk-local-token"))
    }
}
