// SPDX-License-Identifier: Apache-2.0

// The words over the transport's squelch track, in two lengths. A narrow bar first drops the
// three words under the track, then takes the short caption (`open · 33 dB`), so the track keeps
// its size and no word is cut (docs/plans/app.md, MC-1b).

import Foundation

public enum SquelchCaption {
    /// `open · 33 dB above the marker`, `muted · 12 dB below the marker`, `open · squelch off`
    /// with no squelch, and `no signal measured yet` before a level; `short` gives `open · 33 dB`,
    /// `muted · 12 dB`, `open · off` and `no signal yet`. NaN stands for nothing measured and for
    /// no squelch.
    public static func words(squelchDB: Double, powerDB: Double, open: Bool, short: Bool = false)
        -> String
    {
        guard powerDB.isFinite else { return short ? "no signal yet" : "no signal measured yet" }
        guard squelchDB.isFinite else { return short ? "open · off" : "open · squelch off" }
        let d = powerDB - squelchDB
        let state = open ? "open" : "muted"
        let dB = String(format: "%.0f dB", open ? d : -d)
        return short
            ? "\(state) · \(dB)" : "\(state) · \(dB) \(open ? "above" : "below") the marker"
    }
}
