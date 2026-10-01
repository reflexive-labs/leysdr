// SPDX-License-Identifier: GPL-3.0-or-later

// The status detail a running decode job reports between state changes. A job read RUNNING
// whether its decoder had produced a thousand records or none, and a client could not tell a
// working decoder from one that had produced nothing without subscribing to its records; an agent
// testing `ley mcp` fell back to `ps` to check the plugin was alive. The count and the age of the
// last record go in `Job.status_detail` (the proto's own example is "3 gaps logged"), refreshed on
// a timer rather than per record so the event stream is not flooded: the first record is published
// at once, and after that the detail updates every `interval` while records are arriving. A job
// with no records stays RUNNING (docs/plans/decoders.md, DEC-16), and the detail shows the count
// (DEC-23).

import Foundation

struct DecodeLiveness: Sendable {
    /// How often a moving count is republished. Two seconds is fast enough that `ley jobs` typed
    /// after a packet shows it, and slow enough that a busy decoder does not flood the event stream
    /// with one event per record.
    static let interval: Duration = .seconds(2)

    private(set) var records: UInt64 = 0
    private var lastRecord: ContinuousClock.Instant?
    private var published: UInt64 = 0

    /// Notes one delivered record. Returns true when this is the first, which is published at once.
    mutating func noteRecord() -> Bool {
        records += 1
        lastRecord = .now
        return records == 1
    }

    /// Whether the count has moved since the detail was last published.
    var moved: Bool { records != published }

    /// The detail to publish now, and marks it published.
    mutating func publish(decoder: String) -> String {
        published = records
        return detail(decoder: decoder)
    }

    /// The running job's status detail: the decoder, the record count and the last record's age.
    func detail(decoder: String) -> String {
        guard records > 0, let last = lastRecord else {
            return "decoding with \(decoder): no records yet"
        }
        let ago = Int((ContinuousClock.now - last).components.seconds)
        let noun = records == 1 ? "record" : "records"
        let when = ago < 2 ? "just now" : "\(ago) s ago"
        return "decoding with \(decoder): \(records) \(noun), last \(when)"
    }
}
