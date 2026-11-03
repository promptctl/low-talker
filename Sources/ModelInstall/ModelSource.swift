import Foundation
import LowTalkerCore
import Synchronization
import WhisperKit

/// Where a model's files come from when the store does not have them.
///
/// [LAW:types-are-the-program] Every source ends as the same thing: the files of one
/// part laid down in the store and the manifest that proves them. A published archive
/// is a store in a zip, so it is fetched, unpacked, and then read as `.store`; nothing
/// but Hugging Face needs a layout of its own.
public enum ModelSource: Sendable, CustomStringConvertible {
    /// argmaxinc/whisperkit-coreml and the openai tokenizer repos on huggingface.co,
    /// through WhisperKit's hub client, at a revision; with none, at the one `main`
    /// names when the install starts.
    case huggingFace(ModelRevision?)
    /// Another store holding the model installed: its manifests say which files to
    /// take, and that they are whole before anything is taken.
    case store(ModelStore)
    /// A base URL serving `<model>.zip` for each model it carries, each archive a store
    /// holding that one model, as `ModelStore.pack` writes it.
    case published(URL)

    public var description: String {
        switch self {
        case .huggingFace(nil): "huggingface.co"
        case .huggingFace(let revision?): "huggingface.co at \(revision)"
        case .store(let store): store.directory.path
        case .published(let base): base.absoluteString
        }
    }

    /// The archive a published base serves for `model`.
    public static func archiveName(of model: ModelName) -> String {
        "\(model.rawValue).zip"
    }
}

/// A source made ready to hand over parts: a published archive downloaded and
/// unpacked into a store beside the destination, anything else as it is.
///
/// [LAW:no-ambient-temporal-coupling] The unpacked copy lives exactly as long as the
/// `with` body, so no caller can read a part out of an archive that was cleaned up.
enum OpenSource {
    /// Both parts are fetched at this one revision, so the tokenizer is the one the
    /// weights were named with even if `main` moves between them.
    case huggingFace(ModelRevision)
    case store(ModelStore)

    static func with<T>(
        _ source: ModelSource,
        _ model: ModelName,
        beside destination: ModelStore,
        phase: @escaping @Sendable (ModelStore.InstallPhase) -> Void,
        _ body: (OpenSource) async throws -> T
    ) async throws -> T {
        switch source {
        case .huggingFace(let revision?):
            return try await body(.huggingFace(revision))
        case .huggingFace(nil):
            return try await body(.huggingFace(ModelRevision.upstream(of: model)))
        case .store(let store):
            return try await body(.store(store))
        case .published(let base):
            // On the destination's volume, so the copy out of it is a clone.
            let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.directory, create: true)
            // [LAW:no-silent-failure] exception: a defer cannot throw, and a scratch
            // copy left behind costs disk, not correctness; the install's own error,
            // if there is one, is the one that must reach the caller.
            defer { try? FileManager.default.removeItem(at: scratch) }
            let archive = try await Archive.download(base.appending(path: ModelSource.archiveName(of: model)), into: scratch) { phase(.downloading(fractionCompleted: $0)) }
            try Task.checkCancellation()
            phase(.unpacking)
            let unpacked = scratch.appending(path: "store")
            try await Archive.unpack(archive, into: unpacked)
            return try await body(.store(ModelStore(directory: unpacked)))
        }
    }
}

