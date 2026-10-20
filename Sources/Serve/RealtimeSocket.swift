import AVFoundation
import Foundation
import LowTalkerCore
import Network
import Synchronization

/// One Realtime transcription socket, from the 101 to the close (epic low-serve-axq): the
/// client's events read in order, each item heard by one streaming `transcribe`, and every
/// server event sent through one outbox.
struct RealtimeSocket {
    /// One of the server's places for sockets, held for as long as this one is.
    let place: Place
    let transcriber: any Transcriber
    /// The most audio the socket holds at once, in seconds, across every item from its
    /// first append until it is heard.
    let audio: TimeInterval

    /// The most one message may hold. Pipecat's appends are about 5 KB of base64 each.
    static let messageLimit = 1 << 20

    /// Serves the socket until the client closes it, breaks the protocol, or is lost, and
    /// says what happened on it.
    func run(_ connection: NWConnection, _ reader: inout Reader) async -> (RealtimeActivity, lost: String?) {
        let outbox = Outbox()
        // [LAW:single-enforcer] The one writer: every frame goes out in the order it was
        // put in the outbox, and is counted once it has gone.
        let writer = Task {
            var sent = RealtimeActivity.Sent()
            for await queued in outbox.frames {
                do {
                    try await connection.send(queued.bytes)
                } catch {
                    // Nothing more can reach the client, so the reader stops too: closing
                    // ends its wait for room, and the cancel fails its pending read.
                    outbox.close(nil)
                    connection.cancel()
                    return (sent, "\(error)" as String?)
                }
                outbox.sent(queued.bytes.count)
                sent.count(queued.frame)
            }
            return (sent, nil as String?)
        }
        var activity = RealtimeActivity()
        // [LAW:no-ambient-temporal-coupling] Every item is a child of `items`, so none
        // outlives the socket, and each is gone from it once answered.
        let lost = await withDiscardingTaskGroup { items in
            var state = State(session: RealtimeSession(), outbox: outbox, held: HeldAudio(limit: audio))
            state.outbox.emit(.sessionCreated(id: state.sessionID, state.session))
            var assembler = WebSocket.Assembler()
            /// The frame the server ends with; none when the connection was lost.
            var last: Data?
            var lost: String?
            reading: while true {
                // Backpressure: a client that does not read is not read, so what it sends
                // cannot pile up frames it will never take (low-serve-axq.69k).
                await outbox.room()
                let message: WebSocket.Message
                do {
                    message = try await reader.message(&assembler, limit: Self.messageLimit)
                } catch let violation as WebSocket.Violation {
                    activity.violation = violation.description
                    activity.closeCode = Int(violation.code)
                    last = WebSocket.close(violation.code, violation.description)
                    break reading
                } catch {
                    lost = "\(error)"
                    break reading
                }
                switch message {
                case .text(let text):
                    state.receive(text, transcriber: transcriber, &activity, &items)
                case .binary:
                    let violation = WebSocket.Violation(code: 1003, "binary messages are not part of the Realtime API")
                    activity.violation = violation.description
                    activity.closeCode = Int(violation.code)
                    last = WebSocket.close(violation.code, violation.description)
                    break reading
                case .ping(let payload):
                    state.outbox.put(.control(WebSocket.frame(.pong, payload)))
                case .pong:
                    continue
                case .close(let code):
                    // Echoed, as RFC 6455 asks: the client's code is the one the close carries.
                    activity.closeCode = code.map(Int.init)
                    last = code.map { WebSocket.close($0) } ?? WebSocket.frame(.close, Data())
                    break reading
                }
            }
            // Closed first, so what items say while they stop is dropped rather than sent
            // after the close. Items still being heard have no one left to hear them.
            outbox.close(last)
            state.abandon()
            items.cancelAll()
            return lost
        }
        let (sent, unsent) = await writer.value
        activity.sent = sent
        (activity.mostUnsentBytes, activity.backpressureWaits) = outbox.pressure
        return (activity, unsent ?? lost)
    }

