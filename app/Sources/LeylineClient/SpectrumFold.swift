// SPDX-License-Identifier: Apache-2.0

// Folds over FFT rows the window needs, each the same rule `ley` applies so the two clients
// report the same bin and land on the same squelch: max hold, Centre on Strongest Signal, and the
// measured squelch. Presentation only: a median is a fold over one row, the spectrum itself is the
// daemon's (invariant 2), and nothing here is a detector (invariant 12).

import Foundation

public enum SpectrumFold {
    /// The row's median level: the noise floor per bin, as presentation.
    public static func medianDB(_ bins: [Float]) -> Float {
        guard !bins.isEmpty else { return .nan }
        return bins.sorted()[bins.count / 2]
    }

    /// How far above the row's median a bin must be to count as a peak. The loudest of a
    /// thousand noise bins sits about 10 dB above their median by chance alone; 15 dB is above
    /// what noise reaches and below any carrier worth tuning to (`go/internal/cli/spectrum.go`,
    /// `peakAboveFloorDb`).
    public static let peakAboveFloorDB: Float = 15

    public struct Peak: Sendable, Hashable {
        public var centerHz: UInt64
        public var db: Float
    }

    /// Up to `n` of the loudest local maxima at or above `minDB`, loudest first, as bin-centre
    /// frequencies. A run of equal bins counts once, and a peak closer than three bins or a
    /// 128th of the span to a louder one is its shoulder, not a second find. `ley spectrum`'s
    /// `loudestBins`, so both clients report the same peaks.
    public static func loudestBins(
        _ bins: [Float], centerHz: UInt64, spanHz: UInt64, n: Int, minDB: Float
    ) -> [Peak] {
        guard !bins.isEmpty, n > 0 else { return [] }
        let binWidth = Double(spanHz) / Double(bins.count)
        let left = Double(centerHz) - Double(spanHz) / 2
        var peaks: [Peak] = []
        for (i, v) in bins.enumerated() {
            if v < minDB { continue }
            if i > 0, bins[i - 1] >= v { continue }
            if i + 1 < bins.count, bins[i + 1] > v { continue }
            // A span reaching below 0 Hz puts a bin's centre there; 0 Hz is the lower clamp.
            let hz = max(0, (left + (Double(i) + 0.5) * binWidth).rounded())
            peaks.append(Peak(centerHz: UInt64(hz), db: v))
        }
        peaks.sort { $0.db > $1.db }
        let gap = max(3 * binWidth, Double(spanHz) / 128)
        var kept: [Peak] = []
        for p in peaks {
            if kept.count >= n { break }
            let near = kept.contains { abs(Double(p.centerHz) - Double($0.centerHz)) < gap }
            if !near { kept.append(p) }
        }
        return kept
    }

    /// The strongest peak in the row by the rule above, or nil when nothing clears the floor.
    public static func strongest(_ bins: [Float], centerHz: UInt64, spanHz: UInt64) -> Peak? {
        let floor = medianDB(bins)
        guard floor.isFinite else { return nil }
        return loudestBins(
            bins, centerHz: centerHz, spanHz: spanHz, n: 1, minDB: floor + peakAboveFloorDB
        ).first
    }

    /// A squelch from one row: the median bin is the floor per bin, scaled to the channel width
    /// by 10·log10(bandwidth / bin width), and the threshold is 10 dB above that, rounded.
    /// `ley tune`'s auto squelch (`go/internal/cli/session.go`, `measureSquelch`). Returns the
    /// threshold and the scaled floor; both NaN on an empty row.
    public static func autoSquelch(_ bins: [Float], sampleRate: UInt64, bandwidthHz: UInt32) -> (
        thresholdDB: Double, floorDB: Double
    ) {
        let floor = channelFloorDB(
            binFloorDB: Double(medianDB(bins)), bins: bins.count, sampleRate: sampleRate,
            bandwidthHz: bandwidthHz)
        guard floor.isFinite else { return (.nan, .nan) }
        return ((floor + 10).rounded(), floor)
    }

    /// The floor of a channel from the floor of a bin: `floor + 10·log10(bandwidth / bin
    /// width)`, the auto squelch's scaling, which is also what a channel's power is over noise
    /// by. NaN when there is nothing to scale.
    public static func channelFloorDB(
        binFloorDB: Double, bins: Int, sampleRate: UInt64, bandwidthHz: UInt32
    ) -> Double {
        guard binFloorDB.isFinite, bins > 0, sampleRate > 0, bandwidthHz > 0 else { return .nan }
        let binWidth = Double(sampleRate) / Double(bins)
        return binFloorDB + 10 * log10(Double(bandwidthHz) / binWidth)
    }

