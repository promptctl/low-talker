import AVFoundation
import CoreAudio
import Synchronization

/// The microphone, reached through CoreAudio's HAL audio unit.
///
/// AVAudioEngine is the obvious way to do this and it is the slower one: building an
/// engine and starting it is paid from the key going down, and more for the first one in a
/// process. Keeping one engine alive across presses does not fix it either: its starts
/// vary, and the device stayed running after `stop()`, which lights the menu-bar indicator
/// on a Mac nobody is dictating to - the exact thing `shut` exists to prevent.
///
/// The same device through a HAL unit opens quickly and goes dark on every stop.
/// What makes that possible is the split this type is named for: the expensive part of
/// reaching a microphone is per-process and is spent in `AudioComponentInstanceNew` and
/// `AudioUnitInitialize`, and neither of them opens a device.
/// Only `AudioOutputUnitStart` does. So an app that prepares while it is idle leaves a
/// press paying only the opening, and shows no indicator for the preparing.
///
/// That last sentence is a claim about a unit bound to a microphone, and it is false of one
/// bound to anything carrying an output - which is what CoreAudio hands an app that enables
/// input too early. `Reach` is written in the order that avoids it and then reads back
/// whether the device is running, so the split is proven on each preparation rather than
/// believed from this paragraph.
///
/// Idle is not the same as nobody waiting, though, and the reaching is done off the main
/// actor. A device change readies again from inside a CoreAudio notification, and the main
/// actor that notification lands on is the one a key-down handler needs next: a readying
/// there made the key wait for it, and a run of notifications made it wait for each. So `init`
/// hands the reaching to one serial queue and returns, and the one moment anything waits for
/// it is `open` - a press that came for this input before it was ready, which pays whatever
/// of it is left rather than the whole of it. Measured for low-privacy-o1z.68i on a loaded
/// Mac: a warm readying held the main thread, and handing the same work to the queue
/// returned at once.
///
/// [LAW:effects-at-boundaries] Every CoreAudio call in the capture path is here, behind
/// `PreparedInput`, so the state machine in `AudioCapture` runs in tests against hardware
/// a test controls and on a CI machine with no microphone at all.
@MainActor
final class HALInput: PreparedInput {
    /// What the render callback reaches, and the only things touched on the IO thread.
    ///
    /// A class because the callback is a C function pointer that cannot capture: it is
    /// handed this by address, which is also why it must outlive every render, and why
    /// the unit is stopped before it is let go. [LAW:no-ambient-temporal-coupling]
    ///
    /// The IO thread renders under a hard deadline, so what it does here is render into memory
    /// the press allocated and copy the slice into the press's ring - no allocation, and no
    /// waiting on a lock. Converting and handing over is `SliceDelivery`'s, on a thread of its
    /// own.
    private final class Sink: @unchecked Sendable {
        /// The delivery thread's while a press runs, and the main actor's in `begin` once the
        /// last press's delivery has finished.
        nonisolated(unsafe) let converter: AudioClip.Converter
        nonisolated(unsafe) var unit: AudioUnit?
        /// The press the unit is rendering for, and nil between presses. A render only ever
        /// tries this lock, and renders nothing when the main actor holds it to begin or end a
        /// press. So a press is never let go under a render - not even one a stop that failed
        /// left running - and the IO thread never waits. [LAW:no-ambient-temporal-coupling]
        private let press = Mutex<Press?>(nil)

        struct Press {
            let rendered: RenderBuffer
            let delivery: SliceDelivery
        }

        init(converter: AudioClip.Converter) {
            self.converter = converter
        }

        /// Ends whatever press is on the sink, then begins `make`'s. A press is its own stream:
        /// the resampler starts from nothing rather than carrying the previous press's tail
        /// into the head of this one, and it is reset only once that press's delivery thread,
        /// which converts with it, has ended. [LAW:one-source-of-truth]
        func begin(_ make: () throws -> Press) rethrows {
            end()
            converter.reset()
            let new = try make()
            press.withLock { $0 = new }
        }

        /// Lets the press go: what it rendered is handed over, and the converter is free for
        /// the next.
        func end() {
            press.withLock { $0.take() }?.delivery.finish()
        }

