import CoreAudio
import Foundation
import Grants
import LowTalkerCore

/// One run of the real `AudioCapture` against the real hardware, with a clock and a log of
/// what capture said, so a scenario reads what happened rather than what it hoped.
@MainActor
final class Probe {
    let microphone: AudioObjectID
    let loopback: AudioObjectID
    let capture: AudioCapture
    private let epoch = ContinuousClock.now
    private(set) var reports: [(at: Double, text: String)] = []
    private(set) var failures = 0

    init(microphone: AudioObjectID, loopback: AudioObjectID) {
        self.microphone = microphone
        self.loopback = loopback
        let box = ReportBox()
        capture = AudioCapture { box.take($0) }
        box.probe = self
    }

    /// Seconds since this run began.
    func now() -> Double { Self.seconds(ContinuousClock.now - epoch) }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    func log(_ line: String) { print(String(format: "[%6.2f] ", now()) + line) }

    fileprivate func record(_ report: CaptureReport) {
        reports.append((now(), "\(report)"))
        log("capture: \(report)")
    }

    /// When capture last said it relaunched, or nil.
    func lastRelaunch(after moment: Double) -> Double? {
        reports.last { $0.at >= moment && $0.text.contains("relaunched the microphone") }?.at
    }

    func check(_ passed: Bool, _ what: String) {
        log((passed ? "pass: " : "FAIL: ") + what)
        if !passed { failures += 1 }
    }

    func start() async throws {
        let grant: MicrophoneGrant
        do { grant = try MicrophonePermission().current.grant() } catch { throw Devices.Failure(description: "this process has no microphone access: \(error)") }
        try await capture.start(grant, atRest: .shut)
    }

    /// One press: `during` runs while the session is open, then the press ends.
    struct Heard {
        let seconds: Double
        let elapsed: Double
        let peak: Float
        let lost: String?
        let firstSample: Duration?
    }

    func press(_ label: String, during: () async throws -> Void) async throws -> Heard {
        let session = try capture.beginSession(at: .now, preRoll: 0)
        let streamed = capture.stream(session)
        let began = ContinuousClock.now
        try await during()
        let elapsed = Self.seconds(ContinuousClock.now - began)
        let ending = capture.endSession(streamed)
        let reading = ending.reading
        let heard = Heard(
            seconds: AudioClip.duration(for: reading.samples),
            elapsed: elapsed,
            peak: reading.peak,
            lost: ending.lost.map { "\($0)" },
            firstSample: reading.firstSample
        )
        log("\(label): \(String(format: "%.2f", heard.seconds)) s of audio over \(String(format: "%.2f", heard.elapsed)) s, peak \(String(format: "%.3f", heard.peak))\(heard.lost.map { ", lost: \($0)" } ?? "")")
        return heard
    }

    func speak(seconds: Double = 4) async throws {
        try await Devices.say("one two three four five six seven eight nine", into: loopback)
    }
}

/// Capture's reports arrive on the main actor; this hands them to the probe without making
/// the probe's initializer wait on itself.
private final class ReportBox: @unchecked Sendable {
    @MainActor weak var probe: Probe?
    @MainActor func take(_ report: CaptureReport) { probe?.record(report) }
}

/// What a speech press is held to: speech was heard (a peak well above a quiet room's) and the
/// audio covers the press but for `allowance` seconds.
private let speechPeak: Float = 0.1

@MainActor
enum Scenarios {
    /// A press open on an aggregate over the microphone, destroyed mid-press. `lagSeconds`
    /// is how long the loopback takes to become the default after the destroy.
    ///
    /// Passes when the press carries the speech said after the cut, within the lag plus
    /// 0.3 s of the elapsed time - nothing can relaunch before a default exists - the relaunch is
    /// reported within 0.3 s of the default existing, the loss is reported as the microphone
    /// restarting, and the next plain press hears every word.
    static func cut(_ probe: Probe, lagSeconds: Double) async throws {
        try Devices.setDefaultInput(probe.loopback)
        try await probe.start()
        let before = try await probe.press("plain press, before") { try await probe.speak() }
        probe.check(before.peak > speechPeak && before.elapsed - before.seconds < 0.3, "a plain press hears the speech (the baseline)")

        let aggregate = try Devices.makeAggregate(over: probe.microphone)
        defer { try? Devices.destroy(aggregate) }
        try await Task.sleep(for: .seconds(1))
        try Devices.setDefaultInput(aggregate)
        try await Task.sleep(for: .seconds(1))

        var destroyedAt = 0.0
        let cut = try await probe.press("press cut by destroying its device") {
            try await Task.sleep(for: .seconds(1))
            destroyedAt = probe.now()
            try Devices.destroy(aggregate)
            if lagSeconds > 0 { try await Task.sleep(for: .seconds(lagSeconds)) }
            try Devices.setDefaultInput(probe.loopback)
            try await probe.speak()
        }
        probe.check(cut.peak > speechPeak, "the press carries the speech said after the cut")
        probe.check(cut.elapsed - cut.seconds < lagSeconds + 0.3, "the press lost no more than the lag plus 0.3 s (lost \(String(format: "%.2f", cut.elapsed - cut.seconds)) s of \(lagSeconds) + 0.3)")
        probe.check(cut.lost?.contains("restarted") == true, "the press reports that the microphone restarted")
        if let relaunched = probe.lastRelaunch(after: destroyedAt) {
            probe.check(relaunched - destroyedAt < 0.3 + lagSeconds, "capture relaunched \(String(format: "%.2f", relaunched - destroyedAt)) s after the destroy")
        } else {
            probe.check(false, "capture reported a relaunch after the destroy")
        }

        try await Task.sleep(for: .seconds(1))
        let after = try await probe.press("plain press, after") { try await probe.speak() }
        probe.check(after.peak > speechPeak && after.elapsed - after.seconds < 0.3, "the device the press fell back to hears the next press")
    }

