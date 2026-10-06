// SPDX-License-Identifier: GPL-3.0-or-later

// The delay line a gated audio recording writes through, so the squelch tail can be silenced and
// the squelch's open faded in before either reaches the part (docs/design/recording.md, "The
// squelch's edges").
//
// The squelch decides once per capture block and closes on the first block after the carrier
// has gone, so the audio between the carrier dropping and the close transition is the
// discriminator's full-scale noise. The close record arrives with or just before the audio it
// describes, so by then the tail is still held here, and it is faded out before it is released.
//
// Off the DSP thread: the record job's drain owns this. The storage is reserved once when the
// runner starts; a push within that capacity does not grow it.

import Foundation

struct HeldAudio: Sendable {
    /// Audio samples held back before they are released to the part.
    let capacity: Int
    /// Capture samples per audio sample, to place each held sample on the capture's timeline.
    let perAudio: Double
    /// Capture samples of the faded ramp ahead of a silenced window.
    let fadeSamples: UInt64

    private(set) var samples: [Float] = []
    /// The capture sample just past the last held sample.
    private(set) var endSample: UInt64 = 0
    /// Windows still to be applied to audio that has not arrived yet: an edge record that came in
    /// before the audio it describes.
    private var windows: [Window] = []

    private enum Window {
        /// A ramp to silence from `fadeFrom` to `from`, then silence up to the close transition `to`.
        case out(fadeFrom: UInt64, from: UInt64, to: UInt64)
        /// Silence from `silentFrom` to the open transition `from`, then a ramp from silence to full
        /// gain at `to`.
        case fadeIn(silentFrom: UInt64, from: UInt64, to: UInt64)

        var end: UInt64 {
            switch self {
            case .out(_, _, let to), .fadeIn(_, _, let to): return to
            }
        }
    }

    init(capacity: Int, perAudio: Double, fadeSamples: UInt64) {
        self.capacity = Swift.max(0, capacity)
        self.perAudio = Swift.max(perAudio, 1e-9)
        self.fadeSamples = fadeSamples
        // A frame (at most `AudioFrameSource.maxFrame`) is appended before the overflow is
        // released, so the reservation covers both.
        samples.reserveCapacity(self.capacity + AudioFrameSource.maxFrame)
        windows.reserveCapacity(4)
    }

    var isEmpty: Bool { samples.isEmpty }

    /// The capture sample of the oldest held sample: everything before it has been released.
    var startSample: UInt64 {
        let behind = UInt64((Double(samples.count) * perAudio).rounded())
        return endSample > behind ? endSample - behind : 0
    }

    /// Holds `audio`, which ends at capture sample `end`, and returns whatever no longer fits,
    /// oldest first, for the part.
    mutating func push(_ audio: [Float], endingAt end: UInt64) -> [Float] {
        guard !audio.isEmpty else { return [] }
        let firstNew = samples.count
        samples.append(contentsOf: audio)
        endSample = Swift.max(end, endSample)
        if !windows.isEmpty {
            for w in windows { apply(w, from: firstNew) }
            windows.removeAll { $0.end <= endSample }
        }
        let over = samples.count - capacity
        guard over > 0 else { return [] }
        let released = Array(samples[0..<over])
        samples.removeFirst(over)
        return released
    }

    /// Silences `[closedAt - tail, closedAt)`, with a raised-cosine ramp of `fadeSamples` ahead of
    /// it so the cut is not a click. Applied to what is held now and to whatever arrives later
    /// inside the window; audio already released is out of reach.
    mutating func silence(before closedAt: UInt64, tail: UInt64) {
        let from = closedAt > tail ? closedAt - tail : 0
        add(.out(fadeFrom: from > fadeSamples ? from - fadeSamples : 0, from: from, to: closedAt))
    }

    /// Ramps `[openedAt, openedAt + length)` up from silence with a raised cosine, so the floor
    /// noise and the key-up click in the block the squelch opened on are not written at full
    /// scale. Audio dated less than one audio sample before the open is silenced too, because a
    /// held sample's place on the timeline is only good to that: a capture block is not a whole
    /// number of audio samples (16384 capture samples are 327.68 at 2.4 MSPS and 48 kHz), so a
    /// frame of 327 or 328 is dated up to an audio sample either side of where it belongs, and the
    /// open block's first sample can sit just before the open, where the ramp would not reach it.
    /// Whatever else falls there is the squelch's zeros on the `.audio` tap. Audio a whole audio
    /// sample or more before the open is left as it is.
    mutating func fadeIn(from openedAt: UInt64, length: UInt64) {
        let reach = UInt64(Swift.max(perAudio.rounded(.up) - 1, 0))
        add(.fadeIn(silentFrom: openedAt > reach ? openedAt - reach : 0, from: openedAt,
                    to: openedAt + Swift.max(length, 1)))
    }

    private mutating func add(_ w: Window) {
        apply(w, from: 0)
        if w.end > endSample { windows.append(w) }
    }

    /// Releases every held sample before capture sample `sample`, and returns the rest as well,
    /// in order: the part closing there takes the first, and the second is after its end.
    mutating func drain(before sample: UInt64) -> (kept: [Float], after: [Float]) {
        let behind = sample < endSample ? Double(endSample - sample) / perAudio : 0
        let split = Swift.max(0, Swift.min(samples.count, samples.count - Int(behind.rounded())))
        let kept = Array(samples[0..<split])
        let after = Array(samples[split...])
        samples.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
        return (kept, after)
    }

    /// Releases everything held.
    mutating func drainAll() -> [Float] {
        let all = samples
        samples.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
        return all
    }

    /// Multiplies the held samples from index `first` on by the window's gain at their place on
    /// the capture's timeline.
    private mutating func apply(_ w: Window, from first: Int) {
        let count = samples.count
        guard first < count else { return }
        let end = Double(endSample)
        for i in first..<count {
            let at = end - Double(count - i) * perAudio
            switch w {
            case .out(let fadeFrom, let from, let to):
                if at < Double(fadeFrom) || at >= Double(to) { continue }
                if at >= Double(from) {
                    samples[i] = 0
                } else if from > fadeFrom {
                    let x = (at - Double(fadeFrom)) / Double(from - fadeFrom)
                    samples[i] *= Float(0.5 * (1 + cos(Double.pi * x)))
                }
            case .fadeIn(let silentFrom, let from, let to):
                if at < Double(silentFrom) || at >= Double(to) { continue }
                if at < Double(from) {
                    samples[i] = 0
                    continue
                }
                let x = (at - Double(from)) / Double(to - from)
                samples[i] *= Float(0.5 * (1 - cos(Double.pi * x)))
            }
        }
    }
}