        deinit { end() }

        /// What CoreAudio calls on its own IO thread, as the C function pointer the unit
        /// takes. Reaches the sink it was handed the address of, and nothing else.
        ///
        /// It lives on the sink rather than inside `Reach.init` because a closure takes
        /// the isolation of the context it was formed in: one written in a `@MainActor`
        /// member is inferred main-actor-isolated, and converting that to a C function
        /// pointer leaves a runtime isolation check in the thunk which traps the first time
        /// CoreAudio calls it - on the IO thread, which is the only thread that ever
        /// calls it. A press died on its first buffer and the crash named this closure.
        /// Nothing about a render is the main actor's, and this is where the type says so
        /// rather than leaving it to where the lines happen to sit.
        /// [LAW:no-ambient-temporal-coupling]
        static let callback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<Sink>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
        }

        /// One device slice: rendered into the press's memory and pushed to its delivery,
        /// stamped as CoreAudio stamped it.
        func render(
            flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
            timeStamp: UnsafePointer<AudioTimeStamp>,
            bus: UInt32,
            frames: UInt32
        ) -> OSStatus {
            press.withLockIfAvailable { press -> OSStatus in
                guard let unit, let press else { return noErr }
                // A device that asks for more than the buffer holds would overrun it; refusing
                // is the loud version of that. The buffer holds the largest slice the device
                // offered when the press opened, so what reaches this is a device whose range
                // grew during the press. [LAW:no-silent-failure]
                guard Int(frames) <= press.rendered.frameCapacity else {
                    press.delivery.deliver(.overlongSlice(frames: Int(frames), capacity: press.rendered.frameCapacity))
                    return kAudio_ParamError
                }
                press.rendered.offer(Int(frames))
                let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, press.rendered.list.unsafeMutablePointer)
                guard status == noErr else {
                    press.delivery.deliver(.renderFailed(status))
                    return status
                }
                press.delivery.deliver(press.rendered.list, frames: Int(frames), stamp: timeStamp.pointee)
                return noErr
            } ?? noErr
        }
    }

    /// What a render fills: one non-interleaved float buffer per channel, in memory this owns
    /// rather than an `AVAudioPCMBuffer`'s. That one's buffer list is an Objective-C property
    /// that recomputes every byte size from the frame length each time it is read, which is
    /// both a message send on the IO thread and the trap that once had every press's first
    /// render refused with -50: sizes written into the list were overwritten by the next read.
    private final class RenderBuffer: @unchecked Sendable {
        let list: UnsafeMutableAudioBufferListPointer
        let frameCapacity: Int
        private let storage: [UnsafeMutablePointer<Float>]

        init(channels: Int, frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: channels)
            frameCapacity = frames
            storage = (0..<channels).map { _ in
                let channel = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                channel.initialize(repeating: 0, count: frames)
                return channel
            }
        }

        /// Points each buffer at its channel and says how much of it the next render may
        /// fill. [LAW:one-source-of-truth] The list is derived from the storage and the frame
        /// count on every render, so nothing a previous render left in it is read.
        func offer(_ frames: Int) {
            for (index, channel) in zip(list.indices, storage) {
                list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.size), mData: channel)
            }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    /// A microphone reached: the unit, the device binding, the format and the converter, all
    /// the way to `AudioUnitInitialize`, with the device read back as not running. Everything
    /// a press should not have to pay for, and everything that has to be given back.
    ///
    /// Isolated to nothing, because it is made on the readying queue and can be let go of
    /// there too: an input replaced while its reaching was under way is dropped by the queue
    /// when that reaching finishes. Nothing in it needs a particular thread - the CoreAudio
    /// calls are safe from any, the watches reach the main actor whoever registered them,
    /// and giving them back from the queue while the main thread waits on it cannot hang,
    /// because a removal waits on `listen`'s own queue and never on main.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// [LAW:types-are-the-program] exception: `@unchecked` because an `AudioUnit` is a
    /// pointer the compiler cannot vouch for. What makes the sharing sound is that nothing
    /// here is written after `init` returns: the queue makes it, one thread at a time holds
    /// what `Elsewhere` hands back, and the unit's own calls are CoreAudio's to serialize.
    private final class Reach: @unchecked Sendable {
        let unit: AudioUnit
        let sink: Sink
        /// What the unit hands a render, and so what each press's buffer is allocated in.
        let format: AVAudioFormat
        /// The device this was prepared against. A prepared input is bound to one device, so
        /// a default-input change is answered by preparing another rather than by re-pointing
        /// this one. [LAW:one-source-of-truth] `AudioCapture` is the one place that knows the
        /// device changed, and asking it for a fresh input is how that knowledge arrives here.
        let device: AudioObjectID
        /// That device and the format it delivers in, named while readying rather than at the
        /// press, so the press's record costs the press nothing.
        let input: MicrophoneInput
        /// Listeners on the bound device, held for as long as this is - which is as long as
        /// the binding they watch. They were a press's once, and the stretch that left
        /// unwatched is what low-privacy-o1z.aa1 was.
        private let watches: [@Sendable () -> Void]

        /// Binds a unit to `requested` and takes it as far as it goes without opening the
        /// device. No device is opened here, and macOS lights no indicator for it.
        init(binding requested: AudioObjectID, onStale: @escaping @MainActor () -> Void) throws {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw AudioHardwareError.noInputComponent
            }
            var instance: AudioUnit?
            try AudioHardwareError.check(AudioComponentInstanceNew(component, &instance), AudioHardwareError.componentUnavailable)
            guard let unit = instance else { throw AudioHardwareError.componentUnavailable(noErr) }

            // Everything below configures `unit` through locals, and the stored properties are
            // assigned only once the last throwing call has succeeded. Swift runs a class's
            // `deinit` for a throwing initializer only when every stored property was already
            // assigned, so deferring them keeps "init threw" and "deinit ran" mutually
            // exclusive: the catch here is the one place a preparation gives its unit back, and
            // it cannot double-free one `deinit` is also about to take. Assigning as we went
            // leaked a component per attempt instead. [LAW:single-enforcer]
            let device: AudioObjectID
            let sink: Sink
            let format: AVAudioFormat
            // Appended one at a time below, and read by the catch, so a second registration that
            // throws still leaves the first one disposable.
            var registered: [@Sendable () -> Void] = []
            do {
                // Output off, then the input device, then input on. The order is load-bearing
                // and nothing here shows it, so it is written down.
                //
                // A HAL unit is born pointing at the default *output* device, which has no
                // input. Enabling input while it points there asks CoreAudio to capture from a
                // device that cannot, and it answers by building this process a private
                // aggregate of the default output and the default input, binding the unit to
                // that, and handing the same aggregate back to anything that asks for the
                // default input afterwards. An aggregate carrying an output runs from
                // `AudioUnitInitialize`, so preparing took the device: LowTalker.app lit the
                // menu-bar indicator at launch and held it for as long as it ran. Bound to the
                // microphone first, the unit never sits in the state that provokes the swap.
                //
                // Only an app meets it - CoreAudio builds that aggregate for clients it offers
                // voice isolation to - so a command-line check read dark on the very code the
                // app was lighting the menu bar with, and the suite, which never builds the
                // app target, read nothing at all. The check after `AudioUnitInitialize` is
                // what makes the next difference of that shape fail rather than ship.
                var disable: UInt32 = 0
                try AudioHardwareError.check(
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                    AudioHardwareError.inputUnavailable
                )

                var binding = requested
                try AudioHardwareError.check(
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &binding, UInt32(MemoryLayout<AudioObjectID>.size)),
                    AudioHardwareError.inputUnavailable
                )

                // Input on bus 1: this unit captures and never plays.
                var enable: UInt32 = 1
                try AudioHardwareError.check(
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, HALInput.inputBus, &enable, UInt32(MemoryLayout<UInt32>.size)),
                    AudioHardwareError.inputUnavailable
                )

                // What the device delivers, which decides what the converter converts from.
                var source = AudioStreamBasicDescription()
                var sourceSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                try AudioHardwareError.check(
                    AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, HALInput.inputBus, &source, &sourceSize),
                    AudioHardwareError.inputUnavailable
                )
                // Float samples, one buffer per channel: the shape `AudioClip.Converter` reads and
                // the shape a render can be pointed at channel by channel. The unit converts the
                // device's own encoding into it, so nothing here has to know what that was.
                var client = AudioStreamBasicDescription(
                    mSampleRate: source.mSampleRate,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                    mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                    mFramesPerPacket: 1,
                    mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                    mChannelsPerFrame: source.mChannelsPerFrame,
                    mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
                    mReserved: 0
                )
                try AudioHardwareError.check(
                    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, HALInput.inputBus, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                    AudioHardwareError.inputUnavailable
                )
                guard let described = AVAudioFormat(streamDescription: &client) else {
                    throw AudioClipError.unconvertibleFormat(sampleRate: client.mSampleRate, channels: client.mChannelsPerFrame)
                }
                format = described

                let built = Sink(converter: try AudioClip.Converter(from: format))
                built.unit = unit

                var callback = AURenderCallbackStruct(
                    inputProc: Sink.callback,
                    inputProcRefCon: Unmanaged.passUnretained(built).toOpaque()
                )
                try AudioHardwareError.check(
                    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                    AudioHardwareError.inputUnavailable
                )

                // The last of the per-process cost, and still no device open.
                try AudioHardwareError.check(AudioUnitInitialize(unit), AudioHardwareError.inputUnavailable)

                // Which device the unit came out of initialization bound to, which is
                // CoreAudio's answer and not the one we asked for. It has answered differently
                // once already - the aggregate above - and a unit swapped onto one would leave
                // both of the things below pointed at a device the unit no longer uses: the
                // watches listening to it for changes, and the guard asking it whether the
                // preparation took a microphone. [FRAMING:representation]
                device = try HALInput.boundDevice(unit)

                // This unit is bound to one device, so a device that goes away or changes shape
                // under it is capture's cue to ready another against whatever replaced it. Both
                // watches live here rather than in `open()` because what they watch is the
                // binding, and the binding lasts as long as this input: registered at the press
                // they left the resting stretch between presses unwatched, and a device that
                // renegotiated its format there was heard by nobody. See
                // `AudioHardware.prepareInput` for what that cost. A switch of which device is
                // the *default* leaves both of these quiet and is `AudioCapture`'s to see.
                //
                // Ahead of the guard below, so the claim that a listener costs no device is made
                // the same way every other claim about preparing is: by reading the device back.
                // Registering one should not run a device, and this is the line that would fail
                // the preparation rather than trust it.
                registered.append(try HALInput.watch(device, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, onStale))
                registered.append(try HALInput.watch(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput, onStale))

                // [LAW:parse-dont-validate] The border between a microphone reached and a
                // microphone taken. Everything above claims to cross it without opening a
                // device, and the epic's whole promise rests on that claim, so this is where a
                // `Reach` becomes one: the type exists only for a unit whose device is not
                // running on this process's account.
                //
                // Read rather than believed because the claim is about CoreAudio, which is free
                // to change its mind between releases, between devices and - as the aggregate
                // above proved - between an app and a command line running the same lines. A
                // preparation that opened the device throws here and the unwind below gives the
                // device back; what the user is left with is a press that says there is no
                // microphone, rather than an indicator lit all day over an app reporting a shut
                // one. [LAW:no-silent-failure]
                guard try !HALInput.isRunning(device) else { throw AudioHardwareError.preparingOpenedTheDevice(device) }
                sink = built
            } catch {
                registered.forEach { $0() }
                HALInput.discard(unit)
                throw error
            }

            self.unit = unit
            self.device = device
            self.sink = sink
            self.format = format
            self.watches = registered
            input = MicrophoneInput(device: device, name: Result { () throws(AudioHardwareError) in try HALInput.name(of: device) }, sampleRate: format.sampleRate, channels: Int(format.channelCount))
        }

        /// What a press renders into and hands its audio over through: a buffer that holds the
        /// largest slice the device can hand this unit, and a ring with room for `backlog` of
        /// slices on their way to the pipeline.
        ///
        /// Sized by the device rather than by the unit, and at the press rather than at the
        /// preparation, because both of the other answers were measured wrong on this Mac for
        /// low-privacy-o1z.c0p. Moving the device's IO buffer to a larger size under a
        /// prepared, stopped unit handed the next press slices of that size, and a buffer sized
        /// when the input was readied refused every one of them: the press heard nothing. The
        /// unit's `kAudioUnitProperty_MaximumFramesPerSlice` does follow the device, but on
        /// CoreAudio's schedule rather than this one's - read straight after the move it
        /// answered the old size on some runs and the new one on others. [LAW:no-ambient-temporal-coupling]
        /// The device's own range bounds every size it can be moved to, so no move of the size
        /// can outgrow it and nothing has to have caught up for it to be true. Its smallest
        /// size is what bounds how many slices the ring's frames can be split into.
        ///
        /// Allocated on every open rather than kept and grown, so there is no earlier size for
        /// this to be compared with. [LAW:one-source-of-truth] What that adds to a press was
        /// measured the same day: negligible beside what the open itself costs.
        func press(
            appending: @escaping @Sendable ([Float], HostTime) -> Void,
            onFailure: @escaping @Sendable (any Error) -> Void
        ) throws -> Sink.Press {
            var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
            var size = UInt32(MemoryLayout<AudioValueRange>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try AudioHardwareError.check(
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range),
                AudioHardwareError.inputUnavailable
            )
            let slice = Int(range.mMaximum)
            let frames = max(2 * slice, Int(format.sampleRate * HALInput.backlog))
            let channels = Int(format.channelCount)
            return Sink.Press(
                rendered: RenderBuffer(channels: channels, frames: slice),
                delivery: try SliceDelivery(
                    SliceRing(channels: channels, frames: frames, entries: frames / max(Int(range.mMinimum), 1) + 1),
                    slice: slice,
                    format: format,
                    converter: sink.converter,
                    appending: appending,
                    onFailure: onFailure
                )
            )
        }

        /// Gives the device back and leaves the unit prepared, so the next press opens it at
        /// the prepared price, and answers whether the microphone actually went dark - the fact
        /// the epic promises, and the one only a caller holding a press can act on.
        /// [LAW:single-enforcer] Every way a press stops comes through here, including the
        /// one an `open()` that failed partway takes.
        ///
        /// Both steps are idempotent - stopping a stopped unit and ending a sink with no press do
        /// nothing - so this needs no flag saying whether the device is open. It had one, and
        /// because it was set only after a successful start, it made this a no-op on exactly the
        /// path that had something to unwind. [LAW:polishing-by-subtraction]
        ///
        /// What it does not do is drop the device watches. They belong to the binding rather
        /// than to the press, and a key-up that took them down is what left an idle microphone
        /// unwatched.
        func close() -> Bool {
            let stopped = AudioOutputUnitStop(unit)
            // After the stop, so what the last render pushed is handed over before the delivery
            // ends rather than dropped on the floor.
            sink.end()
            // [LAW:parse-dont-validate] The border `init`'s guard stands on, walked the other
            // way: that one proves reaching a microphone took no device, this one proves
            // letting go gave it back.
            //
            // The device is read rather than the status trusted because the failure this is
            // named for returns `noErr` - the `AVAudioEngine` this type replaced stopped
            // without complaint and left the device running, which the class doc records as the
            // reason `shut` could not be built on it. A status says whether CoreAudio accepted
            // the call; only the device says whether the microphone is still on.
            //
            // Both halves were read off this Mac for low-privacy-o1z.pr2, where the vocabulary
            // had been guessed rather than measured. Across presses the device read dark the
            // instant `AudioOutputUnitStop` returned, at a cost far under that call's own,
            // which is what makes the reading affordable here rather than owed to a later beat.
            // A device destroyed under a running unit answers every teardown call `noErr` and
            // this property `'who?'`: a microphone that has gone away cannot say it went dark,
            // and that is this input's last press either way, so the unreadable arm is an
            // answer to return rather than an error to raise. [LAW:no-silent-failure]
            return stopped == noErr && (try? HALInput.isRunning(device)) == false
        }

        /// The unit is stopped before the sink it renders into is let go, because a render
        /// already under way holds a pointer to it - `discard` stops first, and the sink goes
        /// with the stored properties after this returns.
        ///
        /// The one place the watches are given back other than the catch in `init`, and the
        /// two cannot both run: a throwing initializer reaches `deinit` only once every stored
        /// property is assigned, which is the line after that catch can no longer be taken.
        /// [LAW:single-enforcer] per path, which is what the unit already relies on.
        deinit {
            watches.forEach { $0() }
            HALInput.discard(unit)
        }
    }

    /// Where every microphone is reached, one at a time. Serial so that a run of readyings
    /// coalesces: one replaced before its turn is skipped - see `Elsewhere` - and a press
    /// that comes for the newest waits behind at most the one already under way.
    private static let readying = DispatchQueue(label: "ai.promptctl.low-talker.readying", qos: .userInitiated)

    /// The device readying was asked to bind, read on the main actor when this was made. A
    /// property read rather than a readying, so it costs the main actor nothing to take, and
    /// it is what says which device this input is for while the reaching is still under way.
    private let asked: Result<AudioObjectID, any Error>
    private let reach: Elsewhere<Reach>
    /// That this input has stopped being one to open. Held as well as handed to the watches
    /// because the device going away is not the only way that becomes true: a press whose
    /// microphone would not go dark ends on an input nothing should open again either, and
    /// `AudioCapture` answers both the same way - ready another. [LAW:single-enforcer]
    private let onStale: @MainActor () -> Void
    /// How many presses have opened this input. What a report about a press carries, so a
    /// report can tell whether it is still about the press that raised it.
    /// [LAW:no-ambient-temporal-coupling] The window it closes is real and narrow: under
    /// `shut` a key-up leaves this input prepared and `AudioCapture.preparations` unmoved,
    /// so a report that outlived its own press and was keyed only by preparation would
    /// match the *next* press on this same input and take a healthy engine down mid-word.
    private var presses = 0

    /// Starts readying a microphone against whatever the default input is now, and returns
    /// without waiting for it. A default that cannot be read is carried to the press the same
    /// way a readying that failed is: `open` throws it. [LAW:no-silent-failure]
    init(onStale: @escaping @MainActor () -> Void) {
        let asked = Result { try Self.defaultInput() }
        self.asked = asked
        reach = Elsewhere(on: Self.readying) { try Reach(binding: asked.get(), onStale: onStale) }
        self.onStale = onStale    }

    /// The device this input is bound to, once readying has bound one.
    var device: AudioObjectID {
        get throws { try reach.result().get().device }
    }

    func waitUntilReadied() async {
        // What it came to is read again by `open`, which is where a failure is reported.
        await reach.wait()
    }

    /// Opens the device. What a press pays - and, for a press that came before readying
    /// finished, whatever of the readying is left.
    func open(
        appending: @escaping @Sendable ([Float], HostTime) -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) throws -> OpenedInput {
        let reached = try reach.result().get()
        presses += 1
        let press = presses
        do {
            try reached.sink.begin {
                try reached.press(
                    appending: appending,
                    // The delivery thread does not wait for the main actor, so the report is
                    // posted rather than made. [LAW:no-ambient-temporal-coupling]
                    onFailure: { error in Task { @MainActor in onFailure(error) } }
                )
            }
            try AudioHardwareError.check(AudioOutputUnitStart(reached.unit), AudioHardwareError.inputUnavailable)
        } catch {
            endPress(press, on: reached)
            throw error
        }
        // `unowned` because this input holds the reach for as long as it lives, and a disposal
        // that outlived the input is one whose `self` is already gone - so the reach is read
        // exactly when it is still there, and holding it here would keep a unit this input had
        // let go of. [LAW:one-source-of-truth] The input is what owns the unit's lifetime.
        return OpenedInput(dispose: { [weak self, unowned reached] in self?.endPress(press, on: reached) }, input: reached.input)
    }

    /// Ends a press, whether it ran or never started, and gives the input up when the
    /// microphone cannot be shown to have gone dark.
    ///
    /// [LAW:dataflow-not-control-flow] Both ways a press ends run this same step, and the
    /// reading decides what follows rather than which path got here. A start that threw
    /// used to skip it on the grounds that it had opened no device - measured for the
    /// review of PR #55, that is not true of a device swapped out from under a prepared
    /// unit: `AudioOutputUnitStart` against one destroyed underneath returns `noErr` and
    /// lights the real default input instead.
    private func endPress(_ press: Int, on reached: Reach) {
        guard !reached.close() else { return }
        // The press ended and the microphone cannot be shown to be off. Nothing here can
        // put it out - the unit that would not stop is the one this input is built on - so
        // the input is given up instead: `AudioCapture` readies another, lets this one go,
        // and the reach's `deinit` that follows uninitializes and disposes the unit, which is
        // what finally takes the device off this process. An indicator lit between presses is
        // the whole of what `shut` exists to prevent, so it costs the input rather than
        // being dropped. [LAW:no-silent-failure]
        //
        // Posted rather than called: this runs inside `AudioCapture.dispose`, which every
        // transition reaches while holding its `Started` `inout`, and a report landing in
        // the middle of one would read a phase that has not been written back yet.
        //
        // What the post carries is the press, because arriving late is not the same as
        // arriving harmless. `AudioCapture.preparations` does not move at a key-up that
        // leaves this input prepared, so a report keyed only by preparation would still
        // match after the *next* press opened on this very input - and `inputWentStale`
        // would replace that healthy engine mid-word. A press that opened in between took
        // the device deliberately and answers for itself at its own key-up, which runs this
        // same reading, so dropping the older report loses nothing.
        Task { @MainActor [weak self] in
            guard let self, self.presses == press else { return }
            self.onStale()
        }
    }

    /// The device this input is bound to: CoreAudio's answer once readying has one, and until
    /// then the device readying was asked to bind. Nothing for an input readying could not
    /// reach, which is bound to no device at all.
    private var binding: AudioObjectID? {
        switch reach.finished {
        case .success(let reached)?: reached.device
        case .failure?: nil
        case nil: try? asked.get()
        }
    }

    /// Compared against the device the unit is bound to rather than the one it was asked for,
    /// for the reason `Reach.device` is: the binding is CoreAudio's answer. While readying is
    /// under way there is no answer yet, and the device it was asked for stands in: a
    /// default-input change that lands then is about that device, and a run of notifications
    /// for one change would otherwise ready once per notification. [LAW:one-source-of-truth]
    ///
    /// [LAW:no-silent-failure] exception: a default that cannot be read answers `false` rather
    /// than throwing. What that sends capture to do is ready another input, and readying reads
    /// the same property again and carries its failure to the press that opens it - so the
    /// error is not dropped. It is reported where a press can hear it.
    var isOnTheDefaultInput: Bool {
        binding.map { (try? Self.defaultInput()) == $0 } ?? false
    }

    /// Which device a press would open.
    static func defaultInput() throws -> AudioObjectID {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            AudioHardwareError.noDefaultInput
        )
        guard device != kAudioObjectUnknown else { throw AudioHardwareError.noDefaultInput(noErr) }
        return device
    }

    /// The scope is the caller's because it is the property's, not this function's:
    /// `kAudioObjectPropertyScopeGlobal` is a scope like any other rather than a wildcard,
    /// and a listener whose address names a different scope than the notification is
    /// published on is never called. Registering an input device's stream format globally
    /// succeeds and then hears nothing, which is the quietest way this could be wrong.
    ///
    /// Static, with the device passed in, so nothing a listener holds is an input. CoreAudio
    /// keeps the block until it is removed, which is now for the whole life of the input
    /// rather than the length of a press, and a block that captured `self` would keep that
    /// input alive past the last reference to it - with its unit, and with `deinit` never
    /// reached to give either back.
    nonisolated static func watch(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ onChange: @escaping @MainActor () -> Void) throws -> @Sendable () -> Void {
        let remove = try listen(
            to: AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain),
            on: device,
            refused: AudioHardwareError.deviceWatchFailed,
            onChange
        )
        return {
            let status = remove()
            // The two statuses tolerated here were read off this Mac for low-audio-fr3. On
            // a live device a removal answers `noErr`, matched or not. Once a device is torn
            // down, as a destroyed aggregate device was, a removal answers
            // `kAudioHardwareBadObjectError`, whether its block was registered, removed
            // already, or never added.
            //
            // A precondition where the stop in `close()` is a report, and the two are one
            // judgment rather than two: what an unremoved listener leaves behind is already
            // guarded, since `inputWentStale` discards by preparation number anything a
            // stale watch says. So a status nobody has seen costs nothing here and is worth
            // hearing about, while a stop that fails costs the user a lit microphone - dear
            // enough to spend the input on, and far too dear to spend the session on.
            precondition(
                status == noErr || status == kAudioHardwareBadObjectError,
                "CoreAudio refused to remove a listener it added (status \(status))"
            )
        }
    }

    /// Whether *this process* has `device` running.
    ///
    /// `kAudioDevicePropertyDeviceIsRunning` answers for the asking process alone, where
    /// `...IsRunningSomewhere`, which the menu-bar indicator follows, answers for the whole
    /// Mac. Measured on this Mac with a second process holding the microphone: this reads
    /// 0 and the indicator reads 1. That difference is what lets preparing prove it took no
    /// device while a call, a recording or another app's capture is running - a
    /// check on the indicator would refuse to ready a microphone because something else was
    /// using one. [FRAMING:representation] Two properties, two questions, and this is the
    /// one about us.
    private nonisolated static func isRunning(_ device: AudioObjectID) throws -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running),
            AudioHardwareError.runningStateUnreadable
        )
        return running != 0
    }

    /// The name macOS shows for `device`.
    private nonisolated static func name(of device: AudioObjectID) throws(AudioHardwareError) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioHardwareError.check(
            withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) },
            AudioHardwareError.nameUnreadable
        )
        guard let name else { throw .nameUnreadable(noErr) }
        return name.takeRetainedValue() as String
    }

    /// Which device `unit` is bound to, asked of the unit rather than remembered from what
    /// it was told.
    private nonisolated static func boundDevice(_ unit: AudioUnit) throws -> AudioObjectID {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try AudioHardwareError.check(
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size),
            AudioHardwareError.inputUnavailable
        )
        return device
    }

    /// Gives back everything a unit holds, in the order CoreAudio pairs them.
    /// [LAW:single-enforcer] Both ways a unit ends come through here - a `Reach` being
    /// let go, and a preparation giving up partway - so the two cannot drift apart on how
    /// much of a unit there is to give back. The guard after `AudioUnitInitialize` is why
    /// that matters: it lets a preparation throw holding a fully initialized unit, which
    /// until then only `deinit` ever had.
    ///
    /// Every step is unconditional, because each is a no-op on a unit that never got that
    /// far - measured for low-privacy-o1z.pr2 rather than assumed: on a unit that never
    /// reached `AudioUnitInitialize`, on one prepared and never opened, and on a second
    /// pass over a unit already stopped and already uninitialized, all three calls answer
    /// `noErr`. [LAW:dataflow-not-control-flow]
    ///
    /// [LAW:no-silent-failure] exception: these three statuses are dropped, and unlike the
    /// stop in `close()` there is nothing better to read instead. Both paths here have no
    /// caller to tell - `deinit`, and an `init` already throwing a truer error than a
    /// teardown status - and no harm to report either, because what the epic cares about is
    /// whether the device came back, and `AudioComponentInstanceDispose` takes it back by
    /// existing: the unit that held it is gone. That is also what makes `close()`'s report
    /// worth making and this one not. A prepared input that would not stop keeps the
    /// device across presses; a disposed one cannot keep anything.
    private nonisolated static func discard(_ unit: AudioUnit) {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private nonisolated static let inputBus: UInt32 = 1

    /// How far a press's delivery thread may fall behind the device before audio is dropped.
    /// It waits on nothing longer than the main actor copying one session out of the ring, so
    /// this is far more than it needs, and it costs memory only while a press is open.
    private nonisolated static let backlog: TimeInterval = 2
}
