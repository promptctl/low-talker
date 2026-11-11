@testable import InputMethod
import Testing

/// What the input method's log says about a controller and its client, which is what a
/// measurement of two windows of one app is read from (low-reliability-z2z.vh4): which
/// controller, what happened to it, and which client it held.
///
/// [LAW:behavior-not-structure] The wording is the contract, because a person reads it off
/// `log show`: a record's whole line is held in
/// `ControllerRecordRenderingTests`, and the parts it is made of here.
@Suite struct ControllerLineTests {
    @Test func aClientIsNamedByItsIdentifierAndItsApp() {
        #expect(ClientName(identifier: "7E1", application: "com.apple.TextEdit").description == "client 7E1 of com.apple.TextEdit")
    }

    /// Two windows of one app are two names, the whole reason the identifier is said.
    @Test func twoWindowsOfOneAppAreTwoNames() {
        let one = ClientName(identifier: "7E1", application: "com.apple.TextEdit")
        let other = ClientName(identifier: "9B4", application: "com.apple.TextEdit")

        #expect(one.description != other.description)
    }

    @Test func aClientThatGaveNoIdentifierSaysSo() {
        #expect(ClientName(identifier: nil, application: "com.apple.TextEdit").description == "client with no identifier of com.apple.TextEdit")
    }

    @Test func aLineNamesTheControllerTheEventAndTheClientItHolds() {
        let line = controllerLine(controller: 0x6000_0123_abcd, "activated", client: "client 7E1 of com.apple.TextEdit")

        #expect(line == "controller 0x60000123abcd activated, client 7E1 of com.apple.TextEdit")
    }

    /// Two controllers of one client are two lines that differ, which is the whole reason the
    /// controller is on every line.
    @Test func twoControllersAreTwoDifferentLines() {
        let one = controllerLine(controller: 0x1000, "deactivated", client: "client A of com.apple.TextEdit")
        let other = controllerLine(controller: 0x2000, "deactivated", client: "client A of com.apple.TextEdit")

        #expect(one != other)
    }
}
