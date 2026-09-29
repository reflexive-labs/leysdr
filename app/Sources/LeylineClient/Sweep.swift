// SPDX-License-Identifier: Apache-2.0

// Scan band as the window reads it (docs/design/channels.md, "Scan the band"): the scan job the
// band row starts, the row's words while it runs, the hits kept from the finished `Scan` and the
// coverage note under them. The sweep is `ley scan --band`'s, one shot with take-over on the
// window's own radio, so the allocator borrows the window's capture rather than a second radio
// a watch or another window is using; the pause that makes the borrow safe (the sink detached,
// the channel destroyed, the centre events ignored until the terminal event) is the session's,
// not this file's. Everything here is pure so the rules have Linux tests, and the words are
// `ley scan`'s (`go/internal/cli/scan.go`: `scanIDOf`, `coverageNote`) so the two clients say
// the same thing about the same sweep.

import Foundation
import LeylineProto

public enum Sweep {
    /// `ley scan --band`'s config on the window's radio: the band's own edges, or the whole span
    /// of a group's parts (GMRS's two halves, 462.5375 to 467.7375 MHz, gap included; the gap's
    /// hits are dropped afterwards by `SweepResult`), swept once, taking the radio over, on
    /// `deviceID`. The device id is what makes the take-over borrow the window's capture and
    /// not another client's radio. A group whose parts are not all in `bands` falls back to its
    /// own edges, which the table keeps equal to the parts' span.
    public static func config(for band: Band, in bands: [Band] = Bands.builtIn, deviceID: String)
        -> Leyline_V1_ScanConfig
    {
        let span = self.span(of: band, in: bands)
        return .with {
            $0.range.minHz = span.lowerBound
            $0.range.maxHz = span.upperBound
            $0.once = true
            $0.takeOver = true
            $0.deviceID = deviceID
        }
    }

    /// `config(for:in:deviceID:)` as the `StartJob` request that carries it.
    public static func request(
        for band: Band, in bands: [Band] = Bands.builtIn, deviceID: String
    ) -> Leyline_V1_StartJobRequest {
        .with { $0.scan = config(for: band, in: bands, deviceID: deviceID) }
    }

    /// The scan's id from the job's `ley://scans/<id>` result URI, as `ley`'s `scanIDOf` reads
    /// it; nil when the job names no scan, which a job of another kind does not.
    public static func scanID(of job: Leyline_V1_Job) -> String? {
        for uri in job.resultUris where uri.hasPrefix(scanURIPrefix) {
            let id = String(uri.dropFirst(scanURIPrefix.count))
            if !id.isEmpty { return id }
        }
        return nil
    }

    static let scanURIPrefix = "ley://scans/"

    /// The band's edges, or the lowest and highest edge of a group's parts.
    static func span(of band: Band, in bands: [Band]) -> ClosedRange<UInt64> {
        let parts = self.parts(of: band, in: bands)
        guard let lo = parts.map(\.minHz).min(), let hi = parts.map(\.maxHz).max(), lo <= hi
        else { return band.minHz...band.maxHz }
        return lo...hi
    }

    /// Where a detection must lie to count for `band`: the band itself, or each part of a group,
    /// so a hit in the gap between GMRS's halves is dropped for the reason MURS is two halves
    /// (the plan's KTD11). A group none of whose parts resolves counts as one range.
    static func ranges(of band: Band, in bands: [Band]) -> [ClosedRange<UInt64>] {
        let parts = self.parts(of: band, in: bands)
        guard !parts.isEmpty else { return [band.minHz...band.maxHz] }
        return parts.map { $0.minHz...$0.maxHz }
    }

    /// A group's parts as bands, in the group's order; empty for a plain band.
    private static func parts(of band: Band, in bands: [Band]) -> [Band] {
        band.parts.compactMap { Bands.resolve($0, in: bands) }
    }
}

