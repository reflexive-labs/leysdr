// SPDX-License-Identifier: Apache-2.0

// The band table, read from the seed file `ley bands --json` generates (docs/design/channels.md,
// "Bands and bookmarks are files"). The table is Go's; this is a copy checked in as a resource and
// drift-tested from Go, so the app and `ley` name the same bands with the same defaults and neither
// has a table of its own. A band holds its range, the default mode and bandwidth for a newcomer,
// and the step the arrow keys tune by. A band may also carry its channel plan
// (docs/design/channels.md, "The plan is data in the band table"): a list, never `min_hz + n ×
// step_hz`, because CB skips and reorders, marine pairs ship and coast, and GMRS numbers across
// both halves, which is why a group's plan hangs off the group. `Plans` holds the lookups both
// clients answer the same way, mirroring `go/pkg/leyline`.

import Foundation
import LeylineProto

/// One entry of a band's plan: what the service's radios print (`WX3`, `16`, `ch5`) and the
/// aliases that reach it, the plan-prefixed one first (`wx3`, `marine16`). `mode` and
/// `bandwidthHz` are set only where the channel differs from its band (MURS 4 and 5 are 20 kHz
/// wide); `decoder` names the daemon decoder the channel's data wants (`aprs`, `ais`, `same`).
public struct PlanChannel: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var aliases: [String]
    public var hz: UInt64
    /// The mode's lower-case name as `ley bands` prints it, or empty for the band's.
    public var mode: String
    /// Zero for the band's.
    public var bandwidthHz: UInt32
    public var note: String
    public var decoder: String

    enum CodingKeys: String, CodingKey {
        case name, aliases, hz, mode, note, decoder
        case bandwidthHz = "bandwidth_hz"
    }

    public init(
        name: String, aliases: [String], hz: UInt64, mode: String = "", bandwidthHz: UInt32 = 0,
        note: String = "", decoder: String = ""
    ) {
        self.name = name
        self.aliases = aliases
        self.hz = hz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.note = note
        self.decoder = decoder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        hz = try c.decode(UInt64.self, forKey: .hz)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        bandwidthHz = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.decoder = try c.decodeIfPresent(String.self, forKey: .decoder) ?? ""
    }

    /// The plan-prefixed alias, which is unique across every plan where a name (`1`, `16`) is
    /// not.
    public var id: String { aliases.first ?? name }
}

