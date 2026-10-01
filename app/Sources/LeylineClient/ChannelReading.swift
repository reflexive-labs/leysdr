// SPDX-License-Identifier: Apache-2.0

// The inspector's reading steadied for display: the meter's numbers with meter ballistics and
// the words with hysteresis, so the panel stops jumping at the meter's 10 Hz. The raw meter
// stays on `ChannelTelemetryFeed.meter` and in Measurements. This fold only chooses what is
// drawn. It is a value fed once per meter message and reset when the channel changes, and it
// lives here rather than in a view so the container can test it (docs/dev/swift-style.md,
// section 11). Invariant 12 still holds: every word is one of `Reading.swift`'s bands of a
// number the panel prints beside it, and hysteresis only delays a change between two
// adjacent bands.

import Foundation
import LeylineProto

/// A peak-reading meter's ballistics: a rise is taken at once and a fall decays exponentially
/// with `releaseSeconds` as its time constant. Time is whatever clock the caller folds with;
/// the inspector uses the capture's sample clock, so a stalled stream holds its value instead
/// of decaying.
public struct Ballistics: Sendable, Equatable {
    public let releaseSeconds: Double
    /// NaN until the first finite value.
    public private(set) var value: Double = .nan
    private var lastSeconds: Double = .nan

    /// A gap longer than this starts the meter again from the new value rather than decaying
    /// toward it: a stream that resumed after a pause is not a fall.
    static let gapSeconds: Double = 2

    public init(releaseSeconds: Double) {
        self.releaseSeconds = releaseSeconds
    }

    /// Folds `new` in at `seconds` and returns the displayed value. A NaN `new` leaves the value
    /// held; a NaN or backwards clock takes `new` as it is.
    @discardableResult
    public mutating func fold(_ new: Double, atSeconds seconds: Double) -> Double {
        guard new.isFinite else { return value }
        let dt = seconds - lastSeconds
        lastSeconds = seconds
        if !value.isFinite || new >= value || !dt.isFinite || dt < 0 || dt > Self.gapSeconds
            || releaseSeconds <= 0
        {
            value = new
        } else {
            value = new + (value - new) * exp(-dt / releaseSeconds)
        }
        return value
    }

    public mutating func reset() {
        value = .nan
        lastSeconds = .nan
    }
}

extension SignalWord {
    /// How far past a band's edge the level must go before the word leaves that band. A starting
    /// value, not a measurement: the narrowest band (3 to 8 dB) is 5 dB wide, so 1.5 dB either
    /// side still leaves every word reachable. Set it from captures if the words still flicker.
    public static let hysteresisDB: Double = 1.5

    /// The word for `overNoiseDB`, keeping `previous` while the level is within `hysteresisDB`
    /// of `previous`'s band. nil for NaN or nil, like `init?(overNoiseDB:)`.
    public init?(overNoiseDB: Double?, previous: SignalWord?) {
        guard let fresh = SignalWord(overNoiseDB: overNoiseDB), let db = overNoiseDB else {
            return nil
        }
        guard let previous, previous != fresh else {
            self = fresh
            return
        }
        let band = previous.bandDB
        let inside =
            db >= band.lowerBound - Self.hysteresisDB && db < band.upperBound + Self.hysteresisDB
        self = inside ? previous : fresh
    }

    /// The word's band in dB over noise, open at both ends for the outer words.
    var bandDB: Range<Double> {
        let i = Self.allCases.firstIndex(of: self) ?? 0
        let lower = i == 0 ? -Double.infinity : Self.thresholdsDB[i - 1]
        let upper = i == Self.thresholdsDB.count ? Double.infinity : Self.thresholdsDB[i]
        return lower..<upper
    }
}

extension TuningWord {
    /// How far past a tenth of the bandwidth, as a fraction of the bandwidth, the error must go
    /// to leave `Centred`, and how far inside it to come back.
    public static let hysteresisFraction: Double = 0.02

    /// The word for `freqErrorHz`, keeping `previous` until the error is `hysteresisFraction` of
    /// the bandwidth past the edge. The two off-tune words switch directly when the sign
    /// changes. nil where `init?(freqErrorHz:bandwidthHz:)` is.
    public init?(freqErrorHz: Double, bandwidthHz: UInt32, previous: TuningWord?) {
        guard let fresh = TuningWord(freqErrorHz: freqErrorHz, bandwidthHz: bandwidthHz) else {
            return nil
        }
        guard let previous, previous != fresh else {
            self = fresh
            return
        }
        let fraction = abs(freqErrorHz) / Double(bandwidthHz)
        switch (previous, fresh) {
        case (.centred, _):
            self =
                fraction > Self.offTuneFraction + Self.hysteresisFraction ? fresh : .centred
        case (_, .centred):
            self =
                fraction <= Self.offTuneFraction - Self.hysteresisFraction ? .centred : previous
        default:
            self = fresh
        }
    }
}