/// A running sweep as the row reads the job's `status_detail`: `sweeping n steps` before the
/// first hop and `step k/n, m found` after each (`JobStore.swift` in the engine writes both),
/// so `steps` is the count once either has arrived and the row prints `Sweeping 2 m amateur,
/// 7 steps…`. A detail in neither shape (`starting`) is shown verbatim, the design's fallback.
public struct SweepProgress: Sendable, Hashable {
    /// The daemon's line as it came.
    public var detail: String
    /// The hops the sweep plans, from either shape; nil until the daemon has said.
    public var steps: Int?
    /// The hop just finished, from `step k/n`; nil before the first.
    public var step: Int?
    /// Detections so far, from `m found`; nil before the first hop.
    public var found: Int?

    public init(statusDetail: String) {
        detail = statusDetail
        let words = statusDetail.split(separator: " ").map(String.init)
        if words.count == 3, words[0] == "sweeping", let n = Int(words[1]),
            words[2] == "steps" || words[2] == "step"
        {
            steps = n
        } else if words.count == 4, words[0] == "step", words[3] == "found",
            let m = Int(words[2])
        {
            // `3/7,` splits at the slash; the comma belongs to the sentence, not the number.
            let fraction = words[1].split(separator: "/").map(String.init)
            if fraction.count == 2, let k = Int(fraction[0]),
                let n = Int(fraction[1].trimmingCharacters(in: CharacterSet(charactersIn: ",")))
            {
                step = k
                steps = n
                found = m
            }
        }
    }

    /// The row's line while the sweep runs: `Sweeping 2 m amateur, 7 steps…` once the step count
    /// is known, else the detail verbatim.
    public func words(band: Band) -> String {
        guard let steps else { return detail }
        return "Sweeping \(band.name), \(steps == 1 ? "1 step" : "\(steps) steps")…"
    }
}

/// One detection the sweep kept, as the expanded row and the rail draw it: named by the plan
/// channel it sits on within `Plans.toleranceHz`, else by its frequency, and identified by its
/// frequency because a scan reports one detection per carrier.
public struct SweepHit: Sendable, Hashable, Identifiable {
    public var hz: UInt64
    public var snrDb: Double
    public var bandwidthHz: UInt32
    /// The spectrum rows in which the carrier cleared the threshold, of those that covered it
    /// (`Detection.looks`, `looks_possible`): 8/8 is a repeater, 1/8 a burst.
    public var looks: UInt32
    public var looksPossible: UInt32
    /// The radio-printed name of the plan channel the hit is on (`Plans.name(at:)`), or nil.
    public var name: String?

    public var id: UInt64 { hz }

    /// What the row prints: the channel's name, else the frequency in the words a bookmark made
    /// there would carry (`BookmarkNaming.frequencyWords`).
    public var label: String { name ?? BookmarkNaming.frequencyWords(hz) }

    public init(
        hz: UInt64, snrDb: Double, bandwidthHz: UInt32, looks: UInt32, looksPossible: UInt32,
        name: String?
    ) {
        self.hz = hz
        self.snrDb = snrDb
        self.bandwidthHz = bandwidthHz
        self.looks = looks
        self.looksPossible = looksPossible
        self.name = name
    }
}

/// What a finished sweep found for one band: the detections inside it (inside any part, for a
/// group), strongest first, and the range the sweep really looked at, from which the row appends
/// `ley scan`'s coverage note when it is narrower than the band.
public struct SweepResult: Sendable, Hashable {
    /// Strongest first; two of one SNR keep the scan's order.
    public var hits: [SweepHit]
    /// `Scan.covered` when the daemon set it: never wider than the request, narrower when the
    /// radio could not tune all of it or the sweep was stopped early.
    public var covered: ClosedRange<UInt64>?

    /// The one line for a sweep that found nothing (docs/design/channels.md, "Scan the band").
    public static let emptyWords =
        "Nothing on the air right now; repeaters and towers key up briefly"

    /// Edge rounding within this is not reported as a gap: `ley scan`'s `coverageNote` slack.
    static let coverageSlackHz: UInt64 = 1_000

