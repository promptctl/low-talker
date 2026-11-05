import AVFoundation
import CoreAudio
import Synchronization

/// The microphone, reached through an IOProc on the CoreAudio input device itself.
///
/// AVAudioEngine is the obvious way to do this and it is the slower one: building an
/// engine and starting it is paid from the key going down, and more for the first one in a
/// process. Keeping one engine alive across presses does not fix it either: its starts
/// vary, and the device stayed running after `stop()`, which lights the menu-bar indicator
/// on a Mac nobody is dictating to - the exact thing `shut` exists to prevent.
///
/// The same device through an IOProc opens quickly and goes dark on every stop.
/// What makes that possible is the split this type is named for: reaching a microphone -
/// reading the shape of the device's input, building the converter, creating the IOProc -
/// is per-process work, and none of it opens a device. Only `AudioDeviceStart` does. So an
/// app that prepares while it is idle leaves a press paying only the opening, and shows no
/// indicator for the preparing. `Reach` reads back whether the device is running, so the
/// split is proven on each preparation rather than believed from this paragraph.
///
/// It is not reached through the HAL audio unit, which this once used. A unit whose device
/// is destroyed under it handles the death itself, inside this process's CoreAudio
/// notification dispatch: it starts the new default input and blocks that dispatch for two
/// to four seconds. The watch below was delivered that late, stopping the dead unit held the
/// main actor, and the replacement found the new default already running, so a press lost
/// everything said in the gap (low-reliability-z2z.csw, measured by destroying an aggregate
/// device mid-press). An IOProc on a destroyed device answers in microseconds. What the unit
/// did that an IOProc does not is convert: the HAL hands an IOProc the device's own float
/// buffers, so `InputLayout` is read once and every render is held to it.
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
    /// What the IOProc reaches, and the only things touched on the IO thread.
    ///
    /// A class because the block the IOProc runs holds it: it is handed to CoreAudio at
    /// readying and released by `AudioDeviceDestroyIOProcID`, and a destroy that fails (the
    /// device is gone) leaves the block holding it, so a call that arrives late finds a Sink
    /// whose press is nil and returns. [LAW:no-ambient-temporal-coupling]
    ///
    /// The IO thread runs under a hard deadline, so what it does here is check the buffer
    /// list's shape and copy it into the press's ring - no allocation, and no waiting on a
    /// lock. Converting and handing over is `SliceDelivery`'s, on a thread of its own.
    private final class Sink: @unchecked Sendable {
        /// The delivery thread's while a press runs, and the main actor's in `begin` once the
        /// last press's delivery has finished.
        nonisolated(unsafe) let converter: AudioClip.Converter
        /// The press the IOProc is delivering for, and nil between presses. A render only ever
        /// tries this lock, and delivers nothing when the main actor holds it to begin or end
        /// a press. So a press is never let go under a render - not even one a stop that
        /// failed left running - and the IO thread never waits. [LAW:no-ambient-temporal-coupling]
        private let press = Mutex<SliceDelivery?>(nil)

        init(converter: AudioClip.Converter) {
            self.converter = converter
        }

        /// Ends whatever press is on the sink, then begins `make`'s. A press is its own stream:
        /// the resampler starts from nothing rather than carrying the previous press's tail
        /// into the head of this one, and it is reset only once that press's delivery thread,
        /// which converts with it, has ended. [LAW:one-source-of-truth]
        func begin(_ make: () throws -> SliceDelivery) rethrows {
            end()
            converter.reset()
            let new = try make()
            press.withLock { $0 = new }
        }

        /// Lets the press go: what it rendered is handed over, and the converter is free for
        /// the next.
        func end() {
            press.withLock { $0.take() }?.finish()
        }

        deinit { end() }

        /// What CoreAudio runs on its IO thread for each cycle.
        ///
        /// Formed here, on a type that has no isolation, because a closure takes the
        /// isolation of the context it was formed in: one written in a `@MainActor` member is
        /// inferred main-actor-isolated, and the runtime isolation check in its thunk traps the
        /// first time CoreAudio calls it - on the IO thread, which is the only thread that ever
        /// calls it. A press once died on its first buffer and the crash named the closure.
        /// Nothing about a render is the main actor's, and this is where the type says so
        /// rather than leaving it to where the lines happen to sit. [LAW:no-ambient-temporal-coupling]
        func ioBlock() -> AudioDeviceIOBlock {
            { [self] _, input, inputTime, _, _ in
                _ = press.withLockIfAvailable { $0?.deliver(input, stamp: inputTime.pointee) }
            }
        }
    }

    /// A microphone reached: the device's input shape, the format and the converter, and the
    /// IOProc created against the device, with the device read back as not running. Everything
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
    /// [LAW:types-are-the-program] exception: `@unchecked` because an IOProc id is a
    /// pointer the compiler cannot vouch for. What makes the sharing sound is that nothing
    /// here is written after `init` returns: the queue makes it, one thread at a time holds
    /// what `Elsewhere` hands back, and the IOProc's own calls are CoreAudio's to serialize.
    private final class Reach: @unchecked Sendable {
        let sink: Sink
        /// What each press's ring and converter are built in: planar float at the device's
        /// rate, one channel per channel of the layout.
        let format: AVAudioFormat
        /// The shape of what the IOProc is handed, read when this was readied.
        let layout: InputLayout
        /// The device this was prepared against. A prepared input is bound to one device, so
        /// a default-input change is answered by preparing another rather than by re-pointing
        /// this one. [LAW:one-source-of-truth] `AudioCapture` is the one place that knows the
        /// device changed, and asking it for a fresh input is how that knowledge arrives here.
        let device: AudioObjectID
        /// That device and the format it delivers in, named while readying rather than at the
        /// press, so the press's record costs the press nothing.
        let input: MicrophoneInput
        /// What the IOProc's block runs on. Owned here so a stop can wait for a block already
        /// queued: one that landed after the stop would deliver the last press's tail into the
        /// next.
        private let queue: DispatchQueue
        private let procID: AudioDeviceIOProcID
        /// Listeners on the bound device, held for as long as this is - which is as long as
        /// the binding they watch. They were a press's once, and the stretch that left
        /// unwatched is what low-privacy-o1z.aa1 was.
        private let watches: [@Sendable () -> Void]

        /// Reads the device's input shape and creates the IOProc against it, without starting
        /// the device. No device is opened here, and macOS lights no indicator for it.
        init(binding device: AudioObjectID, onStale: @escaping @MainActor () -> Void) throws {
            // Everything below configures locals, and the stored properties are assigned only
            // once the last throwing call has succeeded. Swift runs a class's `deinit` for a
            // throwing initializer only when every stored property was already assigned, so
            // deferring them keeps "init threw" and "deinit ran" mutually exclusive: the catch
            // here is the one place a preparation gives its IOProc back, and it cannot
            // double-free one `deinit` is also about to take. [LAW:single-enforcer]
            let layout: InputLayout
            let sink: Sink
            let format: AVAudioFormat
            let queue = DispatchQueue(label: "ai.promptctl.low-talker.input-io", qos: .userInteractive)
            var created: AudioDeviceIOProcID?
            // Appended one at a time below, and read by the catch, so a second registration that
            // throws still leaves the first one disposable.
            var registered: [@Sendable () -> Void] = []
            do {
                layout = try HALInput.layout(of: device)

                // Float samples, one buffer per channel: the shape `AudioClip.Converter` reads
                // and the shape the ring is read back in. `SliceRing` makes it out of whatever
                // the layout's buffers are, so nothing here has to know how the device lays its
                // channels out.
                var client = AudioStreamBasicDescription(
                    mSampleRate: layout.sampleRate,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                    mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                    mFramesPerPacket: 1,
                    mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                    mChannelsPerFrame: UInt32(layout.channels),
                    mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
                    mReserved: 0
                )
                guard let described = AVAudioFormat(streamDescription: &client) else {
                    throw AudioClipError.unconvertibleFormat(sampleRate: client.mSampleRate, channels: client.mChannelsPerFrame)
                }
                format = described

                let built = Sink(converter: try AudioClip.Converter(from: format))
                try AudioHardwareError.check(
                    AudioDeviceCreateIOProcIDWithBlock(&created, device, queue, built.ioBlock()),
                    AudioHardwareError.inputUnavailable
                )

                // This IOProc is bound to one device, so a device that goes away or changes
                // shape under it is capture's cue to ready another against whatever replaced
                // it. Both watches live here rather than in `open()` because what they watch is
                // the binding, and the binding lasts as long as this input: registered at the
                // press they left the resting stretch between presses unwatched, and a device
                // that renegotiated its format there was heard by nobody. See
                // `AudioHardware.prepareInput` for what that cost. A switch of which device is
                // the *default* leaves both of these quiet and is `AudioCapture`'s to see.
                //
                // A rate change raises the stream-format notification too, measured by setting
                // BlackHole's nominal rate under a listener on each of the four properties it
                // could have been signalled on, so one watch covers shape and rate.
                //
                // Ahead of the guard below, so the claim that a listener costs no device is made
                // the same way every other claim about preparing is: by reading the device back.
                registered.append(try HALInput.watch(device, kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal, onStale))
                registered.append(try HALInput.watch(device, kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput, onStale))

                // [LAW:parse-dont-validate] The border between a microphone reached and a
                // microphone taken. Everything above claims to cross it without opening a
                // device, and the epic's whole promise rests on that claim, so this is where a
                // `Reach` becomes one: the type exists only for a device that is not running on
                // this process's account.
                //
                // Read rather than believed because the claim is about CoreAudio, which is free
                // to change its mind between releases, between devices and between an app and a
                // command line running the same lines. A preparation that opened the device
                // throws here and the unwind below gives it back; what the user is left with is
                // a press that says there is no microphone, rather than an indicator lit all day
                // over an app reporting a shut one. [LAW:no-silent-failure]
                guard try !HALInput.isRunning(device) else { throw AudioHardwareError.preparingOpenedTheDevice(device) }
                sink = built
            } catch {
                registered.forEach { $0() }
                if let created { HALInput.discard(created, on: device) }
                throw error
            }

            self.device = device
            self.sink = sink
            self.format = format
            self.layout = layout
            self.queue = queue
            self.procID = created!
            self.watches = registered
            input = MicrophoneInput(device: device, name: Result { () throws(AudioHardwareError) in try HALInput.name(of: device) }, sampleRate: format.sampleRate, channels: layout.channels)
        }

        /// What a press hands its audio over through: a delivery whose slices are as large as
        /// the largest the device can hand this IOProc, and a ring with room for `backlog` of
        /// slices on their way to the pipeline.
        ///
        /// Sized by the device at the press rather than at the preparation, because both of
        /// the other answers were measured wrong on this Mac for low-privacy-o1z.c0p. Moving
        /// the device's IO buffer to a larger size under a prepared, stopped input handed the
        /// next press slices of that size, and a buffer sized when the input was readied
        /// refused every one of them: the press heard nothing. The device's own range bounds
        /// every size it can be moved to, so no move of the size can outgrow it and nothing
        /// has to have caught up for it to be true. [LAW:no-ambient-temporal-coupling] Its
        /// smallest size is what bounds how many slices the ring's frames can be split into.
        ///
        /// Allocated on every open rather than kept and grown, so there is no earlier size for
        /// this to be compared with. [LAW:one-source-of-truth] What that adds to a press was
        /// measured the same day: negligible beside what the open itself costs.
        func press(
            appending: @escaping @Sendable ([Float], HostTime) -> Void,
            onFailure: @escaping @Sendable (any Error) -> Void
        ) throws -> SliceDelivery {
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
            return try SliceDelivery(
                SliceRing(channels: layout.channels, frames: frames, entries: frames / max(Int(range.mMinimum), 1) + 1),
                layout: layout,
                slice: slice,
                format: format,
                converter: sink.converter,
                appending: appending,
                onFailure: onFailure
            )
        }

        /// Starts the device. What a press pays.
        func start() throws {
            try AudioHardwareError.check(AudioDeviceStart(device, procID), AudioHardwareError.inputUnavailable)
        }

        /// Gives the device back and leaves the input prepared, so the next press opens it at
        /// the prepared price, and answers whether the microphone actually went dark - the fact
        /// the epic promises, and the one only a caller holding a press can act on.
        /// [LAW:single-enforcer] Every way a press stops comes through here, including the
        /// one an `open()` that failed partway takes.
        ///
        /// Every step is idempotent - stopping a stopped or never-started IOProc answers
        /// `noErr`, measured, and ending a sink with no press does nothing - so this needs no
        /// flag saying whether the device is open. It had one, and because it was set only
        /// after a successful start, it made this a no-op on exactly the path that had
        /// something to unwind. [LAW:polishing-by-subtraction]
        ///
        /// What it does not do is drop the device watches. They belong to the binding rather
        /// than to the press, and a key-up that took them down is what left an idle microphone
        /// unwatched.
        func close() -> Bool {
            let stopped = AudioDeviceStop(device, procID)
            // A block already queued when the stop landed runs after it, so wait for the queue:
            // what it pushes is handed over by `sink.end()` below instead of into the next press.
            queue.sync {}
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
            // A device that is gone answers the stop `!dev` and cannot say whether it is
            // running, so this is false for it, and `endPress` gives the input up: capture
            // readies another, which is the second way to a replacement beside the watch, and
            // the right one for a device that went away under a press nobody was told about.
            return stopped == noErr && (try? HALInput.isRunning(device)) == false
        }

        /// The IOProc is stopped before it is destroyed, and both before the sink it runs is
        /// let go - the block holds the sink, so the sink outlives a destroy that fails.
        ///
        /// The one place the watches are given back other than the catch in `init`, and the
        /// two cannot both run: a throwing initializer reaches `deinit` only once every stored
        /// property is assigned, which is the line after that catch can no longer be taken.
        /// [LAW:single-enforcer] per path, which is what the IOProc already relies on.
        deinit {
            watches.forEach { $0() }
            HALInput.discard(procID, on: device)
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
        self.onStale = onStale
    }

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
                    //
                    // A device that changed what it hands over under this press is not an
                    // engine failure: it is an input that stopped being one to open, so it
                    // takes the way out every other such input takes, and capture readies
                    // another and relaunches. Reported as a failure it would leave the engine
                    // failed, which a device report does not relaunch. Only that fault goes
                    // this way: one that the device never matched would be replaced into the
                    // same mismatch. [LAW:single-enforcer]
                    onFailure: { [weak self] error in
                        Task { @MainActor in
                            switch Self.route(of: error) {
                            case .replaceInput: self?.giveUp(press)
                            case .failPress: onFailure(error)
                            }
                        }
                    }
                )
            }
            try reached.start()
        } catch {
            endPress(press, on: reached)
            throw error
        }
        // `unowned` because this input holds the reach for as long as it lives, and a disposal
        // that outlived the input is one whose `self` is already gone - so the reach is read
        // exactly when it is still there, and holding it here would keep an IOProc this input had
        // let go of. [LAW:one-source-of-truth] The input is what owns the IOProc's lifetime.
        return OpenedInput(dispose: { [weak self, unowned reached] in self?.endPress(press, on: reached) }, input: reached.input)
    }

    /// Ends a press, whether it ran or never started, and gives the input up when the
    /// microphone cannot be shown to have gone dark.
    ///
    /// [LAW:dataflow-not-control-flow] Both ways a press ends run this same step, and the
    /// reading decides what follows rather than which path got here. A start that threw
    /// used to skip it on the grounds that it had opened no device - measured for the
    /// review of PR #55, that is not true of a device swapped out from under a prepared
    /// input: a start against one destroyed underneath answered `noErr` and lit the real
    /// default input instead, under the audio unit this once used.
    private func endPress(_ press: Int, on reached: Reach) {
        guard !reached.close() else { return }
        // The press ended and the microphone cannot be shown to be off. Nothing here can
        // put it out - the IOProc that would not stop is the one this input is built on - so
        // the input is given up instead: `AudioCapture` readies another, lets this one go,
        // and the reach's `deinit` that follows stops and destroys the IOProc, which is
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
        Task { @MainActor [weak self] in self?.giveUp(press) }
    }

    /// What a fault the delivery reports means for the input.
    enum FaultRoute: Equatable {
        /// This input stopped being one to open: ready another and relaunch.
        case replaceInput
        /// The press failed and nothing about the input says another would do better.
        case failPress
    }

    /// Only a shape that changed under a press that had matched it is the first: a device that
    /// renegotiated is replaced by readying it again. Every other fault, `shapeNeverMatched`
    /// included, fails the press, because readying again would read the same properties and
    /// mismatch the same way. [LAW:single-enforcer]
    nonisolated static func route(of error: any Error) -> FaultRoute {
        if case .inputShapeChanged? = error as? AudioHardwareError { .replaceInput } else { .failPress }
    }

    /// Tells capture this input is no longer one to open, if `press` is still the press it
    /// opened last. The one place that report is made, so a device that noticed and a press
    /// that noticed cannot disagree about whether it is still about the right press.
    /// [LAW:single-enforcer]
    private func giveUp(_ press: Int) {
        guard presses == press else { return }
        onStale()
    }

    /// The device this input is bound to: the one readying was asked to bind, once readying has
    /// it, and until then the same device read at the moment of asking. Nothing for an input
    /// readying could not reach, which is bound to no device at all.
    private var binding: AudioObjectID? {
        switch reach.finished {
        case .success(let reached)?: reached.device
        case .failure?: nil
        case nil: try? asked.get()
        }
    }

    /// Compared against the device this is bound to. While readying is under way there is no
    /// binding yet, and the device it was asked for stands in: a default-input change that
    /// lands then is about that device, and a run of notifications for one change would
    /// otherwise ready once per notification. [LAW:one-source-of-truth]
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
    /// input alive past the last reference to it - with its IOProc, and with `deinit` never
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

    /// The shape of what `device`'s IOProc will be handed, from the virtual format of each of
    /// its input streams - what the HAL presents to a client rather than what the hardware
    /// stores. Refused, naming the device, when it is a shape nothing here can read.
    /// [LAW:parse-dont-validate]
    private nonisolated static func layout(of device: AudioObjectID) throws -> InputLayout {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        try AudioHardwareError.check(AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize), AudioHardwareError.inputUnavailable)
        var streams = [AudioObjectID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioObjectID>.size)
        try AudioHardwareError.check(AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams), AudioHardwareError.inputUnavailable)

        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            try AudioHardwareError.check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format), AudioHardwareError.inputUnavailable)
            formats.append(format)
        }
        switch InputLayout.parse(formats) {
        case .success(let layout): return layout
        case .failure(let why): throw AudioHardwareError.unsupportedInput(device: device, why: why)
        }
    }

    /// Gives back an IOProc: stopped, then destroyed. [LAW:single-enforcer] Both ways one
    /// ends come through here - a `Reach` being let go, and a preparation giving up partway -
    /// so the two cannot drift apart on how much of an IOProc there is to give back.
    ///
    /// Every step is unconditional, because each is a no-op on an IOProc that never got that
    /// far - measured on the built-in microphone and BlackHole for low-reliability-z2z.csw
    /// rather than assumed: a stop of one never started, a second stop, and a destroy while
    /// running all answer `noErr`, and the device is dark after. [LAW:dataflow-not-control-flow]
    ///
    /// [LAW:no-silent-failure] exception: these two statuses are dropped, and unlike the stop
    /// in `close()` there is nothing better to read instead. Both paths here have no caller to
    /// tell - `deinit`, and an `init` already throwing a truer error than a teardown status -
    /// and no harm to report either, because what the epic cares about is whether the device
    /// came back, and a destroyed IOProc cannot keep it. A device that is gone answers both
    /// `!dev`, which is the answer to a question nobody is left to ask.
    private nonisolated static func discard(_ procID: AudioDeviceIOProcID, on device: AudioObjectID) {
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
    }

    /// How far a press's delivery thread may fall behind the device before audio is dropped.
    /// It waits on nothing longer than the main actor copying one session out of the ring, so
    /// this is far more than it needs, and it costs memory only while a press is open.
    private nonisolated static let backlog: TimeInterval = 2
}
