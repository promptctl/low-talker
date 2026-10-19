@testable import LowTalkerCore
import Foundation
import Testing

private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The speech gate replayed over the bench fixtures and what is done to them: transients
/// inserted, background talk mixed under them, rooms of every level, a tap left open. Each
/// case is one row of what the real `Utterance` hands its last pass, written to
/// $GATE_REPLAY_OUT; scripts/gate-replay/report reads those rows against master's
/// (scripts/gate-replay/baseline.tsv). `make gate-replay` runs the two. The gate under test
/// is the one in the tree, through the API every caller uses, so the same rows come from
/// master, from a change to the gate, or from any commit whose `Utterance` takes clips.
@Suite struct GateReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GATE_REPLAY_OUT"] != nil, "make gate-replay runs it"))
    func replay() async throws {
        let environment = ProcessInfo.processInfo.environment
        let out = try #require(environment["GATE_REPLAY_OUT"])
        let esc50 = try #require(environment["GATE_REPLAY_ESC50"], "GATE_REPLAY_ESC50 names the folder scripts/gate-replay/fetch-esc50 fills")
        let fixtures = try Fixtures(bench: repository.appendingPathComponent("bench"), esc50: URL(fileURLWithPath: esc50))
        try #require(!fixtures.transients.isEmpty, "no ESC-50 clips under \(esc50)")
        let rows = await Self.measure(fixtures.cases)
        try (rows.sorted().joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// Every case's row, measured as many at a time as there are cores: each utterance is
    /// its own actor, and nothing passes between cases.
    static func measure(_ cases: [Case]) async -> [String] {
        await withTaskGroup(of: String.self) { group in
            var rows: [String] = []
            var pending = cases[...]
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                guard let next = pending.popFirst() else { break }
                group.addTask { await next.row() }
            }
            for await row in group {
                rows.append(row)
                if let next = pending.popFirst() { group.addTask { await next.row() } }
            }
            return rows
        }
    }
}

/// White noise, the same samples every run: a linear congruential generator.
struct Noise {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1
    }

    /// `count` samples of noise peaking at `level`.
    static func samples(_ count: Int, at level: Float) -> [Float] {
        var noise = Noise()
        return (0..<count).map { _ in noise.next() * level }
    }
}

/// One signal through the gate: what it is (`key=value` fields, the row's first column),
/// how to make it, and the stretch inserted into it, which the windows it is measured in
/// leave out so they line up with the same signal without it.
struct Case: Sendable {
    let id: String
    let inserted: Range<Int>?
    let signal: @Sendable () -> [Float]

    /// The window a row's windows are counted in: a hundredth of a second.
    static let window = 160

    /// The id, the count and FNV-1a hash of the samples the last pass is handed, and the
    /// windows of the signal they came from, as runs `first-last` (inclusive), or `-`.
    func row() async -> String {
        let utterance = Utterance()
        for clip in AudioClip(samples: signal()).chunks(of: 0.01) {
            await utterance.append(clip)
        }
        await utterance.end()
        let (handed, arrived, _, timeline) = await utterance.audio(beyond: 0)
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for sample in handed {
            hash = (hash ^ UInt64(sample.bitPattern)) &* 0x100_0000_01B3
        }
        let windows = Self.runs(sourceWindows(arrived: arrived, timeline: timeline))
        return [id, String(handed.count), String(hash, radix: 16), windows].joined(separator: "\t")
    }

    /// The windows of the signal holding a handed sample. Kept samples run on unbroken between
    /// the quiet let go, so a hundredth of them whose ends lie a hundredth apart in the audio
    /// appended is one stretch of it; one that straddles quiet let go is placed sample by sample.
    private func sourceWindows(arrived: Int, timeline: Timeline) -> Set<Int> {
        func appended(_ kept: Int) -> Int {
            AudioClip.sampleCount(for: timeline.place(AudioClip.duration(for: kept)))
        }
        var windows = Set<Int>()
        for start in stride(from: 0, to: arrived, by: Self.window) {
            let end = min(start + Self.window, arrived) - 1
            let (first, last) = (appended(start), appended(end))
            let stretches = last - first == end - start ? [first...last] : (start...end).map { appended($0)...appended($0) }
            for stretch in stretches {
                windows.formUnion(source(stretch))
            }
        }
        return windows
    }

    /// The windows of the signal a stretch of the audio appended covers, the inserted stretch cut out.
    private func source(_ stretch: ClosedRange<Int>) -> [Int] {
        let cut = inserted ?? Int.max..<Int.max
        // The part before the inserted stretch, and the part after it moved back by its length.
        let parts = [
            (stretch.lowerBound, min(stretch.upperBound, cut.lowerBound - 1), 0),
            (max(stretch.lowerBound, cut.upperBound), stretch.upperBound, cut.count),
        ]
        return parts.filter { $0.0 <= $0.1 }.flatMap { low, high, shift in
            Array(((low - shift) / Self.window)...((high - shift) / Self.window))
        }
    }

