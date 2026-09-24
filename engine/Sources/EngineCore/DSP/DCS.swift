// SPDX-License-Identifier: GPL-3.0-or-later

// DCS (digital-coded squelch) decoding over the sub-audible tap (docs/design/signal-views.md,
// "DCS"; docs/plans/signal-views.md, SV-7).
//
// Everything this file assumes about the format was read off two real takes on 2026-09-23
// (`rf-captures/ht-dcs-023.cf32` and `ht-dcs-754.cf32`, the SV-7 entry "Recorded and read
// 2026-09-23"): a 23-bit word repeated without a gap at 134.4 bit/s; in received order, with
// positive deviation as a one, nine code bits low bit first, the fixed bits `001` and eleven
// parity bits; the word a Golay(23,12) codeword under g(x) = x^11 + x^9 + x^7 + x^6 + x^5 + x + 1
// with the first received bit as the coefficient of x^22. The decoder runs in the channel's
// detached sub-audible task beside the CTCSS detector, never on the DSP thread.

import Foundation

/// The DCS format and the standard code list, as stateless functions over one 23-bit word.
///
/// A word is held in the low 23 bits of a `UInt32` with the first received bit at bit 22, so the
/// integer is the codeword polynomial with that bit as the coefficient of x^22.
public enum DCS {
    /// Bits a second, from the word's autocorrelation on both takes (134.44 measured).
    public static let bitRateHz = 134.4
    public static let wordBits = 23
    /// g(x) = x^11 + x^9 + x^7 + x^6 + x^5 + x + 1. Both takes divide exactly under it in every
    /// rotation and in both polarities, as a cyclic code containing the all-ones word does.
    public static let generator: UInt32 = 0xAE3
    static let wordMask: UInt32 = (1 << 23) - 1

    /// The 104 codes radios offer, octal. Checked on 2026-09-24 against the RadioReference wiki's
    /// DCS chart (wiki.radioreference.com/index.php/DCS), which lists these 104 and eight more
    /// (006, 007, 015, 017, 021, 050, 141, 214) that scanners accept and handheld menus do not
    /// offer; the 104 are also the set closed under inversion that page's pair table lists. The
    /// list is what frames the word: the fixed bits alone do not, because every rotation of a
    /// codeword is a codeword and several rotations carry `001` in place (the 754 word also reads
    /// as 076 and 203).
    public static let standardCodes: [Int] = [
        0o023, 0o025, 0o026, 0o031, 0o032, 0o036, 0o043, 0o047, 0o051, 0o053, 0o054, 0o065,
        0o071, 0o072, 0o073, 0o074, 0o114, 0o115, 0o116, 0o122, 0o125, 0o131, 0o132, 0o134,
        0o143, 0o145, 0o152, 0o155, 0o156, 0o162, 0o165, 0o172, 0o174, 0o205, 0o212, 0o223,
        0o225, 0o226, 0o243, 0o244, 0o245, 0o246, 0o251, 0o252, 0o255, 0o261, 0o263, 0o265,
        0o266, 0o271, 0o274, 0o306, 0o311, 0o315, 0o325, 0o331, 0o332, 0o343, 0o346, 0o351,
        0o356, 0o364, 0o365, 0o371, 0o411, 0o412, 0o413, 0o423, 0o431, 0o432, 0o445, 0o446,
        0o452, 0o454, 0o455, 0o462, 0o464, 0o465, 0o466, 0o503, 0o506, 0o516, 0o523, 0o526,
        0o532, 0o546, 0o565, 0o606, 0o612, 0o624, 0o627, 0o631, 0o632, 0o654, 0o662, 0o664,
        0o703, 0o712, 0o723, 0o731, 0o732, 0o734, 0o743, 0o754,
    ]

    /// The remainder of `word` divided by the generator; 0 for a codeword.
    public static func syndrome(_ word: UInt32) -> UInt32 {
        var v = word & wordMask
        var i = 22
        while i >= 11 {
            if v >> UInt32(i) & 1 == 1 { v ^= generator << UInt32(i - 11) }
            i -= 1
        }
        return v
    }

    public static func isCodeword(_ word: UInt32) -> Bool { syndrome(word) == 0 }