    /// The pointer badge's level clause: `−52 dBFS · 26 dB over the floor`, whole dB with a
    /// real minus sign (U+2212) and no plus, and `— dBFS · — dB over the floor` without a level
    /// or before a floor is held. The margin is the difference of the two rounded numbers, so it
    /// agrees with the level beside it and with the rule's `floor −78` label.
    public static func levelWords(levelDB: Float, floorDB: Float) -> String {
        guard levelDB.isFinite, floorDB.isFinite else {
            return "\(Reading.absent) dBFS · \(Reading.absent) dB over the floor"
        }
        let level = Int(levelDB.rounded())
        let margin = level - Int(floorDB.rounded())
        return "\(signed(level)) dBFS · \(signed(margin)) dB over the floor"
    }

    private static func signed(_ n: Int) -> String {
        n < 0 ? "\u{2212}\(-n)" : "\(n)"
    }
}

/// The loudest level seen per bin since the last reset: the spectrum's max-hold trace. A
/// fold over rows the app already has; it resets when the capture moves or the bin count
/// changes, because a hold across two different spans is wrong for both.
public struct MaxHold: Sendable {
    public private(set) var levelsDB: [Float] = []
    public private(set) var rows = 0

    public init() {}

    public mutating func reset() {
        levelsDB = []
        rows = 0
    }

    public mutating func fold(_ row: [Float]) {
        if levelsDB.count != row.count {
            levelsDB = row
            rows = 1
            return
        }
        for i in row.indices where row[i] > levelsDB[i] {
            levelsDB[i] = row[i]
        }
        rows += 1
    }
}

/// The noise floor the waterfall's cold end and the spectrum's axis are keyed from: a smoothed
/// median, held. It is taken from the first median, falls as soon as the median is more than
/// `slackDB` below it, and rises only once the median has stayed more than `slackDB` above it
/// for `riseSeconds` on the capture's clock. Every row on screen is coloured from the current
/// floor, so a floor that moved recoloured rows already drawn; a keyed handheld that clips the
/// radio lifts the whole band's median with overload spurs for as long as it transmits, and a
/// floor that followed at once recoloured the history on every press of PTT
/// (docs/dev/app.md, "Palette and type"). A real change, a retune or a gain move, resets the fold,
/// so the floor is re-taken at once after one. The time is the rows' `SampleTime` and the capture's
/// rate, never the wall clock (AGENTS.md, invariant 5); with the rate unknown the floor does not
/// rise.
public struct HeldFloor: Sendable, Equatable {
    /// How far the median may drift from the floor before the floor follows it.
    public static let slackDB: Float = 4
    /// How long the median must stay over the floor plus the slack before the floor rises.
    /// Longer than a clipping over measured on a real GMRS handheld (12206080 samples at 4 MS/s,
    /// 3 s); an over that lasts longer than this still moves the floor once it has.
    public static let riseSeconds: Double = 5

    /// The held floor in dBFS, rounded to 1 dB; NaN until the first median.
    public private(set) var floorDB: Float = .nan
    /// The first sample of the run of medians above the floor plus the slack, or nil when the
    /// newest median is not above it.
    private var riseStart: UInt64?

    public init() {}

    /// Folds one smoothed median in, measured on the row at `sampleIndex` of a capture sampled
    /// at `sampleRate`, and returns the floor. A NaN median changes nothing.
    @discardableResult
    public mutating func fold(medianDB: Float, atSample sampleIndex: UInt64, sampleRate: UInt64)
        -> Float
    {
        guard !medianDB.isNaN else { return floorDB }
        if floorDB.isNaN || medianDB < floorDB - Self.slackDB {
            floorDB = medianDB.rounded()
            riseStart = nil
        } else if medianDB > floorDB + Self.slackDB, sampleRate > 0 {
            // A row from before the run's start (a restarted timeline) begins the run again.
            let from = riseStart.flatMap { $0 <= sampleIndex ? $0 : nil } ?? sampleIndex
            if Double(sampleIndex - from) >= Self.riseSeconds * Double(sampleRate) {
                floorDB = medianDB.rounded()
                riseStart = nil
            } else {
                riseStart = from
            }
        } else {
            riseStart = nil
        }
        return floorDB
    }

    /// Forgets the floor, so the next median is taken at once: the capture moved or its gain
    /// changed, and the held value belongs to the old picture.
    public mutating func reset() {
        floorDB = .nan
        riseStart = nil
    }
}
