// SPDX-License-Identifier: GPL-3.0-or-later

// A live decode job's watch on its capture's stream. A job with no records is legitimately quiet:
// nothing on the air decodes to nothing (DEC-16). A capture that says it is streaming and
// delivers no blocks is something else, a radio that has stopped, and a job reading it would
// otherwise run RUNNING, "no records yet", for as long as anyone waits. So the job counts the
// blocks the device hands the capture and goes DEGRADED when the count stops moving.

import EngineCore
import Foundation

/// How a job reads its capture's stream on each look.
struct StreamProgress: Sendable {
    /// Blocks the device has handed the capture (`CaptureStats.blocksReceived`).
    var blocks: UInt64
    /// `CaptureSnapshot.tuningGeneration`: a rate change stops and restarts the device's stream,
    /// so the quiet while it does is not a stall.
    var generation: UInt64
    /// A detached capture is away, which the job says in its own words.
    var detached: Bool
    /// The radio's model, for the detail.
    var radio: String
}

/// The stall rule, kept apart from the runners so a test can drive it with its own clock.
struct StreamStall: Sendable {
    /// How long a capture may deliver nothing before the job says so. The slowest stream a radio
    /// here makes is an RTL-SDR at 250 kS/s, whose 16384-sample USB transfers arrive every 66 ms,
    /// and a file device plays 16384-sample blocks at the file's rate, every 341 ms at 48 kS/s.
    /// Five seconds is fifteen of the slowest file blocks and seventy-five of the slowest dongle
    /// transfers, and it is longer than the bounded stop a rate change waits on (about 4 s), so an
    /// rtl_tcp link that hiccups or a stream that restarts does not read as a dead radio.
    static let defaultAfter: Duration = .seconds(5)

    let after: Duration
    private var blocks: UInt64?
    private var generation: UInt64 = 0
    private var since: ContinuousClock.Instant?
    /// The seconds the detail names, fixed when the stall is first reported so the detail does not
    /// change, and publish an event, on every look.
    private var quietSeconds: Int?

    init(after: Duration = StreamStall.defaultAfter) {
        self.after = after
    }

    /// The DEGRADED detail, "no samples from <radio> for N s", or nil while blocks arrive.
    mutating func look(_ p: StreamProgress, now: ContinuousClock.Instant = .now) -> String? {
        if p.detached || p.blocks != blocks || p.generation != generation || since == nil {
            blocks = p.blocks
            generation = p.generation
            since = now
            quietSeconds = nil
            return nil
        }
        guard let since, now - since >= after else { return nil }
        let quiet = quietSeconds ?? Int((now - since).components.seconds)
        quietSeconds = quiet
        return "no samples from \(p.radio) for \(quiet) s"
    }
}

extension SessionStore {
    /// Where a capture's stream stands, for `StreamStall`; nil when the capture is gone.
    func streamProgress(_ id: CaptureID) async -> StreamProgress? {
        guard let entry = captures[id] else { return nil }
        let snapshot = await entry.engine.snapshot
        let radio = devices[entry.deviceID]?.model ?? "the radio"
        return StreamProgress(blocks: entry.engine.stats.blocksReceived, generation: snapshot.tuningGeneration,
                              detached: snapshot.detached, radio: radio)
    }
}