    /// The word a transmitter sends for `code` (0...511, the nine bits of the three octal digits),
    /// in received order: code bits low first, `001`, then the parity that makes it a codeword.
    public static func encode(code: Int) -> UInt32 {
        precondition((0 ..< 512).contains(code))
        var data: UInt32 = 0
        for j in 0 ..< 9 where (code >> j) & 1 == 1 { data |= 1 << UInt32(22 - j) }
        data |= 1 << 11  // received bit 11, the last of the fixed `001`
        return data | syndrome(data)
    }

    /// `word` rotated so that the bit received `k` places later comes first.
    public static func rotate(_ word: UInt32, by k: Int) -> UInt32 {
        let k = UInt32(((k % wordBits) + wordBits) % wordBits)
        guard k > 0 else { return word & wordMask }
        return ((word << k) | (word >> (UInt32(wordBits) - k))) & wordMask
    }

    /// The code a frame-aligned word carries when its received bits 9 to 11 are `001`, or nil.
    /// It does not check parity; callers test the unrotated word once, because rotation keeps a
    /// codeword a codeword.
    static func frameCode(_ r: UInt32) -> Int? {
        guard (r >> 11) & 0b111 == 0b001 else { return nil }
        var code = 0
        for j in 0 ..< 9 where (r >> UInt32(22 - j)) & 1 == 1 { code |= 1 << j }
        return code
    }

    /// The octal digits of `code` read as a decimal number, the contract's convention for
    /// `dcs_code` (023 -> 23).
    public static func octalAsDecimal(_ code: Int) -> Int {
        (code >> 6 & 7) * 100 + (code >> 3 & 7) * 10 + (code & 7)
    }
}

/// What the DCS decoder concluded at one hop.
public struct DCSResult: Sendable, Equatable {
    /// Whether three consecutive words at one bit phase read as one listed code.
    public var detected: Bool = false
    /// The code, as the octal digits read in decimal (023 -> 23, the contract's convention); 0
    /// unless `detected`. The decoder never reports the nearest listed code to a word that is not
    /// one (invariant 12).
    public var code: Int = 0
    /// True when the code was read from the complemented stream. With the standard list this is
    /// never the case: the list is closed under complement (023 inverted is on the air as 047
    /// normal, bit for bit), so the received polarity always finds a listed code first.
    public var inverted: Bool = false
    /// Mean magnitude of the sliced samples at the chosen phase, Hz. NaN before the history holds
    /// three words.
    public var deviationHz: Double = .nan
    /// Bits corrected to reach a codeword. Always 0: this version accepts exact codewords only.
    public var bitErrors: Int = 0
    /// Consecutive words, newest back and at most three, that read as the same listed code at the
    /// best phase.
    public var wordsAgreeing: Int = 0
    /// Mean |sample| over the standard deviation of |sample| at the sliced bit centres: how open
    /// the eye is. NaN before the history holds three words.
    public var eye: Double = .nan
    /// A stated score, not a probability: see `DCSDecoder.confidence(wordsAgreeing:eye:)`.
    public var confidence: Double = 0
    /// The newest word at the best phase, received polarity, first bit at bit 22. For the log when
    /// nothing is claimed; never interpreted beyond that.
    public var rawWord: UInt32 = 0

    public init() {}
}

/// Slices the sub-audible tap into DCS bits and reads the code.
///
/// No clock is recovered. Every hop it samples the detrended tap at bit spacing from each of
/// `phases` starting points, forms the last three 23-bit words at each, and accepts a phase whose
/// three words give one listed code; a transmitter's clock is steady enough over three words
/// (0.51 s) that the best of eight phases sits within a sixteenth of a bit of the centre. Every
/// buffer is allocated in `init`; `analyse` allocates nothing.
public final class DCSDecoder {
    public let rate: Double
    public let samplesPerBit: Double
    /// Starting points tried within one bit. At 7.44 samples a bit, eight puts the best within
    /// half a sample of the bit centre.
    public static let phases = 8
    /// Consecutive identical words a lock needs, as receivers do.
    public static let wordsForLock = 3
    /// The tuning-error tracker's time constant. Long against a word (171 ms) so the bits do not
    /// move it, which a window mean would: a run of ones pulls a short mean up and shrinks every
    /// one in it.
    public static let trackerSeconds = 1.0

