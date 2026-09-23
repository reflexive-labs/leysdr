// SPDX-License-Identifier: Apache-2.0

// Folds over FFT rows the window needs, each the same rule `ley` applies so the two clients
// report the same bin and land on the same squelch (docs/design/app-design-handoff.md, Region 3
// "Max hold", Region 4 "Centre on Strongest Signal", Region 1 "the squelch is measured").
// Presentation only: a median is a fold over one row, the spectrum itself is the daemon's
// (invariant 2), and nothing here is a detector (invariant 12).

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
    /// or before a floor is held (docs/design/app-design-handoff.md, "Region 3: the
    /// spectrum"). The margin is the difference of the two rounded numbers, so it agrees with
    /// the level beside it and with the rule's `floor −78` label.
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
