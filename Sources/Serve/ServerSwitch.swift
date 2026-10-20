import Foundation
import LowTalkerCore
import Security
import Synchronization

/// An app's transcription server: whether the person has switched it on, what it is doing,
/// and the engine it answers with. The one owner of the app's listener, so the menu, the
/// saved choice and the socket cannot disagree about whether the app serves.
/// [LAW:single-enforcer]
///
/// Only a build signed to accept connections has one: see `ifEntitled`. With the choice off,
/// nothing is bound.
@MainActor
public final class ServerSwitch {
    /// What the server is doing now, in the words the menu says it.
    public enum State: CustomStringConvertible, Sendable {
        case off
        /// Asked to listen, and not listening yet.
        case starting
        case listening(TranscriptionServer)
        /// Asked to listen and not listening, and why: the address refused, no binding could
        /// be read, or the listener failed after it was up.
        case stopped(String)

        public var description: String {
            switch self {
            case .off: "off"
            case .starting: "starting"
            case .listening(let server): "listening at \(server.baseURL)"
            case .stopped(let reason): "stopped — \(reason)"
            }
        }
    }

    public private(set) var state: State = .off {
        didSet { ServedRequest.logger.notice("server: \(self.state, privacy: .public)") }
    }

    /// Whether the person has switched serving on, kept in the app's defaults. Unset reads
    /// as off. [LAW:one-source-of-truth]
    public var chosen: Bool { defaults.bool(forKey: Self.choiceKey) }
    static let choiceKey = "serves"

    /// The engine every request is answered with, read at each request: the app's own
    /// resident model once it has loaded, so there is never a second copy in memory.
    private let resident = Resident()
    private let defaults: UserDefaults
    private let listen: @Sendable (ServeBinding, @escaping @Sendable () -> ServedEngine) async throws(ListenRefused) -> TranscriptionServer
    /// The attempt that is the current one, which ends once its server has.
    ///
    /// [LAW:no-ambient-temporal-coupling] Each attempt awaits the one before it, so a new
    /// listen asks for the port only after the last server has let it go.
    private(set) var running: Task<Void, Never>?
    private var attempts = 0

    init(
        defaults: UserDefaults,
        listen: @escaping @Sendable (ServeBinding, @escaping @Sendable () -> ServedEngine) async throws(ListenRefused) -> TranscriptionServer
    ) {
        self.defaults = defaults
        self.listen = listen
    }

    /// This process's switch when its signature carries `com.apple.security.network.server`,
    /// which only the network build's does, and nil otherwise: the offline build cannot
    /// accept a connection, so it has no server to switch.
    ///
    /// [LAW:one-source-of-truth] Read off the signature, the fact `scripts/variant` reads to
    /// name a package, rather than a second flag the build would have to keep in step with it.
    public static func ifEntitled(defaults: UserDefaults = .standard) -> ServerSwitch? {
        let entitlement = "com.apple.security.network.server"
        let granted = SecTaskCreateFromSelf(nil)
            .flatMap { SecTaskCopyValueForEntitlement($0, entitlement as CFString, nil) } as? Bool == true
        ServedRequest.logger.notice("server: \(granted ? "network build, may serve" : "offline build, no server", privacy: .public)")
        guard granted else { return nil }
        return ServerSwitch(defaults: defaults) { binding, engine throws(ListenRefused) in
            try await TranscriptionServer.listen(on: binding, engine: engine)
        }
    }

    /// The engine requests are answered with from now on.
    public func answer(with engine: ServedEngine) {
        resident.engine.withLock { $0 = engine }
    }

    /// Records the person's choice and brings the server into line with it.
    public func choose(_ on: Bool, at binding: @escaping @MainActor () async throws -> ServeBinding) {
        defaults.set(on, forKey: Self.choiceKey)
        resume(at: binding)
    }

    /// Brings the server into line with the choice already made: at launch, what the person
    /// last chose.
    ///
    /// `binding` is awaited once the attempt is `starting`, so a binding the app has yet to
    /// read reads as starting, and one it could not read as stopped with why.
    ///
    /// [LAW:dataflow-not-control-flow] Every call takes down what is there and then listens
    /// if the choice says to, so a second call is a restart and never a second listener.
    public func resume(at binding: @escaping @MainActor () async throws -> ServeBinding) {
        stop()
        guard chosen else { return }
        attempts += 1
        let attempt = attempts
        state = .starting
        let before = running
        let resident = resident
        running = Task {
            await before?.value
            let server: TranscriptionServer
            do {
                server = try await listen(try await binding(), { resident.engine.withLock { $0 } })
            } catch {
                // A binding that cannot be read names no address, so the server says why it
                // has none rather than guessing loopback. [LAW:no-silent-failure]
                settle(attempt, as: .stopped(error is ConfigError ? "the config cannot be read: \(error)" : "\(error)"))
                return
            }
            // Switched off, or asked again, while the port was being bound.
            guard settle(attempt, as: .listening(server)) else {
                server.stop()
                try? await server.finished()
                return
            }
            do { try await server.finished() } catch { settle(attempt, as: .stopped("the listener failed: \(error)")) }
        }
    }

    /// Takes this attempt's outcome as the state only while it is still the current attempt,
    /// and says whether it did.
    @discardableResult
    private func settle(_ attempt: Int, as next: State) -> Bool {
        guard attempts == attempt else { return false }
        state = next
        return true
    }

    /// Stops accepting connections, and gives up the attempt still binding, if any, which lets
    /// its port go: one waiting for an address no interface holds would otherwise never end,
    /// and every attempt after it waits on it.
    private func stop() {
        running?.cancel()
        if case .listening(let server) = state { server.stop() }
        attempts += 1
        state = .off
    }
}

/// The engine the listener reads at every request, which the app sets as its model loads.
private final class Resident: Sendable {
    let engine = Mutex(ServedEngine.loading)
}