    /// The session as the reader holds it between messages.
    private struct State {
        var session: RealtimeSession
        let outbox: Outbox
        let held: HeldAudio
        let sessionID = "sess_\(ID.fresh())"
        /// The item appends are going to, from the first append after a commit.
        var buffer: Buffer?
        /// The last item committed: the one the next follows, and its answer, which the
        /// next is heard after.
        var last: (id: String, answered: Task<Void, Never>)?

        mutating func receive(_ text: String, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) {
            var clientEvent: String?
            do throws(RealtimeError) {
                let object = try ClientEvent.object(text)
                clientEvent = object["event_id"] as? String
                switch try ClientEvent.parse(object, onto: session) {
                case .update(let updated):
                    activity.updates += 1
                    session = updated
                    outbox.emit(.sessionUpdated(id: sessionID, session))
                case .append(let bytes):
                    activity.appends += 1
                    try append(bytes, transcriber: transcriber, &activity, &items)
                case .commit:
                    try commit(&activity, &items)
                }
            } catch {
                activity.refused(error)
                outbox.emit(.error(error, clientEvent: clientEvent))
            }
        }

        /// `bytes` into the open item, which the first append after a commit opens. An item
        /// the append would grow past its share of the socket starts over first, from its
        /// newest audio, so a client that appends through any length of silence without a
        /// commit, as Pipecat does between turns, is never refused for it (low-serve-axq.f96).
        /// Refused whole, before any of it is taken in, only when it would take the socket's
        /// held audio past its limit, which is then held by items committed and not yet heard.
        /// The reader never waits on the engine: a socket whose items are still being heard
        /// goes on reading, pings included, so engine contention delays its transcripts and
        /// nothing else (low-serve-axq.32w).
        private mutating func append(_ bytes: Data, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) throws(RealtimeError) {
            let holding = try held.take(bytes: bytes.count, items: buffer == nil ? 1 : 0)
            activity.heldAudioSeconds = max(activity.heldAudioSeconds, holding.seconds)
            activity.heldItems = max(activity.heldItems, holding.items)
            if let open = buffer, open.bytes + bytes.count > held.share {
                buffer = startOver(open, transcriber: transcriber, &activity, &items)
            }
            let open = buffer ?? self.open(after: last?.answered, transcriber, &activity, &items)
            open.append(bytes)
            buffer = open
        }

        /// A new item for appends to go to, heard once `previous` has ended.
        private func open(after previous: Task<Void, Never>?, _ transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) -> Buffer {
            let opened = Buffer(transcriber: transcriber, vocabulary: session.vocabulary, outbox: outbox, keeping: held.kept, after: previous)
            activity.items += 1
            let transcription = opened.transcription
            items.addTask {
                await withTaskCancellationHandler { _ = await transcription.result } onCancel: { transcription.cancel() }
            }
            return opened
        }

        /// `item` let go unheard, and a new item opened in its place holding its newest
        /// audio. No turn the client heard ended in it, since it committed none of it, and a
        /// speaker who began just before is in the audio kept. What the let-go item held
        /// beyond that is free once its transcribe has ended, which cancelling it brings
        /// about at its next pass, or at once while it waits its turn. The new item is heard
        /// only then, and once the last one committed is answered.
        private func startOver(_ item: Buffer, transcriber: any Transcriber, _ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) -> Buffer {
            let kept = item.letGo()
            let (held, freed, transcription, previous) = (held, item.bytes - kept.count, item.transcription, last?.answered)
            activity.letGo(seconds: RealtimeAudio.duration(bytes: freed))
            // [LAW:no-ambient-temporal-coupling] The new item's turn follows the release, so
            // a transcribe that has started proves what the item before it held is free.
            let turn = Task {
                _ = await transcription.result
                held.release(bytes: freed, items: 0)
                await previous?.value
            }
            items.addTask { await turn.value }
            let reopened = open(after: turn, transcriber, &activity, &items)
            reopened.append(kept)
            return reopened
        }

