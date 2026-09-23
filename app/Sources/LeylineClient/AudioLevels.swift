// SPDX-License-Identifier: Apache-2.0

// The audio ladder's arithmetic, ported from `ley levels` (go/internal/cli/levels_bands.go) so the
// inspector's bars and the terminal's read the same dB from the same row
// (docs/design/audio-meters.md). A row is the daemon's spectrum of a channel's audio, one Hann
// transform from 0 Hz to half the audio rate; `BandLevels` sums its bins into octave bands and
// `LevelBar` is one bar's ballistics between rows. Both are presentation over the daemon's rows:
// nothing smoothed here is reported as a measurement, and the rms and peak the panel prints come
// off the meter, not off a row. Values with no Observation in them, so the container tests them.

import Foundation

/// The octave bands of one audio spectrum row, summed in power.
public struct BandLevels: Sendable, Equatable {
    /// One bar: the centre it is named by and the edges of the row's bins that belong to it.
    public struct Band: Sendable, Equatable {
        public let centreHz: Double
        public let loHz: Double
        public let hiHz: Double

        public init(centreHz: Double, edge: Double) {
            self.centreHz = centreHz
            loHz = centreHz / edge
            hiHz = centreHz * edge
        }

        /// `63`, `125`, `1k`, `16k`: hertz below a kilohertz, kilohertz above it, with the fewest
        /// digits that identify the band, as an equaliser labels it.
        public var label: String {
            centreHz < 1000 ? Self.shortest(centreHz) : Self.shortest(centreHz / 1000) + "k"
        }

        private static func shortest(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(v)
        }
    }

    /// The nine ISO octave centres audio equipment carries, 63 Hz to 16 kHz.
    public static let octaveCentresHz: [Double] = [
        63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
    ]
    /// A full octave spans a factor of two, so each edge is √2 from the centre.
    public static let octaveEdge: Double = 2.0.squareRoot()
    /// The Hann window's equivalent noise bandwidth in bins. A windowed tone leaks a quarter of
    /// its power into each neighbour, so a band's bins add up to one and a half times what is
    /// really in it, and broadband power is spread by the same factor.
    public static let windowENBW: Double = 1.5
    /// The level of a band with nothing in it, and the bottom of every level: the DB_U8 scale's
    /// floor, which is also `ley levels`' (`scopeMinDbfs`).
    public static let floorDB: Double = -120

    public let bands: [Band]
    /// One level per band in dBFS, `floorDB` until `measure` has read a row.
    public private(set) var levelsDB: [Double]

    public init(centresHz: [Double] = Self.octaveCentresHz, edge: Double = Self.octaveEdge) {
        bands = centresHz.map { Band(centreHz: $0, edge: edge) }
        levelsDB = [Double](repeating: Self.floorDB, count: centresHz.count)
    }

    /// Reads one row into `levelsDB` in place, so a feed folding twenty rows a second allocates
    /// nothing here. `binHz` is the descriptor's `span_hz` over its bin count.
    public mutating func measure(_ row: [Float], binHz: Double) {
        for i in bands.indices {
            levelsDB[i] = Self.level(of: bands[i], in: row, binHz: binHz)
        }
    }

    public mutating func reset() {
        for i in levelsDB.indices { levelsDB[i] = Self.floorDB }
    }

    /// The band's level: the bins whose centres fall inside it, summed in power, corrected for
    /// the window and converted back to dB. Energy adds where dB do not, so two equal bins read
    /// 3 dB over either. A band too narrow to hold a bin centre reads the bin its centre falls
    /// in, so it is a bar rather than a gap, corrected the same way, so it does not step 1.76 dB
    /// against its neighbours on a flat floor.
    public static func level(of band: Band, in row: [Float], binHz: Double) -> Double {
        guard !row.isEmpty, binHz > 0, binHz.isFinite else { return floorDB }
        var sum = 0.0
        var n = 0
        // The lower edge belongs to this band and the upper to the next, so neighbouring bands
        // never count one bin twice.
        var i = max(Int((band.loHz / binHz).rounded(.up)), 0)
        while i < row.count, Double(i) * binHz < band.hiHz {
            sum += pow(10, Double(row[i]) / 10)
            n += 1
            i += 1
        }
        if n == 0 {
            let c = (band.centreHz / binHz).rounded()
            guard c >= 0, c < Double(row.count) else { return floorDB }
            sum = pow(10, Double(row[Int(c)]) / 10)
        }
        let db = 10 * log10(sum / windowENBW)
        return db.isNaN || db < floorDB ? floorDB : db
    }
}