    private let bitsKept = DCSDecoder.wordsForLock * DCS.wordBits
    /// The oldest sample the slicer can reach, plus interpolation's one extra.
    private let span: Int
    private var history: [Float]
    private var head = 0  // next write index
    private var filled = 0
    private var tracker: Double = 0
    private var trackerSeeded = false
    private let trackerAlpha: Double
    private var sliced: [Float]
    private var bestSliced: [Float]
    private var listed: [Bool]

    /// `codes` is the list a lock must land on, as nine-bit values (octal literals); tests narrow it
    /// to reach the complemented-polarity branch, which the standard list never takes.
    public init(rate: Double, codes: [Int] = DCS.standardCodes) {
        precondition(rate > 0)
        self.rate = rate
        samplesPerBit = rate / DCS.bitRateHz
        span = Int((samplesPerBit * Double(DCSDecoder.wordsForLock * DCS.wordBits + 1)).rounded(.up)) + 2
        history = [Float](repeating: 0, count: span)
        trackerAlpha = 1 - Foundation.exp(-1 / (rate * DCSDecoder.trackerSeconds))
        sliced = [Float](repeating: 0, count: DCSDecoder.wordsForLock * DCS.wordBits)
        bestSliced = sliced
        listed = [Bool](repeating: false, count: 512)
        for c in codes where (0 ..< 512).contains(c) { listed[c] = true }
    }

    /// Forget the history and the tracker. Called when the squelch closes: the next transmission
    /// has its own tuning error and its own bit clock.
    public func reset() {
        head = 0
        filled = 0
        trackerSeeded = false
        tracker = 0
    }

    /// Take the next samples of the tap (±1.0 is `fullScaleDeviationHz`) and decode over the
    /// history so far. Call it once per hop with the samples that arrived since the last call.
    public func analyse(_ samples: [Float], fullScaleDeviationHz: Double) -> DCSResult {
        if !samples.isEmpty, !trackerSeeded {
            // Start the tracker at the first hop's mean rather than at zero, so a channel created
            // mid-transmission is not sliced for a second against a zero the carrier is nowhere
            // near. A key-up after a squelch close starts from the noise's mean instead, and
            // `correctTracker` covers that case once a word reads.
            var sum = 0.0
            for v in samples { sum += Double(v) }
            tracker = sum / Double(samples.count)
            trackerSeeded = true
        }
        for v in samples {
            tracker += trackerAlpha * (Double(v) - tracker)
            history[head] = Float(Double(v) - tracker)
            head = head + 1 == span ? 0 : head + 1
            if filled < span { filled += 1 }
        }
        var out = DCSResult()
        guard filled == span else { return out }

        var bestAgree = -1
        var bestEye = -Double.infinity
        var bestCode = 0, bestInverted = false, bestWord: UInt32 = 0
        for p in 0 ..< Self.phases {
            let back = Double(p) * samplesPerBit / Double(Self.phases)
            // Newest bit first in `sliced`; the words are formed oldest first below.
            for k in 0 ..< bitsKept {
                sliced[k] = sample(back: back + Double(k) * samplesPerBit)
            }
            var words: (UInt32, UInt32, UInt32) = (0, 0, 0)
            for w in 0 ..< Self.wordsForLock {
                var word: UInt32 = 0
                // Word 0 is the newest; within a word the oldest bit goes to bit 22.
                let newest = w * DCS.wordBits
                for j in stride(from: newest + DCS.wordBits - 1, through: newest, by: -1) {
                    word = (word << 1) | (sliced[j] > 0 ? 1 : 0)
                }
                switch w {
                case 0: words.0 = word
                case 1: words.1 = word
                default: words.2 = word
                }
            }
            let r0 = read(words.0)
            var agree = 0
            if let r0 {
                agree = 1
                if read(words.1).map({ $0 == r0 }) == true {
                    agree = 2
                    if read(words.2).map({ $0 == r0 }) == true { agree = 3 }
                }
            }
            let eye = eyeOpening(sliced)
            if agree > bestAgree || (agree == bestAgree && eye > bestEye) {
                bestAgree = agree
                bestEye = eye
                bestCode = r0?.code ?? 0
                bestInverted = r0?.inverted ?? false
                bestWord = words.0
                for k in 0 ..< bitsKept { bestSliced[k] = sliced[k] }
            }
        }
        if bestAgree >= 1 { correctTracker(bits: bestAgree * DCS.wordBits) }
        var meanAbs = 0.0
        for v in bestSliced { meanAbs += Double(abs(v)) }
        meanAbs /= Double(bestSliced.count)
        out.deviationHz = meanAbs * fullScaleDeviationHz
        out.eye = bestEye
        out.rawWord = bestWord
        out.wordsAgreeing = Swift.max(0, bestAgree)
        if bestAgree >= Self.wordsForLock {
            out.detected = true
            out.code = DCS.octalAsDecimal(bestCode)
            out.inverted = bestInverted
            out.confidence = Self.confidence(wordsAgreeing: bestAgree, eye: bestEye)
        }
        return out
    }

