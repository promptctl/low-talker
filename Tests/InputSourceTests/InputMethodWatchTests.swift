import Insertion
import Testing
@testable import InputSource

private let app = Build(number: "9", revision: "0123456789ab")
private let another = Build(number: "9", revision: "ba9876543210")

/// Where the input method stands, read off what the supervisor said of its process and what
/// that process said of its build, in whichever order the two arrive.
@Suite struct InputMethodWatchTests {
    @Test func nothingStandsUntilTheSupervisorSpeaks() {
        var watch = InputMethodWatch()
        #expect(watch.standing(for: app) == nil)
        watch.arrived(CursorArrival(pid: 7, build: another))
        #expect(watch.standing(for: app) == nil)
    }

    @Test func aRunningProcessIsNotYetSaidUntilItsFirstArrival() {
        var watch = InputMethodWatch()
        watch.told(.running(pid: 7, opening: 1))
        #expect(watch.standing(for: app) == .running(pid: 7, build: .notYetSaid))
        watch.arrived(CursorArrival(pid: 7, build: app))
        #expect(watch.standing(for: app) == .running(pid: 7, build: .sameBuild))
    }

    @Test(arguments: [Optional(another), nil])
    func aProcessOfAnotherBuildIsOtherBuild(said: Build?) throws {
        var watch = InputMethodWatch()
        watch.told(.running(pid: 7, opening: 1))
        watch.arrived(CursorArrival(pid: 7, build: said))
        #expect(watch.standing(for: app) == .otherBuild(pid: 7, try #require(BuildMismatch(app: app, inputMethod: said))))
    }

    /// A loop rebuilt makes a new supervisor, whose first word is the process already running.
    /// That process is still the build it said, so the mismatch stands rather than reading as
    /// listening.
    @Test func aRebuiltSupervisorKeepsTheBuildTheRunningProcessSaid() throws {
        var watch = InputMethodWatch()
        watch.told(.running(pid: 7, opening: 1))
        watch.arrived(CursorArrival(pid: 7, build: another))
        watch.told(.running(pid: 7, opening: 1))
        #expect(watch.standing(for: app) == .otherBuild(pid: 7, try #require(BuildMismatch(app: app, inputMethod: another))))
    }

    /// The process the supervisor opens next is not the one that said a build, so nothing it
    /// said counts until the new one says its own.
    @Test func aNewProcessIsNotYetSaidWhateverTheLastOneSaid() {
        var watch = InputMethodWatch()
        watch.told(.running(pid: 7, opening: 1))
        watch.arrived(CursorArrival(pid: 7, build: another))
        watch.told(.ended(pid: 7, launched: nil))
        #expect(watch.standing(for: app) == .ended(pid: 7))
        watch.told(.running(pid: 8, opening: 2))
        #expect(watch.standing(for: app) == .running(pid: 8, build: .notYetSaid))
        watch.arrived(CursorArrival(pid: 8, build: app))
        #expect(watch.standing(for: app) == .running(pid: 8, build: .sameBuild))
    }

    /// A process can be handed a cursor before the supervisor hears it is running, and what it
    /// said then counts once it is.
    @Test func anArrivalBeforeTheSupervisorsWordCountsOnceItComes() throws {
        var watch = InputMethodWatch()
        watch.told(.ended(pid: 7, launched: nil))
        watch.arrived(CursorArrival(pid: 8, build: another))
        watch.told(.running(pid: 8, opening: 2))
        #expect(watch.standing(for: app) == .otherBuild(pid: 8, try #require(BuildMismatch(app: app, inputMethod: another))))
    }

    @Test func aProcessThatCouldNotBeOpenedSaysWhy() {
        var watch = InputMethodWatch()
        watch.told(.notOpened("refused", opening: 1))
        #expect(watch.standing(for: app) == .notOpened("refused"))
    }
}