public struct Band: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    /// What `--band` accepts; the first is the canonical short form and the id.
    public var aliases: [String]
    public var minHz: UInt64
    public var maxHz: UInt64
    /// The mode's lower-case name as `ley bands` prints it, or `usb/lsb` where the sideband
    /// follows the frequency (the HF amateur segments). `mode(at:)` resolves it.
    public var mode: String
    public var bandwidthHz: UInt32
    /// The arrow-key tuning step: channel spacing, which is not the bandwidth (airband is
    /// 10 kHz wide per channel and spaced 25 kHz).
    public var stepHz: UInt32
    public var note: String
    /// The bands a group is made of; empty on a plain band.
    public var parts: [String]
    /// The band's own plan in plan order; empty on a band with none and on a part of a group,
    /// whose plan is the group's (`plan(in:)`).
    public var channels: [PlanChannel]

    enum CodingKeys: String, CodingKey {
        case name, aliases, mode, note, parts, channels
        case minHz = "min_hz"
        case maxHz = "max_hz"
        case bandwidthHz = "bandwidth_hz"
        case stepHz = "step_hz"
    }

    public init(
        name: String, aliases: [String], minHz: UInt64, maxHz: UInt64, mode: String,
        bandwidthHz: UInt32, stepHz: UInt32, note: String = "", parts: [String] = [],
        channels: [PlanChannel] = []
    ) {
        self.name = name
        self.aliases = aliases
        self.minHz = minHz
        self.maxHz = maxHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.stepHz = stepHz
        self.note = note
        self.parts = parts
        self.channels = channels
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        minHz = try c.decode(UInt64.self, forKey: .minHz)
        maxHz = try c.decode(UInt64.self, forKey: .maxHz)
        mode = try c.decode(String.self, forKey: .mode)
        bandwidthHz = try c.decodeIfPresent(UInt32.self, forKey: .bandwidthHz) ?? 0
        stepHz = try c.decodeIfPresent(UInt32.self, forKey: .stepHz) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        parts = try c.decodeIfPresent([String].self, forKey: .parts) ?? []
        channels = try c.decodeIfPresent([PlanChannel].self, forKey: .channels) ?? []
    }

    public var id: String { aliases.first ?? name }
    public var isGroup: Bool { !parts.isEmpty }
    public var widthHz: UInt64 { maxHz - minHz }
    /// Where a view showing the whole band puts the radio, as `ley` does.
    public var centerHz: UInt64 { minHz + widthHz / 2 }
    public func contains(_ hz: UInt64) -> Bool { hz >= minHz && hz <= maxHz }

    /// Fine tuning is a tenth of the step and never below 100 Hz.
    public var fineStepHz: UInt32 { max(100, stepHz / 10) }

    /// The demodulator at `hz`: the band's own, or the amateur convention where the table says
    /// the sideband follows the frequency (LSB below 10 MHz, USB from there up).
    public func mode(at hz: UInt64) -> Leyline_V1_DemodMode {
        if let m = Leyline_V1_DemodMode.named(mode) { return m }
        return Band.sideband(at: hz)
    }

    /// Whether the mode is a fixed one or `usb/lsb`, for a label that shows the pair.
    public var modeWord: String { Leyline_V1_DemodMode.named(mode)?.word ?? mode.uppercased() }

    public static func sideband(at hz: UInt64) -> Leyline_V1_DemodMode {
        hz >= 10_000_000 ? .usb : .lsb
    }

    /// The band whose plan answers for this one: itself, or the group it is a part of when it
    /// has no plan of its own, because GMRS's numbering spans both halves and the plan hangs off
    /// the group (docs/design/channels.md, "The plan is data in the band table"). Go's
    /// `planOwner` in `go/pkg/leyline/bands.go`.
    func planOwner(in bands: [Band]) -> Band {
        guard channels.isEmpty, let alias = aliases.first else { return self }
        return bands.first { $0.isGroup && $0.parts.contains(alias) } ?? self
    }

    /// The plan this band answers with: its own, else its group's when it is a part.
    public func plan(in bands: [Band] = Bands.builtIn) -> [PlanChannel] {
        planOwner(in: bands).channels
    }

    /// The channel's demodulator: its own where the plan sets one, else the band's at the
    /// channel's frequency, so an HF channel would follow the sideband rule. Go's `presetOf`.
    public func mode(of channel: PlanChannel) -> Leyline_V1_DemodMode {
        Leyline_V1_DemodMode.named(channel.mode) ?? mode(at: channel.hz)
    }

    /// The channel's width: its own where the plan sets one (MURS 4 and 5 are 20 kHz where the
    /// group is 11.25 kHz), else the band's.
    public func bandwidth(of channel: PlanChannel) -> UInt32 {
        channel.bandwidthHz != 0 ? channel.bandwidthHz : bandwidthHz
    }
}