        /// The open item ends and is answered; with no audio in one, the commit is refused.
        private mutating func commit(_ activity: inout RealtimeActivity, _ items: inout DiscardingTaskGroup) throws(RealtimeError) {
            guard let buffer, buffer.hasAudio else { throw .bufferEmpty }
            self.buffer = nil
            let heard = buffer.end()
            activity.audioSeconds += heard
            for event in [ServerEvent.committed(item: buffer.id, previous: last?.id), .itemAdded(item: buffer.id, previous: last?.id), .itemDone(item: buffer.id, previous: last?.id)] {
                outbox.emit(event)
            }
            let deltas = buffer.deltas
            let transcription = buffer.transcription
            let (held, bytes) = (held, buffer.bytes)
            // [LAW:no-ambient-temporal-coupling] Freed before the item is answered, so a
            // client that appends on hearing it finds the room already there.
            let answered = Task {
                let result = await transcription.result
                held.release(bytes: bytes, items: 1)
                await deltas.settle(result, heard: heard)
            }
            last = (buffer.id, answered)
            items.addTask { await answered.value }
        }

        func abandon() {
            buffer?.abandon()
        }
    }
}

/// What one socket holds, from each append until its item is heard: the bytes appends
/// carry, and a second more of them for each item, since holding an item costs more than
/// its audio. [LAW:single-enforcer] The one count of it, so the memory a socket holds is
/// bounded however many items, however short, its client commits while the engine is busy.
private final class HeldAudio: Sendable {
    /// What an item costs beyond its audio, in bytes of audio: a second of it.
    private static let perItem = RealtimeAudio.rate * 2
    private let limit: TimeInterval
    /// The most audio, in bytes, the open item grows to before it starts over: half the
    /// limit, so an item the client leaves open never holds the room its committed items
    /// wait in.
    let share: Int
    /// What an item that starts over keeps of its newest audio, in bytes: half its share,
    /// so it starts over again only after as much more, and a speaker who began before it
    /// did keeps minutes of their words.
    let kept: Int
    private let held = Mutex((bytes: 0, items: 0))

    init(limit: TimeInterval) {
        self.limit = limit
        share = Int(limit / 2 * Double(RealtimeAudio.rate)) * 2
        kept = share / 2
    }

    /// `bytes` more held in `items` more items, refused whole when they would take the
    /// socket past its limit; returns what the socket holds with them.
    func take(bytes: Int, items: Int) throws(RealtimeError) -> (seconds: TimeInterval, items: Int) {
        try held.withLock { held throws(RealtimeError) in
            let charged = held.bytes + bytes + items * Self.perItem
            let seconds = RealtimeAudio.duration(bytes: charged)
            guard seconds <= limit else { throw .audioTooLong(seconds: seconds, limit: limit) }
            held = (charged, held.items + items)
            return (seconds, held.items)
        }
    }

    /// `bytes` held in `items` items are free: an item heard, or audio an item let go.
    func release(bytes: Int, items: Int) {
        held.withLock { $0 = ($0.bytes - bytes - items * Self.perItem, $0.items - items) }
    }
}

/// One item's audio while it is being appended: 24 kHz PCM16 in, 16 kHz clips out to the
/// `transcribe` that opened with it.
private final class Buffer {
    let id: String
    let deltas: Deltas
    let transcription: Task<Transcription, any Error>
    private let clips: AsyncStream<AudioClip>.Continuation
    private let converter: AudioClip.Converter
    /// A byte of a sample whose other byte the next append carries.
    private var carry = Data()
    /// Whole samples appended, at 24 kHz.
    private var received = 0
    /// Samples delivered, at 16 kHz.
    private var samples = 0
    /// What it starts over from: its newest `keeping` bytes, beside the audio `HeldAudio`
    /// counts, so an open item holds up to that much more.
    private var newest: Newest

