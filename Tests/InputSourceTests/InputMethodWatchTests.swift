import Insertion
import Testing
@testable import InputSource

private let app = Build(number: "9", revision: "0123456789ab")
private let another = Build(number: "9", revision: "ba9876543210")

/// Where the input method stands, read off what the supervisor said of its process and what
/// that process said of its build, in whichever order the two arrive.
@Suite struct InputMethodWatchTests {
    @Test func nothingStandsUntilTheSupervisorSpeaks() {
        var watch = InputMethodWatch(app: app)
        #expect(watch.standing == nil)
        #expect(watch.arrived(CursorArrival(pid: 7, build: another)) == nil)
        #expect(watch.standing == nil)
    }

    @Test func aRunningProcessIsNotYetSaidUntilItsFirstArrival() {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.running(pid: 7, opening: 1))
        #expect(watch.standing == .running(pid: 7, build: .notYetSaid))
        _ = watch.arrived(CursorArrival(pid: 7, build: app))
        #expect(watch.standing == .running(pid: 7, build: .sameBuild))
    }

    @Test(arguments: [Optional(another), nil])
    func aProcessOfAnotherBuildIsOtherBuild(said: Build?) throws {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.running(pid: 7, opening: 1))
        _ = watch.arrived(CursorArrival(pid: 7, build: said))
        #expect(watch.standing == .otherBuild(pid: 7, try #require(BuildMismatch(app: app, inputMethod: said))))
    }

    /// A loop rebuilt makes a new supervisor, whose first word is the process already running.
    /// That process is still the build it said, so the mismatch stands rather than reading as
    /// listening.
    @Test func aRebuiltSupervisorKeepsTheBuildTheRunningProcessSaid() throws {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.running(pid: 7, opening: 1))
        _ = watch.arrived(CursorArrival(pid: 7, build: another))
        _ = watch.told(.running(pid: 7, opening: 1))
        #expect(watch.standing == .otherBuild(pid: 7, try #require(BuildMismatch(app: app, inputMethod: another))))
    }

    /// The process the supervisor opens next is not the one that said a build, so nothing it
    /// said counts until the new one says its own.
    @Test func aNewProcessIsNotYetSaidWhateverTheLastOneSaid() {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.running(pid: 7, opening: 1))
        _ = watch.arrived(CursorArrival(pid: 7, build: another))
        _ = watch.told(.ended(pid: 7, launched: nil))
        #expect(watch.standing == .ended(pid: 7))
        _ = watch.told(.running(pid: 8, opening: 2))
        #expect(watch.standing == .running(pid: 8, build: .notYetSaid))
        _ = watch.arrived(CursorArrival(pid: 8, build: app))
        #expect(watch.standing == .running(pid: 8, build: .sameBuild))
    }

    /// A process can be handed a cursor before the supervisor hears it is running, and what it
    /// said then counts once it is.
    @Test func anArrivalBeforeTheSupervisorsWordCountsOnceItComes() throws {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.ended(pid: 7, launched: nil))
        _ = watch.arrived(CursorArrival(pid: 8, build: another))
        _ = watch.told(.running(pid: 8, opening: 2))
        #expect(watch.standing == .otherBuild(pid: 8, try #require(BuildMismatch(app: app, inputMethod: another))))
    }

    @Test func aProcessThatCouldNotBeOpenedSaysWhy() {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.notOpened("refused", opening: 1))
        #expect(watch.standing == .notOpened("refused"))
    }

    /// Every word of the supervisor's is shown, since the line may hold what a rebuild put up,
    /// and the log hears a standing only the first time.
    @Test func everySupervisorWordIsShownAndANewStandingLogged() {
        var watch = InputMethodWatch(app: app)
        #expect(watch.told(.running(pid: 7, opening: 1)) == .init(standing: .running(pid: 7, build: .notYetSaid), isNew: true))
        #expect(watch.told(.running(pid: 7, opening: 1)) == .init(standing: .running(pid: 7, build: .notYetSaid), isNew: false))
    }

    /// An arrival in each app the person moves to shows nothing, so the line keeps whatever
    /// else it says, and only one that moves the standing is shown and logged.
    @Test func anArrivalIsShownOnlyWhenItMovesTheStanding() throws {
        var watch = InputMethodWatch(app: app)
        _ = watch.told(.running(pid: 7, opening: 1))
        let mismatch = try #require(BuildMismatch(app: app, inputMethod: another))
        #expect(watch.arrived(CursorArrival(pid: 7, build: another)) == .init(standing: .otherBuild(pid: 7, mismatch), isNew: true))
        #expect(watch.arrived(CursorArrival(pid: 7, build: another)) == nil)
        _ = watch.told(.running(pid: 8, opening: 2))
        #expect(watch.arrived(CursorArrival(pid: 8, build: app)) == .init(standing: .running(pid: 8, build: .sameBuild), isNew: true))
        #expect(watch.arrived(CursorArrival(pid: 8, build: app)) == nil)
    }
}
