import Foundation
import Identity
import Insertion
import os

private nonisolated let noticesLog = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "notices")

/// What this process tells the app, in the order it happened: every cursor that becomes the one
/// words go to (`FocusedClient`), so the app can offer words no cursor took to it, and
/// the process ending itself over its memory ceiling, so the app can say why it went away.
///
/// [LAW:no-shared-mutable-globals] One per `InputMethodProcess`. It is one stream with two writer's doors, `cursorArrived(in:)` and `activated(holding:)`,
/// and one reader, `relay`, which the process's entry point runs.
public nonisolated final class Notices: Sendable {
    /// IMK rule 7: the most memory this process holds before it ends itself, in bytes.
    public static let memoryCeiling: UInt64 = 1024 * 1024 * 1024

    public enum Notice: Equatable, Sendable {
        case cursorArrived
        case overMemoryCeiling(Overrun)
    }

    /// What one unit of this stream's work did. A test reads it from the sink it hands in; the
    /// shipped process's sink is the unified log, through `rendering`. [LAW:nothing-unseen]
    public enum Record: Equatable, Sendable {
        /// A cursor in this app became the one words go to.
        case cursorArrived(in: String)
        /// An activation read this footprint, in bytes, against the ceiling.
        case footprint(UInt64)
        /// An activation found the process over its ceiling, which it ends over.
        case overrun(Overrun)
        /// How telling the app fared, when it changed from the notice before.
        case told(NoticeSender.Told)
        /// The overrun was told, faring so, and the process ends now.
        case overrunTold(Overrun, NoticeSender.Told)

        /// What the unified log receives for this record. Everything is public: none of it is
        /// anything a person typed.
        public var rendering: (level: OSLogType, line: String) {
            switch self {
            case let .cursorArrived(application): (.info, "a cursor arrived in \(application)")
            case let .footprint(footprint): (.info, "activated holding \(footprint) bytes of a \(Notices.memoryCeiling) byte ceiling")
            case let .overrun(overrun): (.fault, "ending this process: \(overrun)")
            case let .told(told): (told.isFault ? .error : .default, told.description)
            case let .overrunTold(overrun, told): (.fault, "\(overrun); \(told)")
            }
        }

        /// The one edge where a record reaches the unified log. [LAW:single-enforcer]
        func log() {
            let (level, line) = rendering
            noticesLog.log(level: level, "\(line, privacy: .public)")
        }
    }

    /// One element per notice. The newest are kept if the reader falls behind, since one
    /// arrival is as good as another to the app. An overrun finishes the stream, so it is
    /// always the last element and nothing after it can push it out.
    /// [LAW:no-ambient-temporal-coupling]
    public let notices: AsyncStream<Notice>
    private let continuation: AsyncStream<Notice>.Continuation
    /// Where each record goes, as `Committer`'s `told` is.
    private let recorded: @Sendable (Record) -> Void

    init(recorded: @escaping @Sendable (Record) -> Void) {
        (notices, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.recorded = recorded
    }

    /// A cursor in `application` became the one words go to.
    public func cursorArrived(in application: String) {
        recorded(.cursorArrived(in: application))
        continuation.yield(.cursorArrived)
    }

    /// A controller was activated while this process held `footprint` bytes. The overrun, when
    /// it is over the ceiling, which the controller answers by taking no client.
    public func activated(holding footprint: UInt64) -> Overrun? {
        recorded(.footprint(footprint))
        return Overrun(footprint: footprint, ceiling: Self.memoryCeiling).map { overrun in
            recorded(.overrun(overrun))
            continuation.yield(.overMemoryCeiling(overrun))
            continuation.finish()
            return overrun
        }
    }

    /// Tells the app each notice through `tell`, and runs `end` once an overrun is told.
    /// How the telling fares is recorded when it changes, and always for an overrun: the app not
    /// listening is the ordinary state of an app that is not running. [LAW:no-silent-failure]
    ///
    /// [LAW:effects-at-boundaries] Telling and ending are the entry point's to bring.
    public func relay(tell: (Notice) -> NoticeSender.Told, end: () -> Void) async {
        var fared: NoticeSender.Told?
        for await notice in notices {
            let told = tell(notice)
            switch notice {
            case .cursorArrived:
                if told != fared { recorded(.told(told)) }
                fared = told
            case .overMemoryCeiling(let overrun):
                recorded(.overrunTold(overrun, told))
                end()
            }
        }
    }
}

extension NoticeSender {
    /// Tells the app `notice`.
    public func tell(_ notice: Notices.Notice) -> Told {
        switch notice {
        case .cursorArrived: tellCursorArrived()
        case .overMemoryCeiling(let overrun): tellOverMemoryCeiling(overrun)
        }
    }
}

/// This process's memory footprint in bytes - what Activity Monitor's Memory column shows - or
/// nil, said in the log, when the kernel will not say it. [LAW:no-silent-failure]
public nonisolated func ownFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let read = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard read == KERN_SUCCESS else {
        noticesLog.error("this process's memory footprint could not be read: \(String(cString: mach_error_string(read)), privacy: .public)")
        return nil
    }
    return info.phys_footprint
}
