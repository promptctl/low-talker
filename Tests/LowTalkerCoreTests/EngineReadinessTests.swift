import LowTalkerCore
import Testing
import Uptime

/// The status item's face and words through the wait between launch and a loaded model.
@Suite struct EngineReadinessTests {
    let launch = HostTime(uptime: .seconds(100))

    @Test func aWaitSaysWhatItIsDoingAndHowLongItHasRun() {
        #expect(EngineReadiness.preparing(nil, since: launch).readout(at: launch + .seconds(0.4)) == "checking the model, 0 s so far")
        #expect(EngineReadiness.preparing(.loading, since: launch).readout(at: launch + .seconds(3)) == "loading model, minutes the first time on this Mac, 3 s so far")
        #expect(EngineReadiness.preparing(.loading, since: launch).readout(at: launch + .seconds(164.7)) == "loading model, minutes the first time on this Mac, 2 min 44 s so far")
    }

    /// The load's own length, however long after it the menu is opened: a readout taken an
    /// hour later still says how long the wait was.
    @Test func theEndOfTheWaitSaysHowLongItTook() {
        let ready = EngineReadiness.ready(.default, after: .seconds(60))
        #expect(ready.readout(at: launch) == "ready (\(ModelName.default)) after 1 min 0 s")
        #expect(ready.readout(at: launch + .seconds(3600)) == "ready (\(ModelName.default)) after 1 min 0 s")
        #expect(EngineReadiness.failed("no model").readout(at: launch) == "failed — no model")
    }

    /// A phase report queued behind the load's end cannot reopen the wait it ended.
    @Test func aLatePhaseLeavesAFinishedLoadFinished() {
        let failed = EngineReadiness.failed("the carried store lacks the tokenizer")
        let ready = EngineReadiness.ready(.default, after: .seconds(5))
        #expect(failed.reporting(.loading) == failed)
        #expect(ready.reporting(.loading) == ready)
        #expect(EngineReadiness.preparing(nil, since: launch).reporting(.loading) == .preparing(.loading, since: launch))
    }

    /// Each state draws its own icon: ready the app's mark, the wait and the failure
    /// their own.
    @Test func eachStateDrawsItsOwnIcon() {
        #expect(EngineReadiness.preparing(.loading, since: launch).statusGlyph() == .symbol("hourglass"))
        #expect(EngineReadiness.failed("x").statusGlyph() == .symbol("exclamationmark.triangle.fill"))
        #expect(EngineReadiness.ready(.default, after: .seconds(5)).statusGlyph() == .mark)
    }

    @Test func theIconNamesItsStateToAccessibility() {
        #expect(EngineReadiness.preparing(nil, since: launch).iconDescription(for: "LowTalker") == "LowTalker: preparing the model")
        #expect(EngineReadiness.failed("x").iconDescription(for: "LowTalker") == "LowTalker: the model failed to load")
        #expect(EngineReadiness.ready(.default, after: .seconds(5)).iconDescription(for: "LowTalker") == "LowTalker")
    }
}
