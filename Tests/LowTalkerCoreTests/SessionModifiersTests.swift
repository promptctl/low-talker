import Foundation
@testable import LowTalkerCore
import Testing

/// The app's own reading of the session, which confirms what is still held.
@Suite struct SessionModifiersTests {
    /// The session sets the secondary-Fn bit while an arrow key is down, and an arrow key is
    /// not Fn; the Fn key down with nothing else is Fn. Every other bit is the session's.
    /// The log line says what was held whenever that is not the session's flags as given.
    @Test func theFnBitIsTheFnKeyItself() {
        let fn: UInt64 = 0x800000
        let anArrowWithRightOption = SessionModifiers(session: 0x80140 | fn, fnKeyDown: false, changedAt: 2.5)
        #expect(anArrowWithRightOption.flags == 0x80140)
        #expect(anArrowWithRightOption.description == "session 0x880140, Fn key up, held 0x80140, changed at 2.5")
        let fnAlone = SessionModifiers(session: 0x100 | fn, fnKeyDown: true, changedAt: 2.5)
        #expect(fnAlone.flags == 0x100 | fn)
        #expect(fnAlone.description == "session 0x800100, Fn key down, changed at 2.5")
        #expect(SessionModifiers(session: 0x80140, fnKeyDown: true, changedAt: 2.5).flags == 0x80140 | fn)
    }

    /// A reading is dated by the session's last change, unless that change came after the
    /// keys were read, or the session reports one from before the machine came up.
    @Test func aReadingIsDatedNoLaterThanTheRead() {
        #expect(SessionModifiers.date(lastChange: 7_000.4, readAt: 7_000.5) == 7_000.4)
        #expect(SessionModifiers.date(lastChange: 7_000.6, readAt: 7_000.5) == 7_000.5)
        #expect(SessionModifiers.date(lastChange: 7_000.5 - 1.8e10, readAt: 7_000.5) == 0)
    }

    /// A reading from the session now is dated no later than it was taken.
    @Test func aLiveReadingIsDatedNoLaterThanItIsTaken() {
        let reading = SessionModifiers.read()
        let taken = ProcessInfo.processInfo.systemUptime
        #expect(0...taken ~= reading.changedAt)
    }
}