    /// What appends carry: PCM16 at 24 kHz.
    private let format: AVAudioFormat

    /// `after` ends when this item's turn comes: the item before it answered, or let go and
    /// its audio free.
    init(transcriber: any Transcriber, vocabulary: Vocabulary, outbox: Outbox, keeping: Int, after previous: Task<Void, Never>?) {
        newest = Newest(capacity: keeping)
        // [LAW:no-silent-failure] A fixed pair of formats AVFoundation converts between;
        // a throw here, or from converting or draining between them, is a programming
        // error, so it traps.
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RealtimeAudio.rate), channels: 1, interleaved: true)!
        converter = try! AudioClip.Converter(from: format)
        let (stream, clips) = AsyncStream<AudioClip>.makeStream()
        self.clips = clips
        id = "item_\(ID.fresh())"
        let deltas = Deltas(item: id, outbox: outbox)
        self.deltas = deltas
        // [LAW:no-ambient-temporal-coupling] An item is heard only once the one before it
        // is answered, so a socket's items are answered in the order they were committed:
        // the engine takes decodes in turn, but an item's several passes are not one turn.
        // Its audio waits in `stream` meanwhile, within the socket's held audio, until the
        // item is heard or, let go while it waits, cancelled.
        transcription = Task {
            if let previous { await ended(previous) }
            try Task.checkCancellation()
            return try await transcriber.transcribe(stream, expecting: vocabulary, partial: deltas.heard)
        }
    }

    var hasAudio: Bool { received > 0 }

    /// Bytes appended, the odd one waiting for its sample's other half included.
    var bytes: Int { received * 2 + carry.count }

    func append(_ bytes: Data) {
        newest.append(bytes)
        let whole = carry + bytes
        let even = whole.count & ~1
        carry = whole.suffix(whole.count - even)
        received += even / 2
        deliver(convert(whole.prefix(even)))
    }

    /// The item's audio ends; returns how many seconds of it there were.
    func end() -> TimeInterval {
        defer { clips.finish() }
        deliver(try! converter.drain())
        return AudioClip.duration(for: samples)
    }

    func abandon() {
        clips.finish()
    }

    /// The item ends unheard: its transcribe is cancelled and it sends no more deltas.
    /// Returns its newest `keeping` bytes, starting on a whole sample.
    func letGo() -> Data {
        // Cancelled first, so ending its audio cannot start a last pass the engine admits.
        transcription.cancel()
        clips.finish()
        let newest = newest.bytes
        deltas.letGo()
        return newest.suffix(newest.count - (bytes - newest.count) % 2)
    }

    private func convert(_ pcm: Data) -> [Float] {
        let frames = pcm.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.int16ChannelData![0], count: frames * 2))
        return try! converter.convert(buffer)
    }

    private func deliver(_ converted: [Float]) {
        samples += converted.count
        clips.yield(AudioClip(samples: converted))
    }
}

/// The newest `capacity` bytes appended, in a ring of that many, so keeping them costs
/// each append only its own bytes.
struct Newest {
    let capacity: Int
    private var ring = Data()
    /// Where the oldest byte is, once the ring is full, and the next byte goes.
    private var oldest = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ bytes: Data) {
        var rest = bytes.suffix(capacity)
        let filling = min(capacity - ring.count, rest.count)
        ring.append(rest.prefix(filling))
        rest = rest.dropFirst(filling)
        while !rest.isEmpty {
            let run = min(capacity - oldest, rest.count)
            ring.replaceSubrange(oldest..<oldest + run, with: rest.prefix(run))
            oldest = (oldest + run) % capacity
            rest = rest.dropFirst(run)
        }
    }

    /// Oldest first.
    var bytes: Data {
        ring.suffix(from: oldest) + ring.prefix(oldest)
    }
}

