import CoreAudio
import Foundation

/// The CoreAudio calls the scenarios make to change the world under a press: find devices,
/// make an aggregate, destroy it, say which device is the default, change a rate. Each
/// answers or says why it could not, because a scenario that failed to set itself up has
/// proved nothing about capture.
enum Devices {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func all() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw Failure(description: "could not size the device list (status \(status))") }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else { throw Failure(description: "could not read the device list (status \(status))") }
        return ids
    }

    static func defaultInput() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &value)
        guard status == noErr else { throw Failure(description: "could not read the default input (status \(status))") }
        return value
    }

    static func nominalRate(_ device: AudioObjectID) throws -> Float64 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw Failure(description: "could not read \(name(device))'s rate (status \(status))") }
        return value
    }

    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func name(_ device: AudioObjectID) -> String { string(device, kAudioObjectPropertyName) }
    static func uid(_ device: AudioObjectID) -> String { string(device, kAudioDevicePropertyDeviceUID) }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func named(_ wanted: String) throws -> AudioObjectID {
        let devices = try all()
        guard let found = devices.first(where: { name($0) == wanted && hasInput($0) }) else {
            let have = devices.filter(hasInput).map(name).joined(separator: ", ")
            throw Failure(description: "no input device named \"\(wanted)\"; the inputs here are: \(have)")
        }
        return found
    }

    /// The built-in microphone when none is named: the one input a Mac always has.
    static func builtIn() throws -> AudioObjectID {
        guard let found = try all().first(where: { hasInput($0) && uid($0).contains("BuiltIn") }) else {
            throw Failure(description: "no built-in microphone; name one with --mic")
        }
        return found
    }

    static func setDefaultInput(_ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw Failure(description: "could not make device \(device) the default input (status \(status))") }
    }

    static let aggregateName = "mic-cut-probe-aggregate"

    /// A public aggregate over `device`, which stays until it is destroyed - a private one
    /// would go with this process, and the scenarios destroy it mid-press on purpose.
    static func makeAggregate(over device: AudioObjectID) throws -> AudioObjectID {
        for leftover in try all() where name(leftover) == aggregateName { AudioHardwareDestroyAggregateDevice(leftover) }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: "\(aggregateName)-uid",
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid(device)]],
            kAudioAggregateDeviceMasterSubDeviceKey: uid(device),
        ]
        var aggregate = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw Failure(description: "could not make an aggregate device (status \(status))") }
        return aggregate
    }

    static func destroy(_ aggregate: AudioObjectID) throws {
        let status = AudioHardwareDestroyAggregateDevice(aggregate)
        guard status == noErr else { throw Failure(description: "could not destroy the aggregate device (status \(status))") }
    }

    static func setNominalRate(_ device: AudioObjectID, to rate: Float64) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { throw Failure(description: "could not set \(name(device)) to \(rate) Hz (status \(status))") }
    }

    /// Plays `text` into `loopback` and returns when it has been said.
    static func say(_ text: String, into loopback: AudioObjectID) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-a", "\(loopback)", text]
        // The handler is set before the process runs: one that exits at once would otherwise be
        // gone before anything was waiting for it.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
