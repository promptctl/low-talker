import AppKit
import Darwin
@testable import MenuBarPresence
import Testing

@Suite struct ResponsibleProcessTests {
    /// The call the handoff rests on is one this macOS offers.
    @Test func thisMacSaysWhichProcessIsResponsible() {
        #expect(ResponsibleProcess.ofThisProcess() != .unknown)
    }

    @Test func aProcessResponsibleForItselfIsThis() {
        #expect(ResponsibleProcess(getpid(), this: getpid()) == .this)
    }

    /// The test runner is this process's parent, standing in for the terminal a shell's start
    /// leaves responsible.
    @Test func anotherResponsibleProcessIsNamedByItsExecutable() throws {
        let responsible = ResponsibleProcess(getppid(), this: getpid())
        guard case .other(let pid, let path?) = responsible else {
            Issue.record("read \(responsible)")
            return
        }
        #expect(pid == getppid())
        #expect(responsible.description == "\(path) (pid \(pid)) is responsible for it")
    }

    @Test func noPidIsUnknown() {
        #expect(ResponsibleProcess(-1, this: getpid()) == .unknown)
        #expect(ResponsibleProcess(0, this: getpid()) == .unknown)
    }

    @Test func eachSaysWhoIsResponsible() {
        #expect(ResponsibleProcess.this.description == "responsible for itself")
        #expect(ResponsibleProcess.other(42, path: nil).description == "pid 42, whose executable could not be read, is responsible for it")
        #expect(ResponsibleProcess.unknown.description == "which process is responsible for it could not be read")
    }
}

@Suite struct HandoffTests {
    private let terminal = ResponsibleProcess.other(7, path: "/Applications/Terminal.app/Contents/MacOS/Terminal")

    @Test func aStartedAppExitsZeroNamingWhatWasResponsible() {
        let handoff = Handoff(of: terminal, started: 99, error: "ignored once started")
        #expect(handoff.status == 0)
        #expect(handoff.said == "/Applications/Terminal.app/Contents/MacOS/Terminal (pid 7) is responsible for it, so macOS would file the menu bar icon under it; LaunchServices started LowTalker as pid 99 instead")
    }

    @Test func anAppNotStartedExitsOneSayingWhy() {
        let handoff = Handoff(of: terminal, started: nil, error: "no such file")
        #expect(handoff.status == 1)
        #expect(handoff.said.hasSuffix("and LaunchServices could not start LowTalker in its place: no such file"))
        let silent = Handoff(of: terminal, started: nil, error: nil)
        #expect(silent.status == 1)
        #expect(silent.said.hasSuffix("and LaunchServices answered neither an app nor an error when asked to start LowTalker in its place"))
    }
}

@Suite struct StatusItemSightingTests {
    private let made = ContinuousClock.now

    @Test func anIconOnScreenOnceIsShownFromTheFirstReadingThatSawIt() {
        var sighting = StatusItemSighting(made: made)
        sighting.saw(onScreen: false, at: made + .milliseconds(10))
        sighting.saw(onScreen: true, at: made + .milliseconds(390))
        sighting.saw(onScreen: false, at: made + .milliseconds(1100))
        sighting.saw(onScreen: true, at: made + .milliseconds(3300))
        #expect(sighting.verdict(menuBar: [nil, nil]) == .shown(after: .milliseconds(390)))
        #expect(sighting.verdict(menuBar: [.screenLocked, .screenLocked]) == .shown(after: .milliseconds(390)))
        #expect(sighting.verdict(menuBar: [nil, nil]).description == "icon shown 390 ms after it was made")
    }

