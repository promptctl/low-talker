import Foundation

/// Runs the blocking `body` on a thread of its own and awaits what it returned.
///
/// A test body runs on the cooperative pool, and a blocking call there holds one of its threads
/// for the whole wait. A blocking call on a dispatch queue holds a worker the pool needs as
/// much: on the three-core CI runner, three default-QoS workers blocked in one test or another
/// left the pool no thread for 15 s, and no test ran (sampled, PR #223). A `Thread` is no
/// worker of either.
public func onAThreadOfItsOwn<T: Sendable, Failure: Error>(_ body: @escaping @Sendable () throws(Failure) -> T) async throws(Failure) -> T {
    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Failure>, Never>) in
        Thread { continuation.resume(returning: Result(catching: body)) }.start()
    }
    return try result.get()
}