/// Returns once `task` has ended, or at once when the waiting task is cancelled.
private func ended(_ task: Task<Void, Never>) async {
    let waiting = Waiting()
    await withTaskCancellationHandler {
        await withCheckedContinuation { waiter in
            waiting.wait(waiter)
            Task {
                await task.value
                waiting.end()
            }
        }
    } onCancel: {
        waiting.cancel()
    }
}

/// The one waiter `ended` resumes, by whichever of its task and its cancellation comes first.
private final class Waiting: Sendable {
    private let state = Mutex<(cancelled: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait(_ waiter: CheckedContinuation<Void, Never>) {
        // Under the lock `cancel` also takes, so a cancel either lands before this and is
        // seen here, or after and finds the waiter.
        let cancelled = state.withLock { state in
            if !state.cancelled { state.waiter = waiter }
            return state.cancelled
        }
        if cancelled { waiter.resume() }
    }

    func end() {
        state.withLock { $0.waiter.take() }?.resume()
    }

    func cancel() {
        state.withLock { state in
            state.cancelled = true
            return state.waiter.take()
        }?.resume()
    }
}

/// One item's text on its way out: confirmed words as deltas while it is heard, then the
/// rest and the transcript once it is.
///
/// [LAW:types-are-the-program] Deltas are only ever the words after the ones already sent,
/// taken from `Partial.confirmed`, which the transcript begins with word for word; so the
/// deltas joined are the transcript's words, and a delta can never take back a word. Like
/// OpenAI's, the first delta keeps the leading space the completed transcript trims.
final class Deltas: Sendable {
    let item: String
    private let outbox: Outbox
    /// How far into the confirmed words the deltas have gone, and whether the item was let
    /// go, after which it sends nothing. Held across the send, so deltas leave in the order
    /// their words were heard.
    private let sent = Mutex((cursor: ConfirmedCursor(), letGo: false))

    init(item: String, outbox: Outbox) {
        self.item = item
        self.outbox = outbox
    }

    func heard(_ partial: Partial) {
        send(partial.confirmed.words)
    }

    /// The item is let go: it sends nothing more.
    func letGo() {
        sent.withLock { $0.letGo = true }
    }

    /// Answers the item, `seconds` of audio, with what it was heard as: the words not yet
    /// sent, then the transcript, or the reason there is none.
    func settle(_ transcription: Result<Transcription, any Error>, heard seconds: TimeInterval) async {
        do {
            let heard = try await Heard { try transcription.get() }
            send(heard.transcription.transcript.words)
            outbox.emit(.completed(item: item, heard: heard, usage: Usage(heard: seconds)))
        } catch TranscriptionFailure.vocabulary(let refusal) {
            outbox.emit(.failed(item: item, .promptRefused("\(refusal)")))
        } catch {
            outbox.emit(.failed(item: item, .engineFailed("\(error)")))
        }
    }

    private func send(_ words: [Transcript.Word]) {
        sent.withLock { sent in
            let new = sent.cursor.advance(through: words)
            guard !sent.letGo, !new.words.isEmpty else { return }
            outbox.emit(.delta(item: item, new.text))
        }
    }
}

/// Where every frame bound for the client is put, in order, until it is closed.
/// [LAW:single-enforcer] The one count of what the client has not yet been sent, which the
/// reader waits on, so a client's own events cannot grow it without bound.
final class Outbox: Sendable {
    /// The most bytes of frames left unsent before the reader waits for the client to read.
    /// Thousands of events, so a client that keeps up with its own never meets it.
    static let limit = 1 << 18

    /// Frames in the order they were put, each encoded once.
    let frames: AsyncStream<Queued>
    /// Held across each put and the close, so no frame can land after the last.
    private let state: Mutex<State>

