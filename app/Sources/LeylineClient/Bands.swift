// SPDX-License-Identifier: Apache-2.0

// The band table, read from the seed file `ley bands --json` generates (docs/design/
// app-design-handoff.md, "Bands and bookmarks are files"). The table is Go's; this is a copy
// checked in as a resource and drift-tested from Go, so the app and `ley` name the same bands
// with the same defaults and neither has a table of its own. A band is a place to look: its
// range, the mode and bandwidth a newcomer wants there, and the step the arrow keys tune by.

import Foundation
import LeylineProto

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

    enum CodingKeys: String, CodingKey {
        case name, aliases, mode, note, parts
        case minHz = "min_hz"
        case maxHz = "max_hz"
        case bandwidthHz = "bandwidth_hz"
        case stepHz = "step_hz"
    }

    public init(name: String, aliases: [String], minHz: UInt64, maxHz: UInt64, mode: String,
                bandwidthHz: UInt32, stepHz: UInt32, note: String = "", parts: [String] = []) {
        self.name = name
        self.aliases = aliases
        self.minHz = minHz
        self.maxHz = maxHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.stepHz = stepHz
        self.note = note
        self.parts = parts
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
}

public enum Bands {
    /// The seed file, decoded once. Empty only if the resource is missing, which the tests catch.
    public static let builtIn: [Band] = {
        guard let url = Bundle.module.url(forResource: "bands", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bands = try? decode(data) else { return [] }
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

    /// The mode a newcomer wants at `hz`: the band's, sideband by frequency on HF, NFM when no
    /// band is recognised. `ley tune`'s rule (`go/pkg/leyline/bands.go`, `DefaultMode`).
    public static func defaultMode(at hz: UInt64, in bands: [Band] = builtIn) -> Leyline_V1_DemodMode {
        band(containing: hz, in: bands)?.mode(at: hz) ?? .nfm
    }

    /// The sample rate a band wants from a radio: the smallest the radio offers that covers the
    /// band, else the largest there is. `ley`'s rule (`go/internal/cli/band.go`).
    public static func sampleRate(for band: Band, offered rates: [UInt64]) -> UInt64? {
        if let fit = rates.filter({ $0 >= band.widthHz }).min() { return fit }
        return rates.max()
    }

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
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

    /// The mode as a person reads it.
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

    /// The widths the transport bar offers for the mode, the default first
    /// (docs/design/app-design-handoff.md, "Region 5", Width).
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
}

// MARK: The rail

extension Band {
    /// `hz` on the band's grid: the nearest multiple of the step counted from the low edge, so a
    /// scrub along the rail lands on a channel the band names rather than between two. A band
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
    /// rail names these at its end caps, and a scrub past a cap crosses into them.
    public static func neighbours(of range: ClosedRange<UInt64>, in bands: [Band] = builtIn) -> (below: Band?, above: Band?) {
        let plain = bands.filter { !$0.isGroup }
        let below = plain.filter { $0.maxHz <= range.lowerBound }.max { $0.maxHz < $1.maxHz }
        let above = plain.filter { $0.minHz >= range.upperBound }.min { $0.minHz < $1.minHz }
        return (below, above)
    }
}

// MARK: Neighbours and reach

extension Bands {
    /// Whether `band` sits close enough against `range` to be named its neighbour: the gap
    /// between them is no more than a tenth of `range`'s width. Marine VHF and NOAA weather,
    /// 375 kHz apart, are neighbours; 2 m and marine VHF, 8 MHz apart, are not, and a rail
    /// that named them so was naming a band 60 MHz away.
    public static func abut(_ range: ClosedRange<UInt64>, _ band: Band) -> Bool {
        let gap: UInt64
        if band.minHz >= range.upperBound { gap = band.minHz - range.upperBound }
        else if band.maxHz <= range.lowerBound { gap = range.lowerBound - band.maxHz }
        else { gap = 0 }
        return gap <= (range.upperBound - range.lowerBound) / 10
    }

    /// Whether any of the radio's tuning ranges reaches into the band. No ranges means the
    /// radio did not say, and every band is offered.
    public static func tunable(_ band: Band, ranges: [Leyline_V1_FrequencyRange]) -> Bool {
        ranges.isEmpty || ranges.contains { $0.minHz <= band.maxHz && $0.maxHz >= band.minHz }
    }

    /// Why a band is out of the radio's reach, to follow its name: `below what this radio
    /// tunes (24 – 1766 MHz)`. Nil when it is tunable.
    public static func outOfRangeWords(_ band: Band, ranges: [Leyline_V1_FrequencyRange]) -> String? {
        guard !tunable(band, ranges: ranges), let lo = ranges.map(\.minHz).min(), let hi = ranges.map(\.maxHz).max() else { return nil }
        let side = band.maxHz < lo ? "below" : band.minHz > hi ? "above" : "outside"
        return "\(side) what this radio tunes (\(mhz(lo)) – \(mhz(hi)) MHz)"
    }

    private static func mhz(_ hz: UInt64) -> String { String(format: "%g", Double(hz) / 1e6) }
}