public enum Bands {
    /// The seed file, decoded once. Empty only if the resource is missing, which the tests catch.
    public static let builtIn: [Band] = {
        guard let url = Bundle.module.url(forResource: "bands", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let bands = try? decode(data)
        else { return [] }
        return bands
    }()

    /// The plain bands in frequency order, without the groups (a group spans the gap between
    /// its parts and would label the empty spectrum there).
    public static var plain: [Band] { builtIn.filter { !$0.isGroup } }

    public static func decode(_ data: Data) throws -> [Band] {
        try JSONDecoder().decode([Band].self, from: data)
    }

    /// The band a frequency lies in, if any; groups are never answered.
    public static func band(containing hz: UInt64, in bands: [Band] = builtIn) -> Band? {
        bands.first { !$0.isGroup && $0.contains(hz) }
    }

    /// Lookup by name or alias: case-insensitive, spaces removed, so `2m` and `2 m amateur`
    /// reach the same entry.
    public static func resolve(_ name: String, in bands: [Band] = builtIn) -> Band? {
        let key = fold(name)
        return bands.first { fold($0.name) == key || $0.aliases.contains { fold($0) == key } }
    }

    /// The default mode at `hz`: the band's, sideband by frequency on HF, NFM when no
    /// band is recognised. `ley tune`'s rule (`go/pkg/leyline/bands.go`, `DefaultMode`).
    public static func defaultMode(at hz: UInt64, in bands: [Band] = builtIn)
        -> Leyline_V1_DemodMode
    {
        band(containing: hz, in: bands)?.mode(at: hz) ?? .nfm
    }

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

// MARK: Plans

/// The channel lookups both clients answer the same way (docs/design/channels.md, "The plan is
/// data in the band table" and "Bands are the spine of the sidebar"). Each mirrors a Go
/// function in `go/pkg/leyline` by name, and the Go tests pin the same frequencies.
public enum Plans {
    /// How far a frequency may sit from a plan channel and still be "on" it: the one tolerance
    /// the two lookups share, chosen so CB's 10 kHz spacing and GMRS's 12.5 kHz both resolve to
    /// the nearer channel (`channelTolerance` in `go/pkg/leyline/bands.go`).
    public static let toleranceHz: UInt64 = 6_000

    /// A plan drawn as ticks on the band rail has at most this many channels: NOAA, GMRS, MURS
    /// and CB are read as marks, marine's hundred at 25 kHz across 6 MHz would read as texture
    /// and stay in the picker (docs/design/channels.md, "Bands are the spine of the sidebar").
    public static let tickLimit = 24

    /// The plan channel nearest `hz` within `toleranceHz`, with the band or group whose plan
    /// holds it. Nearest, not first, because GMRS channels are only 12.5 kHz apart and a
    /// detection can sit inside the tolerance of two. Two entries at equal distance, which
    /// marine's US variants make common (`22A` and ITU `22` share 157.100 MHz), go to the
    /// earlier entry: the plain bands in table order, then the groups. Go's `ChannelAt`.
    public static func channel(at hz: UInt64, in bands: [Band] = Bands.builtIn) -> (
        band: Band, channel: PlanChannel
    )? {
        var best: (band: Band, channel: PlanChannel)?
        var bestDiff = toleranceHz
        for band in bands.filter({ !$0.isGroup }) + bands.filter({ $0.isGroup }) {
            for channel in band.channels {
                let diff = channel.hz > hz ? channel.hz - hz : hz - channel.hz
                if diff < bestDiff || (diff == bestDiff && best == nil) {
                    best = (band, channel)
                    bestDiff = diff
                }
            }
        }
        return best
    }

    /// What a bookmark made on `hz` is named after: the radio-printed name of the channel it
    /// sits on within `toleranceHz`, else nil and the caller names it after the frequency
    /// (one naming function for ⌘D, the pencil, a scan hit's ＋ and CHIRP).
    public static func name(at hz: UInt64, in bands: [Band] = Bands.builtIn) -> String? {
        channel(at: hz, in: bands)?.channel.name
    }

    /// A name typed with a band in hand: the radio-printed name (`16`, `WX3`, `24 coast`), with
    /// or without a leading zero, or any alias, against that band's plan. This is the
    /// band-context lookup, separate from `resolveGlobal`, which is why a channel may carry an
    /// alias equal to one of its band's. Go's `ResolvePlanChannel`.
    public static func resolve(_ name: String, in band: Band, bands: [Band] = Bands.builtIn)
        -> PlanChannel?
    {
        let key = channelKey(name)
        guard !key.isEmpty else { return nil }
        return band.plan(in: bands).first {
            channelKey($0.name) == key || $0.aliases.contains { channelKey($0) == key }
        }
    }

    /// A name typed with no band: a channel's name or alias, case-insensitive, across every
    /// plan, with the band or group that holds it. Bare digits never resolve here, so `16` is
    /// never ambiguous and never a frequency (`ResolvePreset`'s rule in
    /// `go/pkg/leyline/presets.go`); they resolve in band context through `resolve(_:in:)`.
    public static func resolveGlobal(_ name: String, in bands: [Band] = Bands.builtIn) -> (
        band: Band, channel: PlanChannel
    )? {
        let key = presetKey(name)
        guard !key.isEmpty, !key.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        for band in bands {
            for channel in band.channels
            where presetKey(channel.name) == key
                || channel.aliases.contains(where: { presetKey($0) == key })
            {
                return (band, channel)
            }
        }
        return nil
    }

    /// The channels the rail draws as ticks for `band`: its plan when it has `tickLimit`
    /// channels or fewer, and only the entries inside the band's own range, so a half of GMRS
    /// shows the group's channels that lie in it. Empty for a long plan or none.
    public static func ticks(for band: Band, in bands: [Band] = Bands.builtIn) -> [PlanChannel] {
        let plan = band.plan(in: bands)
        guard plan.count <= tickLimit else { return [] }
        return plan.filter { band.contains($0.hz) }
    }

    /// Go's `presetKey`: lower-cased and trimmed, spaces kept, so `24 coast` matches as typed.
    public static func presetKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Go's `channelKey`: `presetKey` with a leading zero dropped, so `06` and `6` both reach
    /// marine channel 6, which radios print either way.
    static func channelKey(_ s: String) -> String {
        var key = Substring(presetKey(s))
        while key.count > 1, key.first == "0", let second = key.dropFirst().first,
            second.isASCII, second.isNumber
        {
            key = key.dropFirst()
        }
        return String(key)
    }
}

extension Leyline_V1_DemodMode {
    /// The enum member for a name as `ley` prints it (`nfm`, `NFM`); nil for `usb/lsb` or an
    /// unknown word.
    public static func named(_ s: String) -> Leyline_V1_DemodMode? {
        switch s.uppercased() {
        case "AM": .am
        case "NFM": .nfm
        case "WFM": .wfm
        case "USB": .usb
        case "LSB": .lsb
        case "CW": .cw
        case "RAW_IQ": .rawIq
        default: nil
        }
    }

    /// The mode's display name.
    public var word: String {
        switch self {
        case .am: "AM"
        case .nfm: "NFM"
        case .wfm: "WFM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .rawIq: "raw IQ"
        default: "unspecified"
        }
    }

    /// The daemon's default channel bandwidth for the mode, mirroring the engine's
    /// `DemodMode.defaultBandwidthHz` through `ley`'s `DefaultBandwidth`.
    public var defaultBandwidthHz: UInt32 {
        switch self {
        case .am: 10_000
        case .nfm: 12_500
        case .wfm: 200_000
        case .usb, .lsb: 2_800
        case .cw: 500
        case .rawIq: 12_500
        default: 0
        }
    }

    /// The widths the transport bar offers for the mode, the default first.
    public var offeredBandwidthsHz: [UInt32] {
        switch self {
        case .nfm: [12_500, 25_000, 6_250]
        case .am: [10_000, 8_000, 6_000]
        case .wfm: [200_000, 150_000]
        case .usb, .lsb: [2_800, 2_400, 3_000]
        case .cw: [500, 250]
        default: []
        }
    }

    /// The enum's own name, as the bookmarks file and proto3 JSON spell it: `word` with the
    /// one difference that raw IQ is `RAW_IQ` on the wire.
    public var wireName: String {
        switch self {
        case .am: "AM"
        case .nfm: "NFM"
        case .wfm: "WFM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .rawIq: "RAW_IQ"
        default: "DEMOD_MODE_UNSPECIFIED"
        }
    }
}

// MARK: The rail

extension Band {
    /// `hz` on the band's grid: the nearest multiple of the step counted from the low edge, so a
    /// scrub along the rail lands on a channel of the band's plan rather than between two. A band
    /// with no step hands the frequency back.
    public func snapped(_ hz: UInt64) -> UInt64 {
        guard stepHz > 0 else { return hz }
        let step = UInt64(stepHz)
        let off = hz >= minHz ? hz - minHz : 0
        let n = (off + step / 2) / step
        return min(minHz + n * step, maxHz)
    }
}

extension Bands {
    /// The bands on either side of `range`, by frequency: the nearest one that ends at or below
    /// its low edge and the nearest that begins at or above its high edge, groups skipped. The
    /// rail labels these at its end caps, and a scrub past a cap crosses into them.
    public static func neighbours(of range: ClosedRange<UInt64>, in bands: [Band] = builtIn) -> (
        below: Band?, above: Band?
    ) {
        let plain = bands.filter { !$0.isGroup }
        let below = plain.filter { $0.maxHz <= range.lowerBound }.max { $0.maxHz < $1.maxHz }
        let above = plain.filter { $0.minHz >= range.upperBound }.min { $0.minHz < $1.minHz }
        return (below, above)
    }
}

// MARK: Neighbours and reach

extension Bands {
    /// Whether `band` sits close enough against `range` to be labelled its neighbour: the gap
    /// between them is no more than a tenth of `range`'s width. Marine VHF and NOAA weather,
    /// 375 kHz apart, are neighbours; 2 m and marine VHF, 8 MHz apart, are not, and a rail
    /// that labelled them so pointed at a band 60 MHz away.
    public static func abut(_ range: ClosedRange<UInt64>, _ band: Band) -> Bool {
        let gap: UInt64
        if band.minHz >= range.upperBound {
            gap = band.minHz - range.upperBound
        } else if band.maxHz <= range.lowerBound {
            gap = range.lowerBound - band.maxHz
        } else {
            gap = 0
        }
        return gap <= (range.upperBound - range.lowerBound) / 10
    }

    /// Whether any of the radio's tuning ranges reaches into the band. No ranges means the
    /// radio reported none, and every band is offered.
    public static func tunable(_ band: Band, ranges: [Leyline_V1_FrequencyRange]) -> Bool {
        ranges.isEmpty || ranges.contains { $0.minHz <= band.maxHz && $0.maxHz >= band.minHz }
    }

    /// Why a band is out of the radio's reach, shown after its name: `below what this radio
    /// tunes (24 – 1766 MHz)`. Nil when it is tunable.
    public static func outOfRangeWords(_ band: Band, ranges: [Leyline_V1_FrequencyRange]) -> String?
    {
        guard !tunable(band, ranges: ranges), let lo = ranges.map(\.minHz).min(),
            let hi = ranges.map(\.maxHz).max()
        else { return nil }
        let side = band.maxHz < lo ? "below" : band.minHz > hi ? "above" : "outside"
        return "\(side) what this radio tunes (\(mhz(lo)) – \(mhz(hi)) MHz)"
    }

    private static func mhz(_ hz: UInt64) -> String { String(format: "%g", Double(hz) / 1e6) }
}
