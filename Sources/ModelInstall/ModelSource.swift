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
            try Archive.unpack(archive, into: unpacked)
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

    static func unpack(_ archive: URL, into directory: URL) throws {
        try ditto(["-x", "-k", archive.path, directory.path])
    }

    /// Zips the contents of `directory`, not the directory itself, so the archive
    /// unpacks into a store wherever it is put.
    static func pack(_ directory: URL, to archive: URL) throws {
        try ditto(["-c", "-k", "--norsrc", "--noextattr", "--noqtn", directory.path, archive.path])
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelInstallError.dittoFailed(arguments: arguments, status: process.terminationStatus, message: String(decoding: message, as: UTF8.self))
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
