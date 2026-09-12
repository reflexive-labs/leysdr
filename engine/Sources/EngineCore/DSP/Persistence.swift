// SPDX-License-Identifier: GPL-3.0-or-later

// Persistence (phosphor) accumulation: docs/design-band-watching.md.
//
// A 2D histogram of the spectrum -- for each frequency bin, how often each level has been seen
// lately. It answers "what is usually here" where an FFT row answers "what is here now", and it is
// the one band view that needs no fine time resolution: it accumulates over time instead of
// resolving it, which is what makes an intermittent ISM signal visible at a couple of rows a second.

import Foundation

/// Counts of (bin, level) pairs, decayed so that "usual" means "usual lately".
///
/// Fed from the FFT ladder as an ordinary sink, so the transform is shared rather than duplicated.
///
/// `add` takes a lock, which the hot path otherwise never does. Its only caller
/// (`PersistenceFrameSink`) calls `add` and `snapshot` back to back from the same `write`, itself
/// invoked from the DSP thread, so the lock guards a histogram that one thread both folds into and
/// reads: uncontended, and cheap enough that the safety is worth the pair of atomics.
public final class PersistenceAccumulator: @unchecked Sendable {
    public let bins: Int
    public let levels: Int
    public let floorDB: Double
    public let rangeDB: Double
    /// Rows after which every count is halved.
    public let rowsPerHalfLife: Int

    private let counts: UnsafeMutablePointer<UInt16>
    private let lock = NSLock()
    private var rowsSinceHalving = 0
    private var rowsSeen: UInt64 = 0

    /// `halfLifeRows` is how many accumulated rows halve the counts. A half-life in seconds is the
    /// caller's to convert, because only it knows the row rate the ladder settled on.
    public init(bins: Int, levels: Int, floorDB: Double, rangeDB: Double, halfLifeRows: Int) {
        precondition(bins > 0 && levels > 0 && rangeDB > 0 && halfLifeRows > 0)
        self.bins = bins
        self.levels = levels
        self.floorDB = floorDB
        self.rangeDB = rangeDB
        rowsPerHalfLife = halfLifeRows
        counts = UnsafeMutablePointer<UInt16>.allocate(capacity: bins * levels)
        counts.initialize(repeating: 0, count: bins * levels)
    }

    deinit { counts.deallocate() }

    /// Rows folded in so far.
    public var rows: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return rowsSeen
    }

    /// Fold one FFT row in. `row` is dB, one value per bin; a row of a different length is folded
    /// by nearest bin so the ladder's size and the histogram's need not match.
    public func add(row: UnsafeBufferPointer<Float>) {
        guard let src = row.baseAddress, row.count > 0 else { return }
        let sp = Signpost.begin(.persistenceAdd)
        defer { Signpost.end(.persistenceAdd, sp) }
        lock.lock()
        defer { lock.unlock() }
        let scale = Double(levels) / rangeDB
        for b in 0 ..< bins {
            // Nearest source bin: the half-bin term rounds instead of flooring, which would bias
            // every cell toward its lower-frequency neighbour. Equal sizes make this the identity.
            let s = row.count == bins ? b : min(row.count - 1, (b * row.count + bins / 2) / bins)
            let db = Double(src[s])
            guard db.isFinite else { continue }
            var l = Int((db - floorDB) * scale)
            if l < 0 { l = 0 }
            if l >= levels { l = levels - 1 }
            let i = b * levels + l
            // Saturate rather than wrap: a count that rolled over would draw a permanent signal as
            // an empty cell, which is the most misleading thing this could possibly do.
            if counts[i] < UInt16.max { counts[i] &+= 1 }
        }
        rowsSeen &+= 1
        rowsSinceHalving += 1
        if rowsSinceHalving >= rowsPerHalfLife {
            rowsSinceHalving = 0
            for i in 0 ..< (bins * levels) { counts[i] >>= 1 }
        }
    }

    /// Copy the histogram out as little-endian uint16, bin-major. `into` must hold
    /// `bins * levels * 2` bytes; returns the bytes written.
    @discardableResult
    public func snapshot(into out: UnsafeMutableRawBufferPointer) -> Int {
        let need = bins * levels * 2
        guard out.count >= need, let base = out.baseAddress else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let dst = base.assumingMemoryBound(to: UInt8.self)
        for i in 0 ..< (bins * levels) {
            let v = counts[i]
            dst[2 * i] = UInt8(truncatingIfNeeded: v)
            dst[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        return need
    }

    /// Largest count in the histogram, which is what a renderer normalises against.
    public var peak: UInt16 {
        lock.lock(); defer { lock.unlock() }
        var m: UInt16 = 0
        for i in 0 ..< (bins * levels) where counts[i] > m { m = counts[i] }
        return m
    }
}
