import Foundation
import Identity
import Insertion
import os

private nonisolated let log = Logger(subsystem: AppIdentity.inputMethodBundleIdentifier, category: "notices")

/// What this process tells the app, in the order it happened: every cursor a controller is
/// given focus in, so the app can offer words no cursor took to the one that just arrived, and
/// the process ending itself over its memory ceiling, so the app can say why it went away.
///
/// [LAW:no-shared-mutable-globals] Shared for `FocusedClient`'s reason: `IMKServer` builds
/// controllers out of a class name, so there is no constructor of ours to hand a sender to.
/// It is one stream with two writer's doors, `cursorArrived(in:)` and `activated(holding:)`,
/// and one reader, `relay`, which the process's entry point runs.
public nonisolated final class Notices: Sendable {
    public static let shared = Notices()

    /// IMK rule 7: the most memory this process holds before it ends itself, in bytes.
    public static let memoryCeiling: UInt64 = 1024 * 1024 * 1024

    public enum Notice: Equatable, Sendable {
        case cursorArrived
        case overMemoryCeiling(Overrun)
    }

    /// One element per notice. The newest are kept if the reader falls behind, since one
    /// arrival is as good as another to the app. An overrun finishes the stream, so it is
    /// always the last element and nothing after it can push it out.
    /// [LAW:no-ambient-temporal-coupling]
    public let notices: AsyncStream<Notice>
    private let continuation: AsyncStream<Notice>.Continuation

    init() {
        (notices, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// A controller was given focus in a cursor that can take words, in `application`.
    public func cursorArrived(in application: String) {
        log.info("a cursor arrived in \(application, privacy: .public)")
        continuation.yield(.cursorArrived)
    }

    /// A controller was activated while this process held `footprint` bytes.
    public func activated(holding footprint: UInt64) {
        log.info("activated holding \(footprint, privacy: .public) bytes of a \(Self.memoryCeiling, privacy: .public) byte ceiling")
        Overrun(footprint: footprint, ceiling: Self.memoryCeiling).map { overrun in
            log.fault("ending this process: \(overrun.description, privacy: .public)")
            continuation.yield(.overMemoryCeiling(overrun))
            continuation.finish()
        }
    }

    /// Tells the app each notice through `tell`, and runs `end` once an overrun is told.
    /// How the telling fares is said when it changes, and always for an overrun: the app not
    /// listening is the ordinary state of an app that is not running. [LAW:no-silent-failure]
    ///
    /// [LAW:effects-at-boundaries] Telling and ending are the entry point's to bring.
    public static func relay(_ notices: AsyncStream<Notice>, tell: (Notice) -> NoticeSender.Told, end: () -> Void) async {
        var fared: NoticeSender.Told?
        for await notice in notices {
            let told = tell(notice)
            switch notice {
            case .cursorArrived:
                if told != fared { log.log(level: told.isFault ? .error : .default, "\(told.description, privacy: .public)") }
                fared = told
            case .overMemoryCeiling(let overrun):
                log.fault("\(overrun.description, privacy: .public); \(told.description, privacy: .public)")
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
        log.error("this process's memory footprint could not be read: \(String(cString: mach_error_string(read)), privacy: .public)")
        return nil
    }
    return info.phys_footprint
}