/// A published model archive: a zip of a store, fetched over HTTP and unpacked with
/// `ditto`, which is what wrote it.
enum Archive {
    /// Fetches `url` into `directory`, reporting the fraction received. Anything but
    /// a 200 is an error naming the URL and the status, since a proxy's error page saved
    /// as the archive would only fail later, as a zip that does not unpack.
    ///
    /// A delegate-driven task, not the async `download(from:)`: that one delivers no
    /// progress to any delegate, and a 480 MB wait with no fraction reads as a hang.
    static func download(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let archive = directory.appending(path: url.lastPathComponent)
        let transfer = Transfer(source: url, destination: archive, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                transfer.wait(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return archive
    }

    static func unpack(_ archive: URL, into directory: URL) async throws {
        try await ditto(["-x", "-k", archive.path, directory.path])
    }

    /// Zips the contents of `directory`, not the directory itself, so the archive
    /// unpacks into a store wherever it is put.
    static func pack(_ directory: URL, to archive: URL) async throws {
        try await ditto(["-c", "-k", "--norsrc", "--noextattr", "--noqtn", directory.path, archive.path])
    }

    /// Awaits `ditto`'s exit rather than blocking on it: a caller is an async install, and
    /// a thread of the cooperative pool held for the whole of an unpack is one no other task
    /// can run on. Stderr goes to a file, so nothing has to drain a pipe while it waits.
    private static func ditto(_ arguments: [String]) async throws {
        let errors = FileManager.default.temporaryDirectory.appending(path: "ditto-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: errors.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: errors.path])
        }
        // [LAW:no-silent-failure] exception: a defer cannot throw, and a stray stderr file
        // costs disk, not correctness.
        defer { try? FileManager.default.removeItem(at: errors) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardError = try FileHandle(forWritingTo: errors)
        // A cancelled install stops the unpack rather than waiting it out.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (exited: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in exited.resume() }
                // Terminating a process never launched raises, so a task already cancelled
                // launches nothing, and the handler below stops only a running one.
                guard !Task.isCancelled else { return exited.resume(throwing: CancellationError()) }
                do { try process.run() } catch { return exited.resume(throwing: error) }
                // A cancel that landed between the check and the launch found nothing running.
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // A ditto stopped by a cancel exits failed, and the install was cancelled, not failed.
        try Task.checkCancellation()
        // Read off the process after the wait, which is also what holds it alive through it.
        let status = process.terminationStatus
        guard status == 0 else {
            // The exit is the failure; a stderr that cannot be read must not replace it.
            let message = (try? Data(contentsOf: errors)).map { String(decoding: $0, as: UTF8.self) } ?? "its stderr could not be read"
            throw ModelInstallError.dittoFailed(arguments: arguments, status: status, message: message)
        }
    }

    /// One download's delegate. The session calls it on its own serial queue, and the
    /// file it is handed exists only until `didFinishDownloadingTo` returns, so the
    /// move and the status check happen there and their verdict waits for completion.
    final class Transfer: NSObject, URLSessionDownloadDelegate, Sendable {
        let source: URL
        let destination: URL
        let progress: @Sendable (Double) -> Void
        private let outcome = Mutex<(any Error)?>(nil)
        private let meeting = Mutex<Meeting>(.apart)

        /// The download's caller and the task's end, in whichever order they arrive: a
        /// task cancelled before it was resumed can end before anyone waits for it.
        ///
        /// [LAW:no-ambient-temporal-coupling] The order is state, and whichever side
        /// comes second is the one that resumes the caller, so neither order is lost.
        private enum Meeting {
            case apart
            case waiting(CheckedContinuation<Void, any Error>)
            case ended(Result<Void, any Error>)
        }

        func wait(_ continuation: CheckedContinuation<Void, any Error>) {
            let ended: Result<Void, any Error>? = meeting.withLock { meeting in
                guard case .ended(let result) = meeting else {
                    meeting = .waiting(continuation)
                    return nil
                }
                return result
            }
            if let ended { continuation.resume(with: ended) }
        }

        init(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
            self.source = source
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            outcome.withLock { outcome in
                do {
                    guard status == 200 else { throw ModelInstallError.downloadRefused(url: source, status: status) }
                    try FileManager.default.moveItem(at: location, to: destination)
                } catch {
                    outcome = error
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let result = Result<Void, any Error> { if let failure = error ?? outcome.withLock({ $0 }) { throw failure } }
            let waiter: CheckedContinuation<Void, any Error>? = meeting.withLock { meeting in
                guard case .waiting(let continuation) = meeting else {
                    meeting = .ended(result)
                    return nil
                }
                return continuation
            }
            if let waiter { waiter.resume(with: result) }
        }
    }
}
