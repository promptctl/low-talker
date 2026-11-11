import CoreGraphics
@testable import InputMethod
import Insertion
import os

/// An input method process assembled from fakes: readings the case sets, notices recorded as values,
/// a gate that asks `asking`, beeps counted, and a committer of `bound`.
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
    /// How many times the process beeped.
    private(set) var beeps = 0
    private(set) var process: InputMethodProcess!

    /// The readings and the beep hold this fixture strongly, as the process holds them, so a case
    /// that keeps only the process or a controller still reads them.
    init(asking: any SteeringAsking = SteeringGate.Unconnected(), bound: Duration = .seconds(20)) {
        let readings = Readings(frontmost: { self.frontmost }, selected: { self.selected },
                                screens: { self.screens }, footprint: { self.footprint })
        process = InputMethodProcess(
            readings: readings, notices: Notices { [recorded] record in recorded.withLock { $0.append(record) } },
            gate: SteeringGate(ceiling: .seconds(30), asking: asking), beep: { self.beeps += 1 }, bound: bound, told: { _ in })
    }

    /// A controller of this process, as `IMKServer` builds one per client.
    func controller() -> DictationInputController { DictationInputController(process: process) }
}
