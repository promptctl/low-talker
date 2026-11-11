import CoreGraphics
@testable import InputMethod
import Insertion
import os

/// An input method process assembled from fakes: readings the case sets, notices recorded as values,
/// steering whose gate asks `asking` and whose effects are recorded, and a committer of `bound`.
///
/// Every reading is read when the process asks for it, so a case changes what the Mac looks like
/// between two steps by setting it.
@MainActor final class AssembledProcess {
    var frontmost: String? = "com.example.editor"
    var selected = true
    var screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    var footprint: UInt64? = 0
    /// What the process recorded of its notices, in order.
    let recorded = OSAllocatedUnfairLock(initialState: [Notices.Record]())
    /// What the steering's verdicts asked for, in order.
    private(set) var performed: [SteeringEffect] = []
    private(set) var process: InputMethodProcess!

    init(asking: any SteeringAsking = SteeringGate.Unconnected(), bound: Duration = .seconds(20)) {
        let readings = Readings(frontmost: { [unowned self] in frontmost }, selected: { [unowned self] in selected },
                                screens: { [unowned self] in screens }, footprint: { [unowned self] in footprint })
        process = InputMethodProcess(
            readings: readings,
            notices: Notices { [recorded] record in recorded.withLock { $0.append(record) } },
            steering: { _ in Steering(gate: SteeringGate(ceiling: .seconds(30), asking: asking)) { [unowned self] in performed.append($0) } },
            committer: { steering in Committer(bound: bound, turns: steering.gate.turns) { _ in } })
    }

    /// A controller of this process, as `IMKServer` builds one per client.
    func controller() -> DictationInputController { DictationInputController(process: process) }
}
