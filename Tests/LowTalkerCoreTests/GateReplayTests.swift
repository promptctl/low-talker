import Foundation
import Testing
@testable import LowTalkerCore

// Throwaway (low-reliability-z2z.b4b): replays the bench fixtures through the real gate and
// writes what a pass is handed to $GATE_REPLAY_OUT. Not to be committed.
@Suite struct GateReplayTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) & 0xFFFFF) / Float(0xFFFFF) * 2 - 1
        }
    }

    static func handed(_ samples: [Float]) async -> (count: Int, hash: UInt64, quiet: Quiet) {
        let utterance = Utterance()
        for start in stride(from: 0, to: samples.count, by: 160) {
            await utterance.append(AudioClip(samples: Array(samples[start..<min(start + 160, samples.count)])))
        }
        await utterance.end()
        let (handed, _, _, timeline) = await utterance.audio(beyond: 0)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for s in handed { hash = (hash ^ UInt64(s.bitPattern)) &* 0x100_0000_01b3 }
        return (handed.count, hash, timeline.quiet)
    }

    /// The 10 ms windows of the source (the audio without the knock) a pass is handed.
    static func windows(_ samples: [Float], knockAt: Int?, knockLength: Int = 3_200) async -> Set<Int> {
        let utterance = Utterance()
        for start in stride(from: 0, to: samples.count, by: 160) {
            await utterance.append(AudioClip(samples: Array(samples[start..<min(start + 160, samples.count)])))
        }
        await utterance.end()
        let (handed, arrived, _, timeline) = await utterance.audio(beyond: 0)
        var kept = Set<Int>()
        for k in stride(from: 0, to: min(handed.count, arrived), by: 160) {
            let appended = AudioClip.sampleCount(for: timeline.place(AudioClip.duration(for: k)))
            guard let knockAt else { kept.insert(appended / 160); continue }
            if appended < knockAt { kept.insert(appended / 160) } else if appended >= knockAt + knockLength { kept.insert((appended - knockLength) / 160) }
        }
        return kept
    }

    @Test func trace() async throws {
        guard let path = ProcessInfo.processInfo.environment["GATE_TRACE"] else { return }
        let x = try AudioClip(contentsOf: URL(fileURLWithPath: path)).samples
        let firstLoud = stride(from: 0, to: x.count, by: 1_600).first { x[$0..<min($0 + 1_600, x.count)].contains { abs($0) >= 0.01 } } ?? 0
        var noise = Noise()
        let knock = (0..<3_200).map { _ in noise.next() > 0 ? Float(0.9) : -0.9 }
        _ = firstLoud
        var roomNoise = Noise()
        let trimmed = ProcessInfo.processInfo.environment["GATE_TRACE_TRIM"] != nil
        let soft = trimmed ? x[firstLoud...].map { $0 * 0.1 } : (Array(repeating: Float(0), count: 8_000) + x).map { $0 * 0.1 + roomNoise.next() * 0.00282 }
        let at = trimmed ? 16_000 : 24_000
        _ = await Self.windows(Array(soft[..<at]) + knock + Array(soft[at...]), knockAt: at)
    }

    /// Voicing of every bench frame peaking within 24 dB of its file's loudest frame, and of noise bursts.
    @Test func voicingStats() async throws {
        guard let out = ProcessInfo.processInfo.environment["GATE_VOICING_OUT"] else { return }
        var lines: [String] = []
        let bench = Self.root.appendingPathComponent("bench")
        for dir in try FileManager.default.contentsOfDirectory(at: bench, includingPropertiesForKeys: nil) where dir.hasDirectoryPath {
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "wav" }) {
                let x = try AudioClip(contentsOf: file).samples
                let frames = stride(from: 0, to: x.count - 1_600, by: 1_600).map { Array(x[$0..<$0 + 1_600]) }
                let peaks = frames.map { $0.reduce(0) { max($0, abs($1)) } }
                let top = peaks.max() ?? 0
                for (frame, peak) in zip(frames, peaks) where peak >= top / 16 {
                    var noise = Noise()
                    let noisy = frame.map { $0 * 0.1 + noise.next() * 0.00282 }
                    lines.append("\(file.lastPathComponent)\t\(String(format: "%.3f", peak / top))\t\(String(format: "%.3f", Utterance.voicing(frame)))\t\(String(format: "%.3f", Utterance.voicing(noisy)))")
                }
            }
        }
        var noise = Noise()
        for _ in 0..<50 { lines.append("burst\t1\t\(String(format: "%.3f", Utterance.voicing((0..<1_600).map { _ in noise.next() * 0.9 })))\t-") }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// Real transients (ESC-50 clips under /tmp/b4b/esc): each clip's loudest 0.5 s, scaled to peak
    /// 0.9, inserted 1 s into each LibriSpeech fixture at -20 dB after 0.5 s of -51 dBFS room.
    /// Lost is speech master hands a pass without it and this gate does not with it, beyond
    /// what as much inserted silence loses.
    @Test func realTransients() async throws {
        guard let out = ProcessInfo.processInfo.environment["GATE_ESC_OUT"] else { return }
        let esc = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/tmp/b4b/esc"), includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let fixtures = try FileManager.default.contentsOfDirectory(at: Self.root.appendingPathComponent("bench/librispeech"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for clipURL in esc {
            let c = try AudioClip(contentsOf: clipURL).samples
            let loudestAt = c.indices.max { abs(c[$0]) < abs(c[$1]) } ?? 0
            let from = max(0, min(loudestAt - 1_600, c.count - 8_000))
            let segment = Array(c[from..<min(c.count, from + 8_000)])
            let scale = 0.9 / (segment.map { abs($0) }.max() ?? 1)
            let transient = segment.map { $0 * scale }
            let voiced = stride(from: 0, to: transient.count - 1_600, by: 1_600).map { Utterance.voicing(Array(transient[$0..<$0 + 1_600])) }.max() ?? 0
            var worst: (Double, String) = (0, "")
            for fixture in fixtures {
                var roomNoise = Noise()
                let soft = (Array(repeating: Float(0), count: 8_000) + (try AudioClip(contentsOf: fixture)).samples).map { $0 * 0.1 + roomNoise.next() * 0.00282 }
                let at = 24_000
                for (name, _) in flags { unsetenv(name) }
                let alone = await Self.windows(soft, knockAt: nil)
                for (name, value) in flags { if let value { setenv(name, value, 1) } }
                let with = await Self.windows(Array(soft[..<at]) + transient + Array(soft[at...]), knockAt: at, knockLength: transient.count)
                let silent = await Self.windows(Array(soft[..<at]) + Array(repeating: 0, count: transient.count) + Array(soft[at...]), knockAt: at, knockLength: transient.count)
                let excess = Double(alone.subtracting(with).count - alone.subtracting(silent).count) / 100
                if excess >= worst.0 { worst = (excess, fixture.lastPathComponent) }
            }
            lines.append("\(clipURL.lastPathComponent)\tvoicing \(String(format: "%.2f", voiced))\tworst lost beyond silence \(String(format: "%.2f", worst.0))s (\(worst.1))")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }

    @Test func replay() async throws {
        guard let out = ProcessInfo.processInfo.environment["GATE_REPLAY_OUT"] else { return }
        let bench = Self.root.appendingPathComponent("bench")
        var files: [URL] = []
        for dir in try FileManager.default.contentsOfDirectory(at: bench, includingPropertiesForKeys: nil) where dir.hasDirectoryPath {
            files += try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        }
        files += (ProcessInfo.processInfo.environment["GATE_REPLAY_EXTRA"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        var lines: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let x = try AudioClip(contentsOf: file).samples
            let firstLoud = stride(from: 0, to: x.count, by: 1_600).first { x[$0..<min($0 + 1_600, x.count)].contains { abs($0) >= 0.01 } } ?? 0
            for (level, gain) in [("0dB", Float(1)), ("-20dB", Float(0.1))] {
                for (trim, base) in [("full", x), ("trim", Array(x[firstLoud...]))] {
                    for (noiseName, noiseLevel) in [("clean", Float(0)), ("noise-51", Float(0.00282)), ("noise-35", Float(0.0178))] {
                        var noise = Noise()
                        let y = base.map { $0 * gain + noise.next() * noiseLevel }
                        if ProcessInfo.processInfo.environment["GATE_SUBSET"] != nil {
                            let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
                            for (name, _) in flags { unsetenv(name) }
                            let before = await Self.windows(y, knockAt: nil)
                            for (name, value) in flags { if let value { setenv(name, value, 1) } }
                            let after = await Self.windows(y, knockAt: nil)
                            let lost = before.subtracting(after).sorted(), added = after.subtracting(before).sorted()
                            if !lost.isEmpty || !added.isEmpty {
                                lines.append("SUBSET \(file.lastPathComponent)\t\(level)\t\(trim)\t\(noiseName)\tlost \(lost.count)0ms\tadded \(added.count)0ms at \(added.first.map { String(format: "%.2f", Double($0) / 100) } ?? "-")..\(added.last.map { String(format: "%.2f", Double($0) / 100) } ?? "-") of \(String(format: "%.2f", Double(y.count) / 16_000))")
                            }
                        }
                        let r = await Self.handed(y)
                        lines.append("\(file.lastPathComponent)\t\(level)\t\(trim)\t\(noiseName)\t\(r.count)\t\(String(r.hash, radix: 16))\t\(String(format: "%.2f", r.quiet.letGo))")
                    }
                }
            }
            // Speech, then 10 s of room left open, at several room levels.
            if ProcessInfo.processInfo.environment["GATE_SUBSET"] != nil, file.lastPathComponent == "greeting.wav" || file.lastPathComponent == "2277-149896-0000.wav" {
                for db in [-51, -45, -41, -38, -35] {
                    let level = Float(pow(10, Double(db) / 20))
                    var noise = Noise()
                    let y = (x + Array(repeating: 0, count: 160_000)).map { $0 + noise.next() * level }
                    let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
                    for (name, _) in flags { unsetenv(name) }
                    let before = await Self.windows(y, knockAt: nil)
                    for (name, value) in flags { if let value { setenv(name, value, 1) } }
                    let after = await Self.windows(y, knockAt: nil)
                    let tail = x.count / 160
                    lines.append("TAIL \(file.lastPathComponent)\t\(db) dBFS\tkept of the open room: master \(before.filter { $0 >= tail }.count)0ms, new \(after.filter { $0 >= tail }.count)0ms")
                }
            }
            // A knock of 0.2 s at 0.9 into the speech at -20 dB: trimmed (no room before it), and
            // whole after 0.5 s of room, clean and in -51 dBFS noise. Lost is against master's gate without the knock.
            var noise = Noise()
            let knock = (0..<3_200).map { _ in noise.next() > 0 ? Float(0.9) : -0.9 }
            let lead = 8_000
            for (shape, base, ats) in [("trim", Array(x[firstLoud...]), [0, 16_000]), ("room", Array(repeating: Float(0), count: lead) + x, [lead, lead + 16_000, lead + 48_000])] {
                for (noiseName, noiseLevel) in [("clean", Float(0)), ("noise-51", Float(0.00282))] {
                    var roomNoise = Noise()
                    let soft = base.map { $0 * 0.1 + roomNoise.next() * noiseLevel }
                    let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
                    for (name, _) in flags { unsetenv(name) }
                    let alone = await Self.windows(soft, knockAt: nil)
                    for (name, value) in flags { if let value { setenv(name, value, 1) } }
                    // n bursts of 0.15 s, 0.25 s apart, as one inserted stretch (a cough fit, claps, knocking),
                    // each beside as much digital silence, the frame-boundary control.
                    let fits = [1, 3, 5].map { n in (n, (0..<n).flatMap { i in Array(knock.prefix(2_400)) + (i + 1 < n ? Array(repeating: Float(0), count: 4_000) : []) }) }
                    for at in ats where at < soft.count {
                      for (kind, burst) in [("knock", knock)] + fits.flatMap({ n, fit in [("bursts\(n)", fit), ("silence\(n)", Array(repeating: Float(0), count: fit.count))] }) {
                        let with = await Self.windows(Array(soft[..<at]) + burst + Array(soft[at...]), knockAt: at, knockLength: burst.count)
                        let lost = alone.subtracting(with).sorted()
                        var ranges: [String] = []
                        var runStart = lost.first
                        for (i, w) in lost.enumerated() where i + 1 == lost.count || lost[i + 1] != w + 1 {
                            ranges.append(String(format: "%.2f-%.2f", Double(runStart!) / 100, Double(w + 1) / 100))
                            runStart = i + 1 < lost.count ? lost[i + 1] : nil
                        }
                        lines.append("\(file.lastPathComponent)\t\(kind)@\(String(format: "%.1f", Double(at) / 16_000))s\t\(shape)\t\(noiseName)\tlost \(Double(lost.count) / 100)s\tadded \(Double(with.subtracting(alone).count) / 100)s\t\(ranges.joined(separator: " "))")
                      }
                    }
                }
            }
        }
        // Background talk: another reader mixed under each LibriSpeech fixture, d dB under its peak,
        // through the fixture and 3 s past it, after 0.5 s of -51 dBFS room. Added is what the new
        // gate hands a pass that master's does not.
        let talkers = try files.filter { $0.path.contains("librispeech") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { try AudioClip(contentsOf: $0).samples }
        let names = files.filter { $0.path.contains("librispeech") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(\.lastPathComponent)
        for (i, a) in talkers.enumerated() {
            let b = talkers[(i + 1) % talkers.count]
            let aPeak = a.reduce(0) { max($0, abs($1)) }, bPeak = b.reduce(0) { max($0, abs($1)) }
            let length = 8_000 + a.count + 48_000
            for db in [-20, -24, -27, -30, -36] {
                let gain = aPeak * Float(pow(10, Double(db) / 20)) / bPeak
                var roomNoise = Noise()
                let y = (0..<length).map { n in
                    (n >= 8_000 && n - 8_000 < a.count ? a[n - 8_000] : 0) + b[n % b.count] * gain + roomNoise.next() * 0.00282
                }
                let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
                for (name, _) in flags { unsetenv(name) }
                let before = await Self.windows(y, knockAt: nil)
                for (name, value) in flags { if let value { setenv(name, value, 1) } }
                let after = await Self.windows(y, knockAt: nil)
                let tail = (8_000 + a.count) / 160
                lines.append("TALK \(names[i])\t\(db) dB\tmaster kept \(Double(before.count) / 100)s\tadded \(Double(after.subtracting(before).count) / 100)s (\(Double(after.subtracting(before).filter { $0 >= tail }.count) / 100)s past the speech)\tlost \(Double(before.subtracting(after).count) / 100)s")
            }
        }
        // Short presses: each say fixture after 0.5 s of -51 dBFS room, then a LibriSpeech reader
        // starting 0.3 s after it ends and talking for 3 s, d dB under the fixture's peak.
        let shorts = files.filter { $0.path.contains("/say/") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (i, file) in shorts.enumerated() {
            let a = try AudioClip(contentsOf: file).samples
            let b = talkers[i % talkers.count]
            let aPeak = a.reduce(0) { max($0, abs($1)) }, bPeak = b.reduce(0) { max($0, abs($1)) }
            let talkStart = 8_000 + a.count + 4_800
            for db in [-24, -27, -30, -36] {
                let gain = aPeak * Float(pow(10, Double(db) / 20)) / bPeak
                var roomNoise = Noise()
                let y = (0..<(talkStart + 48_000)).map { n in
                    (n >= 8_000 && n - 8_000 < a.count ? a[n - 8_000] : 0) + (n >= talkStart ? b[(n - talkStart) % b.count] * gain : 0) + roomNoise.next() * 0.00282
                }
                let flags = ["GATE_RELEASE", "GATE_FOLLOW", "GATE_FLOOR_SPLIT", "GATE_ROOM_FLOOR", "GATE_KTH", "GATE_EARLY", "GATE_VOICED"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
                for (name, _) in flags { unsetenv(name) }
                let before = await Self.windows(y, knockAt: nil)
                for (name, value) in flags { if let value { setenv(name, value, 1) } }
                let after = await Self.windows(y, knockAt: nil)
                let talk = talkStart / 160
                lines.append("SHORT \(file.lastPathComponent)\t\(db) dB\tmaster kept \(Double(before.filter { $0 >= talk }.count) / 100)s of the talk\tnew \(Double(after.filter { $0 >= talk }.count) / 100)s\tlost \(Double(before.subtracting(after).count) / 100)s")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["GATE_VOICING_LOG"] != nil {
            try Utterance.voicingLog.map { String(format: "%.4f\t%.3f", $0.0, $0.1) }.joined(separator: "\n").write(toFile: out + ".voicing", atomically: true, encoding: .utf8)
        }
    }
}