    static func runs(_ windows: Set<Int>) -> String {
        var runs: [String] = []
        var first: Int?
        let sorted = windows.sorted()
        for (index, window) in sorted.enumerated() {
            first = first ?? window
            if index + 1 == sorted.count || sorted[index + 1] != window + 1 {
                runs.append("\(first!)-\(window)")
                first = nil
            }
        }
        return runs.isEmpty ? "-" : runs.joined(separator: ",")
    }
}

/// The audio the cases are made of, and the cases.
struct Fixtures {
    /// Bench fixtures by `folder/name`.
    let speech: [(name: String, samples: [Float])]
    /// ESC-50 clips by `category/name`, each its loudest half second scaled to peak at 0.9.
    let transients: [(name: String, samples: [Float])]

    static let rate = Int(AudioClip.sampleRate)
    /// A room at -51 and -35 dBFS: an M2 Max's built-in microphone in a quiet room, and a loud one.
    static let quietRoom: Float = 0.00282
    static let loudRoom: Float = 0.0178
    /// A speaker 20 dB down: the bench's soft reader.
    static let soft: Float = 0.1
    /// Room before the speech in a whole press, 0.5 s.
    static let lead = 8_000
    /// A white-noise burst: 0.15 s at 0.9. Bursts in a run are 0.25 s apart.
    static let burst = Noise.samples(2_400, at: 0.9).map { $0 >= 0 ? Float(0.9) : -0.9 }
    static let gap = 4_000

