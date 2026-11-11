import Accelerate
import CoreAudio

/// The one channel a render is heard as: every channel of the layout, each weighted by its share
/// of the render's energy. A voice on one channel of sixteen arrives at its own level, where an
/// equal-weight mix would put it at a sixteenth of it, under `Utterance.audible`; channels that
/// carry one signal mix to their mean; and weights that sum to one keep the mix within its
/// loudest channel.
///
/// Mixed here rather than by AVAudioConverter, which mixes every channel equally, and which given
/// a channel layout for more than two channels mixes them to silence (low-reliability-z2z.n4b).
///
/// The weights move from one render's to the next across the render, a crossfade, so a voice
/// that moves between channels is not heard as a step at the render's edge. The first render's
/// own weights are its start, so the instant the microphone opens is heard at its level.
///
/// The producer's alone: called on the IO thread, so it allocates nothing and waits on nothing.
final class Downmix {
    let layout: InputLayout
    /// The weights the last render ended on, then the next render's: `channels` floats each.
    private let weights: UnsafeMutablePointer<Float>
    private let next: UnsafeMutablePointer<Float>
    private var started = false

    init(_ layout: InputLayout) {
        self.layout = layout
        weights = .allocate(capacity: layout.channels)
        weights.initialize(repeating: 0, count: layout.channels)
        next = .allocate(capacity: layout.channels)
        next.initialize(repeating: 0, count: layout.channels)
    }

    deinit {
        weights.deallocate()
        next.deallocate()
    }

    /// Mixes `frames` frames of `list` into `first`, `count` of them, then the rest into `rest`.
    /// The caller has already held `list` to `layout` (`InputLayout.verdict`), which is what
    /// makes every read here in bounds.
    func mix(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, into first: UnsafeMutablePointer<Float>, _ count: Int, then rest: UnsafeMutablePointer<Float>) {
        let channels = layout.channels
        each(list) { channel, source, stride in
            vDSP_svesq(source, stride, next + channel, vDSP_Length(frames))
        }
        // A floor under every channel's energy, so digital silence weighs each channel equally
        // rather than dividing by nothing. Divided rather than multiplied by a reciprocal, as
        // vDSP_vsdiv does, so one channel weighs exactly one and a mono device passes as it is.
        var total: Float = 0
        for channel in 0..<channels {
            next[channel] += .leastNormalMagnitude
            total += next[channel]
        }
        for channel in 0..<channels { next[channel] /= total }
        if !started { weights.update(from: next, count: channels) }
        started = true

        first.update(repeating: 0, count: count)
        rest.update(repeating: 0, count: frames - count)
        each(list) { channel, source, stride in
            var weight = weights[channel]
            var step = (next[channel] - weight) / Float(frames)
            vDSP_vrampmuladd(source, stride, &weight, &step, first, 1, vDSP_Length(count))
            vDSP_vrampmuladd(source + count * stride, stride, &weight, &step, rest, 1, vDSP_Length(frames - count))
        }
        weights.update(from: next, count: channels)
    }

    /// Each channel of `list`, as its index across the layout, its first sample and the stride
    /// between its samples: a buffer of k channels interleaves them k apart.
    private func each(_ list: UnsafeMutableAudioBufferListPointer, _ body: (Int, UnsafePointer<Float>, vDSP_Stride) -> Void) {
        for (index, width) in layout.buffers.enumerated() {
            let source = list[index].mData!.assumingMemoryBound(to: Float.self)
            for lane in 0..<width {
                body(layout.offsets[index] + lane, source + lane, vDSP_Stride(width))
            }
        }
    }
}
