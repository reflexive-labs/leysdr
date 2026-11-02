// SPDX-License-Identifier: Apache-2.0

// The entity fold, the Swift port of `go/pkg/records/table.go`: decode records in, one row per
// `device_id` out, aged by the decoder's silence timeout. Interpretation state lives in the client
// (docs/design/decoders.md, section 3, "The state boundary"), and the app does not link Go, so
// the fold is ported and both are pinned by testdata/decoders/fold-*.json. A row also keeps the
// transmitter's last positions, the trail the Decoders place's map draws.

import Foundation
import LeylineProto

/// One position of a transmitter's trail, with the table's clock when it arrived.
public struct TrailPoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var at: Date

    public init(latitude: Double, longitude: Double, at: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.at = at
    }
}

/// One transmitter as the fold has built it: the newest value of every field it has sent, its
/// last position and the positions before it, its newest record's kind and summary, how many
/// records it has been in, and when its first and newest records reached the table.
public struct DecoderEntity: Sendable, Equatable, Identifiable {
    public var deviceID: String
    public var protocolName: String
    public var kind: String
    public var summary: String
    /// The newest value of every field, merged across records: a vessel's name from its static
    /// report stays while its position reports arrive.
    public var fields: [String: Leyline_V1_FieldValue]
    public var position: Leyline_V1_Position?
    /// The last `EntityTable.trailLength` positions, oldest first; a report at the position
    /// before it adds none.
    public var trail: [TrailPoint]
    /// The newest record's `time`, which the inspector dates through an anchor.
    public var lastTime: Leyline_V1_SampleTime?
    public var firstHeard: Date
    public var lastHeard: Date
    public var count: Int

    public var id: String { deviceID }

    /// The entity as one record, for rendering a template over it: its id, last kind and
    /// position, and the newest value of every field. No signal levels, which belong to one
    /// packet and not to the transmitter.
    public var record: Leyline_V1_DecodeRecord {
        var r = Leyline_V1_DecodeRecord()
        r.protocol = protocolName
        r.deviceID = deviceID
        r.kind = kind
        if let position { r.position = position }
        r.fields = fields
        r.rssiDbfs = .nan
        r.snrDb = .nan
        return r
    }

    /// The direction the transmitter is moving or pointing, from the first of the fields
    /// decoders send for it that it has sent (`track_deg` for aircraft, `cog_deg` for vessels,
    /// `course_deg` for APRS), for the map's marker; nil when it sent none.
    public var heading: Double? {
        for name in EntityTable.headingFields {
            if let v = RecordSummary.number(record, name), v.isFinite { return v }
        }
        return nil
    }
}

/// The fold. A value: the session holds one per decoder page and applies records on the main
/// actor, the test applies the vectors' steps.
public struct EntityTable: Sendable, Equatable {
    /// How many positions a trail keeps.
    public static let trailLength = 50
    /// The fields a heading is read from, in order.
    public static let headingFields = ["track_deg", "course_deg", "cog_deg", "heading_deg"]

    /// The decoder's display, whose templates write each row's summary; nil keeps
    /// `RecordSummary`'s line.
    public var display: Leyline_V1_DecoderDisplay?
    public private(set) var entities: [String: DecoderEntity] = [:]

    public init(display: Leyline_V1_DecoderDisplay? = nil) {
        self.display = display
    }

    /// Folds one record in at `at`, the table's clock (when it reached this client, or for a
    /// stored record its own wall time), and returns the row it landed on. A record with no
    /// `device_id` makes no row: the protocol has no identity concept.
    @discardableResult
    public mutating func apply(_ rec: Leyline_V1_DecodeRecord, at: Date) -> DecoderEntity? {
        let id = rec.deviceID
        guard !id.isEmpty else { return nil }
        var e =
            entities[id]
            ?? DecoderEntity(
                deviceID: id, protocolName: rec.protocol, kind: "", summary: "", fields: [:],
                position: nil, trail: [], lastTime: nil, firstHeard: at, lastHeard: at, count: 0)
        if e.protocolName.isEmpty { e.protocolName = rec.protocol }
        for (name, v) in rec.fields { e.fields[name] = v }
        if rec.hasPosition {
            e.position = rec.position
            let p = rec.position
            if p.latitude.isFinite, p.longitude.isFinite,
                e.trail.last.map({ $0.latitude != p.latitude || $0.longitude != p.longitude })
                    ?? true
            {
                e.trail.append(TrailPoint(latitude: p.latitude, longitude: p.longitude, at: at))
                if e.trail.count > Self.trailLength {
                    e.trail.removeFirst(e.trail.count - Self.trailLength)
                }
            }
        }
        e.kind = rec.kind
        e.summary = DisplayTemplate.summary(display, record: rec)
        if rec.hasTime { e.lastTime = rec.time }
        e.lastHeard = at
        e.count += 1
        entities[id] = e
        return e
    }

    /// Drops every entity silent for longer than `silence` seconds at `now`, and returns how many
    /// went. Zero means never, which is what a manifest's `entity_silence_s` of 0 declares.
    @discardableResult
    public mutating func expire(now: Date, silence: TimeInterval) -> Int {
        guard silence > 0 else { return 0 }
        let gone = entities.values.filter { now.timeIntervalSince($0.lastHeard) > silence }
        for e in gone { entities[e.deviceID] = nil }
        return gone.count
    }

    /// The entities newest first, ties broken by device id so a redraw of an unchanged table does
    /// not reorder rows.
    public var rows: [DecoderEntity] {
        entities.values.sorted {
            $0.lastHeard != $1.lastHeard ? $0.lastHeard > $1.lastHeard : $0.deviceID < $1.deviceID
        }
    }

    /// A row's name: the display's `entity_name` over the row, else its `device_id`.
    public func name(of e: DecoderEntity, label: String = "") -> String {
        DisplayTemplate.entityName(display, record: e.record, label: label)
    }

    /// One of the display's columns for a row, as a template prints it; nil when the row has not
    /// sent it.
    public func column(_ name: String, of e: DecoderEntity, label: String = "") -> String? {
        DisplayTemplate.column(name, record: e.record, label: label)
    }
}
