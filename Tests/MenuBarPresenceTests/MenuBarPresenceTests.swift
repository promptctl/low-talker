import Darwin
import Foundation
import MenuBarPresence
import Testing

@Suite struct LaunchOriginTests {
    /// The test runner started this process itself, which is the start a terminal gives an
    /// executable it runs, and the one the app hands to LaunchServices.
    @Test func aProcessAnotherStartedReadsAsStartedDirectlyByIt() throws {
        let origin = LaunchOrigin.ofThisProcess()
        guard case .directly(let parent, let path?) = origin else {
            Issue.record("read \(origin)")
            return
        }
        #expect(parent == getppid())
        #expect(origin.description == "started directly by \(path) (pid \(parent))")
    }

    @Test func eachOriginSaysWhatStartedIt() {
        #expect(LaunchOrigin.launchd.description == "started by launchd")
        #expect(LaunchOrigin.directly(by: 42, path: nil).description == "started directly by pid 42, whose executable could not be read")
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
        #expect(sighting.verdict(menuBarShown: true) == .shown(after: .milliseconds(390)))
        #expect(sighting.verdict(menuBarShown: false) == .shown(after: .milliseconds(390)))
        #expect(sighting.verdict(menuBarShown: true).description == "icon shown 390 ms after it was made")
    }

    @Test func anIconNeverOnScreenIsHiddenOnlyWhileTheMenuBarIsShown() {
        var sighting = StatusItemSighting(made: made)
        sighting.saw(onScreen: false, at: made + .milliseconds(10))
        #expect(sighting.verdict(menuBarShown: true) == .hidden)
        #expect(sighting.verdict(menuBarShown: false) == .menuBarHidden)
        #expect(StatusItemSighting.Verdict.hidden.description == "icon not shown in the 10 s after it was made, while the menu bar was")
        #expect(StatusItemSighting.Verdict.menuBarHidden.description == "icon not shown in the 10 s after it was made, but the menu bar was hidden too, so it was not judged")
    }
}

@Suite struct HiddenIconNoticeTests {
    /// A defaults domain of its own, so the person's own choice is never read or written.
    private func scratch() -> UserDefaults {
        let name = "MenuBarPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aMacWithTheAllowListIsSentToItsSwitch() {
        let notice = HiddenIconNotice(defaults: scratch(), allowList: true)
        #expect(notice.body.contains("switched on under Allow in the Menu Bar, in System Settings > Menu Bar"))
        let settings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
        #expect(notice.answers == [.openMenuBarSettings(settings), .keepRunning, .quit])
        #expect(notice.answers.map(\.title) == ["Open Menu Bar Settings", "Keep Running", "Quit LowTalker"])
    }

    @Test func aMacWithoutTheAllowListIsNotSentToASwitchItLacks() {
        let notice = HiddenIconNotice(defaults: scratch(), allowList: false)
        #expect(!notice.body.contains("Allow in the Menu Bar"))
        #expect(notice.body.contains("If an app that manages your menu bar is hiding it, show it there."))
        #expect(notice.answers == [.keepRunning, .quit])
    }

    @Test func theNoticeIsSaidUntilThePersonSilencesIt() {
        let defaults = scratch()
        #expect(!HiddenIconNotice(defaults: defaults, allowList: true).silenced)
        HiddenIconNotice(defaults: defaults, allowList: true).silence()
        #expect(HiddenIconNotice(defaults: defaults, allowList: true).silenced)
    }
}