/// What the inspector's reading rows draw for one channel.
public struct ChannelReading: Sendable, Equatable {
    /// The signal bar's release: long enough that a syllable does not flicker the bar, short
    /// enough that the end of a transmission shows within a second.
    public static let signalReleaseSeconds: Double = 0.3
    /// The deviation meter's release, the VU-like fall decided on 2026-09-21: from a peak to under
    /// a tenth of it in about a second.
    public static let deviationReleaseSeconds: Double = 0.4

    public private(set) var channelID: String?
    /// Power over the channel's floor with `signalReleaseSeconds` ballistics; NaN until the
    /// meter and the floor have both been read.
    public private(set) var overNoiseDB: Double = .nan
    public private(set) var signalWord: SignalWord?
    /// The newest measured tuning error, kept after the squelch closes so the panel can show
    /// how the last transmission was tuned. NaN until one was measured.
    public private(set) var freqErrorHz: Double = .nan
    public private(set) var tuningWord: TuningWord?
    /// Peak deviation with `deviationReleaseSeconds` ballistics, kept after the squelch closes
    /// like `freqErrorHz`.
    public private(set) var deviationHz: Double = .nan
    public private(set) var deviationWord: DeviationWord?
    /// True while the newest meter came from an open squelch. When false, tuning and deviation
    /// are the last transmission's values and the panel dims them.
    public private(set) var isLive = false

    private var signal = Ballistics(releaseSeconds: Self.signalReleaseSeconds)
    private var deviation = Ballistics(releaseSeconds: Self.deviationReleaseSeconds)

    public init() {}

    /// Folds one meter in. `seconds` is the message's time on the capture's clock (sample index
    /// over rate). `floorDB` is the band floor at the channel's width
    /// (`SpectrumFold.channelFloorDB`) and nil before the first spectrum row. A different
    /// `channelID` starts from nothing, because the last channel's reading is not this one's.
    public mutating func fold(
        _ meter: Leyline_V1_Meter, atSeconds seconds: Double, channelID: String,
        floorDB: Double?, mode: Leyline_V1_DemodMode, bandwidthHz: UInt32
    ) {
        if channelID != self.channelID {
            self = ChannelReading()
            self.channelID = channelID
        }

        if let floorDB, meter.powerDbfs.isFinite {
            overNoiseDB = signal.fold(meter.powerDbfs - floorDB, atSeconds: seconds)
            signalWord = SignalWord(overNoiseDB: overNoiseDB, previous: signalWord)
        }

        let wasLive = isLive
        isLive = meter.squelchOpen
        // Only an open squelch's numbers describe a transmission; the deviation of noise under
        // a closed squelch is not a reading of anyone. A new transmission starts both meters
        // from its own values, not from where the last one released to.
        guard isLive else { return }
        if !wasLive { deviation.reset() }

        if TuningWord(freqErrorHz: meter.freqErrorHz, bandwidthHz: bandwidthHz) != nil {
            freqErrorHz = meter.freqErrorHz
            tuningWord = TuningWord(
                freqErrorHz: freqErrorHz, bandwidthHz: bandwidthHz,
                previous: wasLive ? tuningWord : nil)
        }
        if DeviationWord(deviationHz: meter.deviationHz, mode: mode, bandwidthHz: bandwidthHz)
            != nil
        {
            deviationHz = deviation.fold(meter.deviationHz, atSeconds: seconds)
            // The word is read from the held level the meter draws, so the number and its
            // colour agree.
            deviationWord = DeviationWord(
                deviationHz: deviationHz, mode: mode, bandwidthHz: bandwidthHz)
        }
    }

    /// The squelch threshold on the signal bar's scale: dB over the channel's floor, NaN with
    /// the squelch off or no floor yet.
    public static func squelchOverNoiseDB(squelchDB: Double, floorDB: Double?) -> Double {
        guard squelchDB.isFinite, let floorDB, floorDB.isFinite else { return .nan }
        return squelchDB - floorDB
    }
}

extension Reading {
    /// How long ago, coarse enough not to flicker: "12 s ago" under a minute, "4 min ago" under
    /// an hour, "2 h ago" after that; "—" for NaN or negative.
    public static func ago(seconds s: Double) -> String {
        guard s.isFinite, s >= 0 else { return absent }
        let whole = Int(s)
        if whole < 60 { return "\(whole) s ago" }
        if whole < 3600 { return "\(whole / 60) min ago" }
        return "\(whole / 3600) h ago"
    }
}