    @Test func anIconNeverOnScreenIsHiddenOnlyWhileTheMenuBarWasInViewThroughTheLastStretch() {
        var sighting = StatusItemSighting(made: made)
        sighting.saw(onScreen: false, at: made + .milliseconds(10))
        #expect(sighting.verdict(menuBar: [nil, nil]) == .hidden)
        #expect(StatusItemSighting.Verdict.hidden.description == "icon not shown in the 10 s after it was made, while the menu bar was in view")
        let unseen: [MenuBarUnseen] = [.sessionNotOnConsole, .screenLocked, .displayAsleep, .menuBarHidden]
        for why in unseen { #expect(sighting.verdict(menuBar: [nil, why]) == .unjudged(why)) }
        // Out of view at the start of the last stretch and in view at the deadline: the
        // icon may still have been coming on screen.
        #expect(sighting.verdict(menuBar: [.screenLocked, nil]) == .unjudged(.screenLocked))
        #expect(sighting.verdict(menuBar: [.screenLocked, .displayAsleep]) == .unjudged(.displayAsleep))
        #expect(StatusItemSighting.Verdict.unjudged(.displayAsleep).description == "icon not shown in the 10 s after it was made, but the display was asleep, so it was not judged")
    }
}

@Suite struct HiddenIconNoticeTests {
    /// A defaults domain of its own, so the person's own choice is never read or written, and
    /// removed once the test is done with it.
    private func withScratch(_ test: (UserDefaults) -> Void) {
        let name = "MenuBarPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    @Test func aMacWithTheAllowListIsSentToItsSwitch() {
        withScratch { defaults in
            let notice = HiddenIconNotice(defaults: defaults, allowList: true)
            #expect(notice.body.contains("switched on under Allow in the Menu Bar, in System Settings > Menu Bar"))
            let settings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
            #expect(notice.answers == [.openMenuBarSettings(settings), .keepRunning, .quit])
            #expect(notice.answers.map(\.title) == ["Open Menu Bar Settings", "Keep Running", "Quit LowTalker"])
        }
    }

    @Test func aMacWithoutTheAllowListIsNotSentToASwitchItLacks() {
        withScratch { defaults in
            let notice = HiddenIconNotice(defaults: defaults, allowList: false)
            #expect(!notice.body.contains("Allow in the Menu Bar"))
            #expect(notice.body.contains("If an app that manages your menu bar is hiding it, show it there."))
            #expect(notice.answers == [.keepRunning, .quit])
        }
    }

    @Test func everyNoticeNamesTheNotch() {
        withScratch { defaults in
            for allowList in [true, false] {
                #expect(HiddenIconNotice(defaults: defaults, allowList: allowList).body.contains("On a screen with a notch, an icon the menu bar has no room for sits behind it."))
            }
        }
    }

    @Test func eachButtonIsItsAnswerAndAnythingElseIsNone() {
        withScratch { defaults in
            let notice = HiddenIconNotice(defaults: defaults, allowList: false)
            #expect(notice.answer(to: .alertFirstButtonReturn) == .keepRunning)
            #expect(notice.answer(to: .alertSecondButtonReturn) == .quit)
            #expect(notice.answer(to: .alertThirdButtonReturn) == nil)
            #expect(notice.answer(to: .abort) == nil)
            #expect(notice.answer(to: .stop) == nil)
        }
    }

    @Test func theNoticeIsSaidUntilThePersonSilencesIt() {
        withScratch { defaults in
            #expect(!HiddenIconNotice(defaults: defaults, allowList: true).silenced)
            HiddenIconNotice(defaults: defaults, allowList: true).silence()
            #expect(HiddenIconNotice(defaults: defaults, allowList: true).silenced)
        }
    }
}

@MainActor @Suite struct ErrorRowTests {
    /// A pasteboard of its own, so the person's clipboard is never read or written, and
    /// released once the test is done with it.
    private func withScratch(_ test: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: .init("MenuBarPresenceTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try test(pasteboard)
    }

    @Test func aClickReplacesWhatWasCopiedWithTheRowsFullTextAndSaysSo() throws {
        try withScratch { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("what the person had copied", forType: .string)
            pasteboard.setData(Data([1, 2, 3]), forType: .png)
            let text = "Your last dictation was not placed: " + String(repeating: "a reason long enough that a menu would shorten it ", count: 20) + "."
            var reported: [ErrorRow.Copied] = []
            let row = ErrorRow(text, copyingTo: pasteboard) { reported.append($0) }

            // A click, as AppKit sends it: the item's action to its target.
            let action = try #require(row.action)
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))

            #expect(pasteboard.data(forType: .png) == nil)
            #expect(pasteboard.string(forType: .string) == text)
            #expect(reported == [ErrorRow.Copied(characters: text.count, taken: true)])
        }
    }

    /// A menu disables any item nothing answers the click of.
    @Test func aMenuEnablesTheRow() {
        withScratch { pasteboard in
            let menu = NSMenu()
            let row = ErrorRow("Config: it cannot be read", copyingTo: pasteboard) { _ in }
            menu.addItem(row)
            menu.update()
            #expect(row.isEnabled)
        }
    }
}