    private struct State {
        let frames: AsyncStream<Queued>.Continuation
        var closed = false
        var unsent = 0
        var mostUnsent = 0
        var waits = 0
        /// The reader, while it waits for room.
        var waiter: CheckedContinuation<Void, Never>?

        /// Queues `queued` and counts it unsent, unless the outbox is closed.
        mutating func put(_ queued: Queued) {
            guard case .enqueued = frames.yield(queued) else { return }
            unsent += queued.bytes.count
            mostUnsent = max(mostUnsent, unsent)
        }
    }

    init() {
        let (frames, continuation) = AsyncStream<Queued>.makeStream()
        self.frames = frames
        state = Mutex(State(frames: continuation))
    }

    func emit(_ event: ServerEvent) {
        put(.event(event))
    }

    /// `frame` bound for the client, or dropped once the outbox is closed.
    func put(_ frame: Outgoing) {
        let queued = Queued(frame)
        state.withLock { $0.put(queued) }
    }

    /// `bytes` of frames have gone to the client.
    func sent(_ bytes: Int) {
        state.withLock { state in
            state.unsent -= bytes
            return state.unsent <= Self.limit ? state.waiter.take() : nil
        }?.resume()
    }

    /// Returns once the frames left unsent are within the limit, or the outbox is closed.
    func room() async {
        await withCheckedContinuation { waiter in
            let ready = state.withLock { state in
                guard state.unsent > Self.limit, !state.closed else { return true }
                state.waits += 1
                state.waiter = waiter
                return false
            }
            if ready { waiter.resume() }
        }
    }

    /// `last` is the final frame sent; nothing put after it is.
    func close(_ last: Data?) {
        state.withLock { state in
            if let last { state.put(Queued(.control(last))) }
            state.frames.finish()
            state.closed = true
            return state.waiter.take()
        }?.resume()
    }

    /// The most bytes the client was left unsent at once, and how often the reader waited
    /// for it to read.
    var pressure: (mostUnsent: Int, waits: Int) {
        state.withLock { ($0.mostUnsent, $0.waits) }
    }
}

/// A frame in the outbox, with the bytes it goes out as.
struct Queued: Sendable {
    let frame: Outgoing
    let bytes: Data

    init(_ frame: Outgoing) {
        self.frame = frame
        bytes = frame.bytes
    }
}

/// A frame bound for the client.
enum Outgoing: Sendable {
    case event(ServerEvent)
    case control(Data)

    var bytes: Data {
        switch self {
        case .event(let event): WebSocket.frame(.text, event.json)
        case .control(let frame): frame
        }
    }
}

/// Everything known about one Realtime socket once it has ended: the Realtime half of
/// its `ServedRequest`. [LAW:nothing-unseen] Items opened less those completed, failed and
/// let go are the items the socket ended before answering.
public struct RealtimeActivity: Sendable, Codable, Equatable {
    public internal(set) var updates = 0
    public internal(set) var appends = 0
    /// Client events refused, by their error's code.
    public internal(set) var refusals: [String: Int] = [:]
    /// The most audio a refused append would have taken the socket's held audio to, in seconds.
    public internal(set) var refusedAudioSeconds: Double?
    public internal(set) var items = 0
    /// The most the socket held at once, in seconds: the audio of items not yet heard and a
    /// second for each.
    public internal(set) var heldAudioSeconds: Double = 0
    /// The most items the socket held at once, each heard only after the one before it.
    public internal(set) var heldItems = 0
    /// Items that grew past their share of the socket uncommitted and started over, and the
    /// seconds of their oldest audio they let go.
    public internal(set) var itemsLetGo = 0
    public internal(set) var letGoAudioSeconds: Double = 0
    /// Seconds of audio in the items committed.
    public internal(set) var audioSeconds: Double = 0
    /// The close code the socket ended with, the client's or the server's.
    public internal(set) var closeCode: Int?
    /// How the client broke the protocol, when it did.
    public internal(set) var violation: String?
    public internal(set) var sent = Sent()
    /// The most bytes of frames the client was left unsent at once, and how often the
    /// reader stopped reading until it took them (backpressure).
    public internal(set) var mostUnsentBytes = 0
    public internal(set) var backpressureWaits = 0