    /// The loopback is not what the default was before the aggregate: macOS falls back to the
    /// microphone, capture relaunches there, and only then does the loopback become the
    /// default. A press stays on the device it is recording on when the default changes, by
    /// design, so it does not hear speech said into the loopback; this reports that rather
    /// than judging it, and judges the press after it.
    static func fallback(_ probe: Probe) async throws {
        try Devices.setDefaultInput(probe.loopback)
        try await probe.start()
        try Devices.setDefaultInput(probe.microphone)
        try await Task.sleep(for: .seconds(1))
        let aggregate = try Devices.makeAggregate(over: probe.microphone)
        defer { try? Devices.destroy(aggregate) }
        try await Task.sleep(for: .seconds(1))
        try Devices.setDefaultInput(aggregate)
        try await Task.sleep(for: .seconds(1))

        let cut = try await probe.press("press cut, fallback to the microphone, loopback 0.5 s later") {
            try await Task.sleep(for: .seconds(1))
            try Devices.destroy(aggregate)
            try await Task.sleep(for: .seconds(0.5))
            try Devices.setDefaultInput(probe.loopback)
            try await probe.speak()
        }
        probe.log("informational: peak \(String(format: "%.3f", cut.peak)) - below \(speechPeak) means the press stayed on the fallback device and did not hear the loopback")
        try await Task.sleep(for: .seconds(1))
        let after = try await probe.press("plain press, after") { try await probe.speak() }
        probe.check(after.peak > speechPeak, "the press after hears the loopback, now the default")
    }

    /// What opening a prepared, shut microphone costs, on each device: `beginSession`'s own
    /// time, and how long after the key the first sample was captured.
    static func open(_ probe: Probe) async throws {
        for device in [probe.loopback, probe.microphone] {
            try Devices.setDefaultInput(device)
            try await probe.start()
            var costs: [Double] = []
            var firsts: [Double] = []
            var partial = 0
            for _ in 0..<20 {
                let began = ContinuousClock.now
                let session = try probe.capture.beginSession(at: .now, preRoll: 0)
                costs.append(Probe.seconds(ContinuousClock.now - began) * 1000)
                let streamed = probe.capture.stream(session)
                try await Task.sleep(for: .milliseconds(300))
                let ending = probe.capture.endSession(streamed)
                if ending.lost != nil { partial += 1 }
                if let first = ending.reading.firstSample { firsts.append(Probe.seconds(first) * 1000) }
                try await Task.sleep(for: .milliseconds(200))
            }
            costs.sort()
            firsts.sort()
            let median = { (values: [Double]) in values.isEmpty ? Double.nan : values[values.count / 2] }
            probe.log("\(Devices.name(device)): open \(String(format: "%.1f", median(costs))) ms median (\(String(format: "%.1f", costs.first ?? 0))-\(String(format: "%.1f", costs.last ?? 0))); first sample \(String(format: "%.1f", median(firsts))) ms after the key; \(partial) of 20 presses partial")
            probe.check(partial == 0, "no press on \(Devices.name(device)) came back partial")
            probe.capture.stop()
        }
    }

    /// The loopback's sample rate changed mid-press: nothing in a buffer list says so, so the
    /// device's stream-format watch is what has to, and capture has to relaunch at the new rate.
    static func rate(_ probe: Probe) async throws {
        try Devices.setDefaultInput(probe.loopback)
        try await probe.start()
        defer { try? Devices.setNominalRate(probe.loopback, to: 48_000) }
        var changedAt = 0.0
        let heard = try await probe.press("press with the loopback's rate changed to 44.1 kHz") {
            try await Task.sleep(for: .seconds(1))
            changedAt = probe.now()
            try Devices.setNominalRate(probe.loopback, to: 44_100)
            try await probe.speak()
        }
        probe.check(probe.lastRelaunch(after: changedAt) != nil, "capture relaunched after the rate changed")
        probe.check(heard.lost?.contains("restarted") == true, "the press reports that the microphone restarted")
        probe.check(heard.peak > speechPeak, "the press carries the speech said after the rate changed")
        if let relaunched = probe.lastRelaunch(after: changedAt) {
            probe.check(relaunched - changedAt < 1, "capture relaunched \(String(format: "%.2f", relaunched - changedAt)) s after the rate changed")
        }
    }
}