/// The ladder's scale, `ley levels`' own: fine where the working range is and coarse below it,
/// held rather than fitted, so a bar of a given height always means the same dB.
public enum LevelScale {
    public static let topDB: Double = 0
    /// Where the scale changes step: 6 dB a step above, 10 dB a step below.
    public static let kneeDB: Double = -24
    public static let bottomDB: Double = -60
    public static let fineStepDB: Double = 6
    public static let coarseStepDB: Double = 10
    /// The alignment level on professional meters, drawn across the plot as a reference line.
    public static let alignmentDB: Double = -18

    /// A level as a fraction of the ladder's height: 0 at `bottomDB`, 1 at full scale, clamped
    /// at both, and 0 for NaN. Piecewise linear in steps, so a mark and a bar of one level land
    /// in the same place.
    public static func fraction(_ db: Double) -> Double {
        guard !db.isNaN else { return 0 }
        let lo = steps(bottomDB)
        let hi = steps(topDB)
        return min(max((steps(db) - lo) / (hi - lo), 0), 1)
    }

    /// The scale in its own units, one unit a step of the fine part, zero at the knee.
    static func steps(_ db: Double) -> Double {
        db >= kneeDB ? (db - kneeDB) / fineStepDB : (db - kneeDB) / coarseStepDB
    }
}

/// One bar of the ladder between rows: where it stands and where its peak cap hangs. Attack is
/// instant, so a bar never lags the sound; release is 20 dB a second, so a syllable's decay
/// stays visible; the cap holds the loudest level of the last 1.5 s and then falls 10 dB a
/// second. Time is the caller's clock; the inspector folds on the capture's sample clock, so a
/// stalled stream holds its bars.
public struct LevelBar: Sendable, Equatable {
    public static let releaseDBPerSecond: Double = 20
    public static let capHoldSeconds: Double = 1.5
    public static let capFallDBPerSecond: Double = 10

    public private(set) var levelDB = BandLevels.floorDB
    public private(set) var capDB = BandLevels.floorDB
    private var capHeldSeconds: Double = 0
    private var lastSeconds: Double = .nan

    public init() {}

    /// Moves the bar on to `db` at `seconds`. The first update after `init` or `reset`, and one
    /// whose clock is NaN or ran backwards, counts no time.
    public mutating func update(_ db: Double, atSeconds seconds: Double) {
        var dt = seconds - lastSeconds
        if !dt.isFinite || dt < 0 { dt = 0 }
        if seconds.isFinite { lastSeconds = seconds }
        update(db, elapsed: dt)
    }

    /// Moves the bar on by one row `dt` seconds after the last. NaN is silence.
    public mutating func update(_ db: Double, elapsed dt: Double) {
        let db = db.isNaN ? BandLevels.floorDB : db
        let s = max(dt, 0)
        levelDB = db >= levelDB ? db : max(db, levelDB - Self.releaseDBPerSecond * s)
        if db >= capDB {
            capDB = db
            capHeldSeconds = 0
        } else {
            capHeldSeconds += s
            // A microsecond of slack, so a hold summed from row intervals (thirty of 0.05 s is
            // 1.5000000000000002) does not end a row early from rounding.
            if capHeldSeconds > Self.capHoldSeconds + 1e-6 {
                capDB = max(levelDB, capDB - Self.capFallDBPerSecond * s)
            }
        }
    }

    /// Back to silence, with no cap and no time: the next update rises from the floor.
    public mutating func reset() {
        self = LevelBar()
    }
}