    public init(hits: [SweepHit], covered: ClosedRange<UInt64>?) {
        self.hits = hits
        self.covered = covered
    }

    public init(scan: Leyline_V1_Scan, band: Band, in bands: [Band] = Bands.builtIn) {
        let ranges = Sweep.ranges(of: band, in: bands)
        let kept = scan.detections.enumerated().filter { _, d in
            ranges.contains { $0.contains(d.centerHz) }
        }
        // The index breaks ties so equal SNRs keep the scan's order whatever the sort's own
        // stability.
        hits = kept.sorted { a, b in
            a.element.snrDb != b.element.snrDb
                ? a.element.snrDb > b.element.snrDb : a.offset < b.offset
        }
        .map { _, d in
            SweepHit(
                hz: d.centerHz, snrDb: d.snrDb, bandwidthHz: d.bandwidthHz, looks: d.looks,
                looksPossible: d.looksPossible, name: Plans.name(at: d.centerHz, in: bands))
        }
        covered =
            scan.hasCovered && scan.covered.maxHz > scan.covered.minHz
            ? scan.covered.minHz...scan.covered.maxHz : nil
    }

    /// `ley scan`'s coverage note (`coverageNote` in `go/internal/cli/scan.go`), word for word:
    /// `covered 144.920 MHz to 147.080 MHz of the 144.000 MHz to 148.000 MHz asked for`, when the
    /// sweep looked at less than the band by more than `coverageSlackHz` at either edge; nil when
    /// it covered the band or the daemon reported no range. The frequencies are the words
    /// `FormatFrequency` prints them in.
    public func coverageWords(band: Band, in bands: [Band] = Bands.builtIn) -> String? {
        guard let covered else { return nil }
        let asked = Sweep.span(of: band, in: bands)
        let slack = Self.coverageSlackHz
        if covered.lowerBound <= asked.lowerBound + slack,
            covered.upperBound + slack >= asked.upperBound
        {
            return nil
        }
        let words = BookmarkNaming.frequencyWords
        return "covered \(words(covered.lowerBound)) to \(words(covered.upperBound)) of the "
            + "\(words(asked.lowerBound)) to \(words(asked.upperBound)) asked for"
    }
}

/// The band row's state for one sweep job, from the job's state and, once it has finished, its
/// `Scan`: the progress words while it runs, the hits or the empty line when it completed, the
/// status detail in `caution` when it failed, and nothing when it was cancelled (a tune elsewhere
/// or Stop), since the row then shows what it did before.
public enum SweepOutcome: Sendable, Hashable {
    case running(SweepProgress)
    case found(SweepResult)
    case empty(SweepResult)
    case failed(detail: String)
    case cancelled

    /// The outcome of `job` for `band`. RUNNING and DEGRADED are running; COMPLETED with its
    /// `scan` is found or empty by the hits kept for the band; FAILED carries the status detail,
    /// the daemon's reason (`JobStore.finish` writes the allocator's decline there), or the
    /// error's message when the detail is empty; CANCELLED is cancelled. Nil for a completed job
    /// whose scan has not been fetched yet, and for a state the contract does not name.
    public static func from(
        job: Leyline_V1_Job, scan: Leyline_V1_Scan?, band: Band, in bands: [Band] = Bands.builtIn
    ) -> SweepOutcome? {
        switch job.state {
        case .running, .degraded:
            return .running(SweepProgress(statusDetail: job.statusDetail))
        case .completed:
            guard let scan else { return nil }
            let result = SweepResult(scan: scan, band: band, in: bands)
            return result.hits.isEmpty ? .empty(result) : .found(result)
        case .failed:
            let detail = job.statusDetail.isEmpty ? job.error.message : job.statusDetail
            return .failed(detail: detail.isEmpty ? job.error.code : detail)
        case .cancelled:
            return .cancelled
        case .unspecified, .UNRECOGNIZED:
            return nil
        }
    }
}