    init(bench: URL, esc50: URL) throws {
        func wavs(_ folder: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func named(_ url: URL) -> String {
            url.deletingLastPathComponent().lastPathComponent + "/" + url.deletingPathExtension().lastPathComponent
        }
        let folders = { (root: URL) in
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        speech = try folders(bench).flatMap(wavs).map { (name: named($0), samples: try AudioClip(contentsOf: $0).samples) }
        transients = try folders(esc50).flatMap(wavs).map { url in
            let clip = try AudioClip(contentsOf: url).samples
            let loudest = clip.indices.max { abs(clip[$0]) < abs(clip[$1]) } ?? 0
            let from = max(0, min(loudest - 1_600, clip.count - 8_000))
            let segment = Array(clip[from..<min(clip.count, from + 8_000)])
            let scale = 0.9 / (segment.map { abs($0) }.max() ?? 1)
            return (name: named(url), samples: segment.map { $0 * scale })
        }
    }

    /// The fixture from the first tenth of a second that reaches -40 dBFS.
    static func fromFirstSound(_ samples: [Float]) -> [Float] {
        let opening = stride(from: 0, to: samples.count, by: 1_600).first { samples[$0..<min($0 + 1_600, samples.count)].contains { abs($0) >= 0.01 } } ?? 0
        return Array(samples[opening...])
    }

    var readers: [(name: String, samples: [Float])] { speech.filter { $0.name.hasPrefix("librispeech/") } }
    var shortPresses: [(name: String, samples: [Float])] { speech.filter { $0.name.hasPrefix("say/") } }

    var cases: [Case] { bench + transientCases + talk + tap }

    /// Every fixture at 0 and -20 dB, whole and from its first sound, clean and in a quiet
    /// and a loud room.
    var bench: [Case] {
        speech.flatMap { name, samples in
            [("0", Float(1)), ("-20", Self.soft)].flatMap { level, gain in
                [("whole", samples), ("trimmed", Self.fromFirstSound(samples))].flatMap { trim, base in
                    [("clean", Float(0)), ("-51", Self.quietRoom), ("-35", Self.loudRoom)].map { room, noise in
                        Case(id: "family=bench fixture=\(name) level=\(level) trim=\(trim) room=\(room)", inserted: nil) {
                            zip(base, Noise.samples(base.count, at: noise)).map { $0 * gain + $1 }
                        }
                    }
                }
            }
        }
    }

    /// A soft reader with a stretch inserted: none, white-noise bursts, ESC-50 clips, or as
    /// much digital silence as either, the control for the frame boundaries an insert moves.
    /// Trimmed fixtures open on their first sound and take the stretch at 0 and 1 s; whole
    /// ones open on half a second of room and take it at 0.5, 1.5 and 3.5 s. ESC-50 clips go
    /// in 1 s into each reader, whole, in a quiet room.
    var transientCases: [Case] {
        func soft(_ name: String, _ samples: [Float], shape: String, room: (String, Float)) -> (key: String, audio: [Float], ats: [Int]) {
            let base = shape == "trimmed" ? Self.fromFirstSound(samples) : Array(repeating: 0, count: Self.lead) + samples
            let ats = shape == "trimmed" ? [0, Self.rate] : [Self.lead, Self.lead + Self.rate, Self.lead + 3 * Self.rate]
            let audio = zip(base, Noise.samples(base.count, at: room.1)).map { $0 * Self.soft + $1 }
            return ("fixture=\(name) shape=\(shape) room=\(room.0)", audio, ats.filter { $0 < audio.count })
        }
        func run(_ burst: [Float], _ count: Int) -> [Float] {
            (0..<count).flatMap { index in burst + (index + 1 < count ? Array(repeating: 0, count: Self.gap) : []) }
        }
        func inserting(_ key: String, _ audio: [Float], at: Int, source: String, runs: Int, _ stretch: [Float]) -> [Case] {
            let id = "family=transient \(key) at=\(at) runs=\(runs) length=\(stretch.count)"
            let silence = [Float](repeating: 0, count: stretch.count)
            return [(source, stretch), ("silence", silence)].map { source, stretch in
                Case(id: "\(id) source=\(source)", inserted: at..<at + stretch.count) {
                    Array(audio[..<at]) + stretch + Array(audio[at...])
                }
            }
        }
        let sources = speech.flatMap { name, samples in
            ["trimmed", "whole"].flatMap { shape in
                [("clean", Float(0)), ("-51", Self.quietRoom)].map { soft(name, samples, shape: shape, room: $0) }
            }
        }
        let alone = sources.map { key, audio, _ in Case(id: "family=transient \(key) source=none", inserted: nil) { audio } }
        let bursts = sources.flatMap { key, audio, ats in
            ats.flatMap { at in [1, 3, 5].flatMap { inserting(key, audio, at: at, source: "noise", runs: $0, run(Self.burst, $0)) } }
        }
        let clips = readers.flatMap { name, samples in
            let (key, audio, _) = soft(name, samples, shape: "whole", room: ("-51", Self.quietRoom))
            return transients.flatMap { clip, segment in
                [1, 3, 5].flatMap { inserting(key, audio, at: Self.lead + Self.rate, source: clip, runs: $0, run(segment, $0)) }
            }
        }
        // Every reader takes every clip at one place, so the silence beside a run of clips is
        // one case per reader and run length.
        var seen = Set<String>()
        return alone + bursts + clips.filter { seen.insert($0.id).inserted }
    }

    /// Background talk under a speaker, at -24, -27, -30 and -36 dB under the speaker's peak,
    /// after half a second of quiet room: a long press, each reader with the next one talking
    /// from the start to 3 s past its end, and a short one, each `say` fixture with a reader
    /// starting 0.3 s after it and talking for 3 s.
    var talk: [Case] {
        let readers = readers
        func mixed(_ press: String, _ index: Int, _ speaker: (name: String, samples: [Float]), talkFrom: (Int) -> Int) -> [Case] {
            let talker = readers[index % readers.count]
            let speakerPeak = speaker.samples.map(abs).max() ?? 0, talkerPeak = talker.samples.map(abs).max() ?? 1
            let start = talkFrom(speaker.samples.count)
            let length = Self.lead + speaker.samples.count + 3 * Self.rate + (press == "short" ? 4_800 : 0)
            return [-24, -27, -30, -36].map { db in
                let gain = speakerPeak * Float(pow(10, Double(db) / 20)) / talkerPeak
                return Case(id: "family=talk press=\(press) fixture=\(speaker.name) under=\(talker.name) db=\(db)", inserted: nil) {
                    let room = Noise.samples(length, at: Self.quietRoom)
                    return (0..<length).map { n in
                        let said = n >= Self.lead && n - Self.lead < speaker.samples.count ? speaker.samples[n - Self.lead] : 0
                        let talked = n >= start ? talker.samples[(n - start) % talker.samples.count] * gain : 0
                        return said + talked + room[n]
                    }
                }
            }
        }
        return readers.enumerated().flatMap { index, reader in mixed("long", index + 1, reader) { _ in 0 } }
            + shortPresses.enumerated().flatMap { index, press in mixed("short", index, press) { Self.lead + $0 + 4_800 } }
    }

    /// A tap left open: each fixture, then 10 s of room, at -51 to -35 dBFS.
    var tap: [Case] {
        speech.flatMap { name, samples in
            [-51, -45, -41, -38, -35].map { db in
                Case(id: "family=tap fixture=\(name) room=\(db)", inserted: nil) {
                    let audio = samples + Array(repeating: 0, count: 10 * Self.rate)
                    return zip(audio, Noise.samples(audio.count, at: Float(pow(10, Double(db) / 20)))).map(+)
                }
            }
        }
    }
}
