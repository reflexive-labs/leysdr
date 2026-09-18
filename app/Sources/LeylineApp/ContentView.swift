// SPDX-License-Identifier: Apache-2.0

// The skeleton window: where the daemon stands, the radios it lists, the captures and channels on
// them. Every number here is the daemon's; the view formats and never computes.

import LeylineClient
import LeylineProto
import SwiftUI

struct ContentView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        NavigationSplitView {
            List {
                let state = session.state
                Section("Radios") {
                    if state.devices.isEmpty { Text("No radio listed").foregroundStyle(.secondary) }
                    ForEach(state.devices, id: \.deviceID) { d in
                        LabeledContent(d.model.isEmpty ? d.driver : d.model) { Text(stateWord(d.state)).foregroundStyle(.secondary) }
                    }
                }
                Section("Channels") {
                    if state.channels.isEmpty { Text("Nothing tuned").foregroundStyle(.secondary) }
                    ForEach(state.channels, id: \.channelID) { ch in
                        LabeledContent(Frequency.format(state.frequencyHz(of: ch) ?? 0)) {
                            Text("\(ch.mode.word) · \(ch.owner.kind)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 12) {
                ConnectionBadge()
                Text("Spectrum and waterfall arrive with APP-2 (docs/plans/app.md).")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
        }
    }

    func stateWord(_ s: Leyline_V1_DeviceState) -> String {
        switch s {
        case .available: "available"
        case .inUse: "in use"
        case .disconnected: "disconnected"
        default: "unknown"
        }
    }
}

/// Names where the mirror stands, in the words the guide uses: the daemon is not running, or it
/// is and the app is following it.
struct ConnectionBadge: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 4) {
            Text(headline).font(.title3)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }

    var headline: String {
        if let e = session.startupError { return "Could not dial the daemon: \(e.message)" }
        switch session.connection {
        case .idle, .connecting: return "Connecting to leylined"
        case .live: return "leylined \(session.state.daemon.version)"
        case .unavailable(let e, _): return e.daemonUnreachable ? "The daemon is not running" : e.message
        }
    }

    var detail: String {
        switch session.connection {
        case .unavailable(_, let retry): return "Start it with `ley daemon start`; retrying in \(retry)."
        default: return session.socketPath
        }
    }
}

extension Leyline_V1_DemodMode {
    var word: String {
        switch self {
        case .am: "AM"
        case .nfm: "NFM"
        case .wfm: "WFM"
        case .usb: "USB"
        case .lsb: "LSB"
        case .cw: "CW"
        case .rawIq: "raw IQ"
        default: "?"
        }
    }
}

enum Frequency {
    /// `146.520 MHz`, `88.5 MHz`, `1.766 GHz`: the guide's spelling, a space before the unit.
    static func format(_ hz: UInt64) -> String {
        if hz >= 1_000_000_000 { return String(format: "%.3f GHz", Double(hz) / 1e9) }
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1e6) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1e3) }
        return "\(hz) Hz"
    }
}