    /// A stated score in [0, 1], **not** a probability, for the same reason as the CTCSS
    /// detector's: there is no corpus to calibrate one against.
    ///
    ///     confidence = min(words_agreeing, 3) / 3 * clamp((eye - 2) / 6)
    ///
    /// where `eye` is mean |sample| over the standard deviation of |sample| at the sliced bit
    /// centres. At an eye of 2 about one sample in 44 lands on the wrong side under Gaussian
    /// scatter, and 8 or more is a clean eye. The two real takes read 30 to 68 from the first lock
    /// (docs/plans/signal-views.md, SV-7, "Landed (engine)"), so the score separates a weak or
    /// noisy lock from a clean one and does not rank clean ones.
    public static func confidence(wordsAgreeing: Int, eye: Double) -> Double {
        let words = Double(Swift.min(Swift.max(wordsAgreeing, 0), wordsForLock)) / Double(wordsForLock)
        guard eye.isFinite else { return words }
        return words * Swift.min(1, Swift.max(0, (eye - 2) / 6))
    }

    /// Move the tracker, and the history already detrended by it, onto the middle of the eye.
    ///
    /// The one-pole tracker starts a transmission wherever the noise before it left it, and at a
    /// one-second time constant the 023 take's eye was still opening two seconds after the lock
    /// (from 2.2 to 20 over 2.3 s). Once a word has read as a listed code its bits are known, so
    /// the midpoint of the ones' mean and the zeros' mean is the residual tuning error, and it does
    /// not depend on how many ones the word holds, which is what bends the bits under a window
    /// mean. Only the first `bits` sliced samples of `bestSliced`, the words that read, are used.
    private func correctTracker(bits: Int) {
        var sumHigh = 0.0, sumLow = 0.0
        var nHigh = 0, nLow = 0
        for k in 0 ..< Swift.min(bits, bestSliced.count) {
            let v = Double(bestSliced[k])
            if v > 0 { sumHigh += v; nHigh += 1 } else { sumLow += v; nLow += 1 }
        }
        guard nHigh > 0, nLow > 0 else { return }
        let residual = (sumHigh / Double(nHigh) + sumLow / Double(nLow)) / 2
        tracker += residual
        let r = Float(residual)
        for i in 0 ..< span { history[i] -= r }
    }

    /// The tap `back` samples before the newest, linearly interpolated.
    private func sample(back: Double) -> Float {
        let i = Int(back)
        let f = Float(back - Double(i))
        let a = history[index(back: i)], b = history[index(back: i + 1)]
        return a + (b - a) * f
    }

    private func index(back: Int) -> Int {
        var i = head - 1 - back
        while i < 0 { i += span }
        return i
    }

    /// The listed code `word` carries in some rotation, received polarity first.
    private func read(_ word: UInt32) -> (code: Int, inverted: Bool)? {
        if DCS.isCodeword(word), let c = listedCode(in: word) { return (c, false) }
        let flipped = ~word & DCS.wordMask
        if DCS.isCodeword(flipped), let c = listedCode(in: flipped) { return (c, true) }
        return nil
    }

    private func listedCode(in word: UInt32) -> Int? {
        for k in 0 ..< DCS.wordBits {
            if let c = DCS.frameCode(DCS.rotate(word, by: k)), listed[c] { return c }
        }
        return nil
    }

    private func eyeOpening(_ v: [Float]) -> Double {
        var sum = 0.0, sumSq = 0.0
        for x in v {
            let a = Double(abs(x))
            sum += a
            sumSq += a * a
        }
        let n = Double(v.count)
        let mean = sum / n
        let variance = Swift.max(0, sumSq / n - mean * mean)
        guard mean > 0 else { return 0 }
        return variance > 0 ? mean / variance.squareRoot() : .infinity
    }
}
