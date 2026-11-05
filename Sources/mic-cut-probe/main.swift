import Foundation

/// Drives a real `AudioCapture` through what a Mac does to a microphone mid-press, against
/// the real hardware, and says whether the press kept the speech said after it. Built for
/// low-reliability-z2z.csw, where the HAL audio unit stalled CoreAudio for seconds when its
/// device was destroyed; it is the driver the checkpoint low-reliability-z2z.01v runs on
/// studious.
///
///     mic-cut-probe cut        destroy the device the press is open on; the loopback is the
///                              default straight after
///     mic-cut-probe lag        the same, with the loopback becoming the default 1.5 s later
///     mic-cut-probe fallback   the microphone is the default between: reports what the press
///                              hears there rather than judging it
///     mic-cut-probe open       what opening a prepared microphone costs, per device
///     mic-cut-probe rate       change the loopback's sample rate mid-press
///
/// Needs the terminal's microphone permission, BlackHole 2ch (or another loopback named with
/// `--loopback`) to say the speech into, and changes the system default input while it runs.
/// Options: `--mic <name>` (default: the built-in microphone), `--loopback <name>`.
/// Exits nonzero when a check fails.
@MainActor
func run() async -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }
    let microphoneName = option("--mic")
    let loopbackName = option("--loopback") ?? "BlackHole 2ch"
    guard let mode = arguments.first, ["cut", "lag", "fallback", "open", "rate"].contains(mode) else {
        print("usage: mic-cut-probe cut|lag|fallback|open|rate [--mic <name>] [--loopback <name>]")
        return 2
    }
    do {
        let microphone = try microphoneName.map(Devices.named) ?? Devices.builtIn()
        let loopback = try Devices.named(loopbackName)
        let probe = Probe(microphone: microphone, loopback: loopback)
        probe.log("microphone \"\(Devices.name(microphone))\", loopback \"\(Devices.name(loopback))\"")
        switch mode {
        case "cut": try await Scenarios.cut(probe, lagSeconds: 0)
        case "lag": try await Scenarios.cut(probe, lagSeconds: 1.5)
        case "fallback": try await Scenarios.fallback(probe)
        case "open": try await Scenarios.open(probe)
        default: try await Scenarios.rate(probe)
        }
        probe.capture.stop()
        probe.log(probe.failures == 0 ? "all checks passed" : "\(probe.failures) check(s) failed")
        return probe.failures == 0 ? 0 : 1
    } catch {
        print("mic-cut-probe could not run: \(error)")
        return 2
    }
}

setvbuf(stdout, nil, _IONBF, 0)
exit(await run())
