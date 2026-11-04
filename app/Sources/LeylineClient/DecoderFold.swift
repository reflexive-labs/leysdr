// SPDX-License-Identifier: Apache-2.0

// One decoder page's records and what they fold into, as the session keeps it for the session's
// life: the record log, the transmitters, whether the history landed, and the map's camera rule.
// It is never rebuilt: a tab switch, a job event, the plan's clock and a selection do not touch
// it, and a history read again (the stream reopened after an error or a daemon restart) merges by
// `record_id` into what is held. Only `entity_silence_s` removes a transmitter, trail and all.

import Foundation
import LeylineProto

public struct DecoderFold: Sendable, Equatable {
    public private(set) var records = RecordLog()
    public private(set) var table: EntityTable
    /// Whether a history has landed, and whether the daemon cut the last one at its limit.
    public private(set) var historyLoaded = false
    public private(set) var historyTruncated = false
    /// The map's camera rule (`MapFraming`), moved as positions arrive.
    public private(set) var framing = MapFraming()

    public init(display: Leyline_V1_DecoderDisplay? = nil) {
        table = EntityTable(display: display)
    }

    /// The decoder's display, read again with the manifests.
    public mutating func setDisplay(_ d: Leyline_V1_DecoderDisplay?) {
        table.display = d
    }

    /// A `QueryRecords` page: the records not already held join the log and fold in oldest
    /// first, after whatever the live feed folded. One older than everything a full log holds is
    /// one the fold may have counted before the log let it go, so it is not folded again.
    /// Returns how many were new.
    @discardableResult
    public mutating func landHistory(_ entries: [RecordEntry], truncated: Bool) -> Int {
        let added = records.insert(entries).filter { records.holds($0.id) }
        for e in added.sorted(by: { $0.at < $1.at }) { table.merge(e.record, at: e.at) }
        historyLoaded = true
        historyTruncated = truncated
        reframe()
        return added.count
    }

    /// One live record; false when it was held already.
    @discardableResult
    public mutating func landLive(_ entry: RecordEntry) -> Bool {
        let added = records.insert([entry]).filter { records.holds($0.id) }
        for e in added { table.merge(e.record, at: e.at) }
        if !added.isEmpty, entry.record.hasPosition { reframe() }
        return !added.isEmpty
    }

    /// Ages transmitters out at `silence`; returns how many went. The map does not move.
    @discardableResult
    public mutating func expire(now: Date, silence: TimeInterval) -> Int {
        table.expire(now: now, silence: silence)
    }

    /// The newest position of every transmitter that has one.
    public var positions: [MapCoordinate] {
        table.entities.values.compactMap { e in
            guard let p = e.position, p.latitude.isFinite, p.longitude.isFinite else { return nil }
            return MapCoordinate(latitude: p.latitude, longitude: p.longitude)
        }
    }

    /// The person moved the map.
    public mutating func personMoved(to visible: MapRegion) {
        framing.personMoved(to: visible)
    }

    /// Fit All.
    public mutating func fitAll() {
        framing.fitAll(positions)
    }

    private mutating func reframe() {
        framing.update(positions)
    }
}