    mutating func letGo(seconds: TimeInterval) {
        itemsLetGo += 1
        letGoAudioSeconds += seconds
    }

    /// [LAW:single-enforcer] The one place a refused client event's facts become the socket's.
    mutating func refused(_ refusal: RealtimeError) {
        refusals[refusal.code, default: 0] += 1
        if case .audioTooLong(let seconds, _) = refusal { refusedAudioSeconds = max(refusedAudioSeconds ?? 0, seconds) }
    }

    /// The server events that reached the socket, by kind.
    public struct Sent: Sendable, Codable, Equatable {
        public internal(set) var deltas = 0
        public internal(set) var completed = 0
        public internal(set) var failed = 0
        public internal(set) var errors = 0
        public internal(set) var other = 0
        /// Seconds of the completed items' quiet the engine was not handed.
        public internal(set) var quietSeconds: Double = 0
        /// The peak of the quietest tenth of a second any completed item held, the room their
        /// quiet was judged against, and seconds within range of an item's loudest that stood
        /// too near the room to be speech.
        public internal(set) var roomPeak: Double?
        public internal(set) var refusedAsRoomSeconds: Double = 0
        /// Bursts of sound in the completed items refused as too brief to be speech, and seconds the
        /// longest of them sounded.
        public internal(set) var transients = 0
        public internal(set) var longestTransientSeconds: Double = 0
        /// The loudest range any completed item's speech was judged against, the loudest sound
        /// above an item's range kept out of it as not speech, and the frames kept out in all.
        public internal(set) var rangePeak: Double?
        public internal(set) var keptOutPeak: Double?
        public internal(set) var keptOutFrames = 0
        /// Completed items refused as nothing spoken, answered as nothing said, and the loudest
        /// sample any of them held: how near the floor a quiet microphone came.
        public internal(set) var nothingSpoken = 0
        public internal(set) var nothingSpokenPeak: Double?

        mutating func count(_ frame: Outgoing) {
            guard case .event(let event) = frame else { return }
            switch event {
            case .delta: deltas += 1
            case .completed(_, let heard, _):
                completed += 1
                quietSeconds += heard.transcription.quiet.letGo
                roomPeak = [roomPeak, heard.transcription.quiet.room.map(Double.init)].compactMap { $0 }.min()
                refusedAsRoomSeconds += heard.transcription.quiet.refusedAsRoom
                transients += heard.transcription.quiet.transients.count
                longestTransientSeconds = max(longestTransientSeconds, heard.transcription.quiet.transients.longest)
                rangePeak = [rangePeak, heard.transcription.quiet.range.map(Double.init)].compactMap { $0 }.max()
                keptOutPeak = [keptOutPeak, heard.transcription.quiet.keptOut.map(Double.init)].compactMap { $0 }.max()
                keptOutFrames += heard.transcription.quiet.keptOutFrames
                if let peak = heard.nothingSpokenPeak {
                    nothingSpoken += 1
                    nothingSpokenPeak = max(nothingSpokenPeak ?? 0, Double(peak))
                }
            case .failed: failed += 1
            case .error: errors += 1
            case .sessionCreated, .sessionUpdated, .committed, .itemAdded, .itemDone: other += 1
            }
        }
    }
}

extension Reader {
    /// The client's next message, its fragments gathered by `assembler`.
    mutating func message(_ assembler: inout WebSocket.Assembler, limit: Int) async throws -> WebSocket.Message {
        while true {
            let frame = try await next { bytes throws(WebSocket.Violation) in try WebSocket.parse(bytes, limit: limit) }
            if let message = try assembler.take(frame, limit: limit) { return message }
        }
    }
}
