// SPDX-License-Identifier: GPL-3.0-or-later

// The GetState snapshot and the shutdown.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Snapshot

    func snapshot(scope: EventScopeFilter) async -> Leyline_V1_GetStateResponse {
        // Read the seq before any actor hop: the object reads below suspend, and a commit that
        // lands in between must look *newer* than this snapshot (duplicate replay is harmless
        // because events carry full state; a stale object tagged with a newer seq is not).
        let at = seq
        var out = Leyline_V1_GetStateResponse()
        out.daemon = info.proto
        let capFilter: CaptureID? = { if case .capture(let c) = scope { return c } else { return nil } }()
        out.devices = listDevices().map(ProtoMapping.descriptor)
        for id in captures.keys.sorted(by: { $0.string < $1.string }) where capFilter == nil || capFilter == id {
            if let p = await captureProto(id) { out.captures.append(p) }
        }
        for id in channels.keys.sorted(by: { $0.string < $1.string }) where capFilter == nil || channels[id]?.captureID == capFilter {
            if let p = await channelProto(id) { out.channels.append(p) }
        }
        for id in sinks.keys.sorted(by: { $0.string < $1.string }) {
            guard let s = sinks[id] else { continue }
            if let c = capFilter, channels[s.channelID]?.captureID != c { continue }
            out.sinks.append(s.proto)
        }
        // Daemon-scoped only: a job is not tied to one capture's lifetime, and a capture-filtered
        // reader asked about that capture.
        if capFilter == nil, let provider = jobsProvider {
            out.jobs = await provider()
        }
        // A playback is not tied to a capture either: it is a file playing, with no radio in it.
        if capFilter == nil {
            out.playbacks = await playbackProtos()
        }
        out.eventSeq = at
        return out
    }

    /// Graceful shutdown: every capture stopped (devices closed), subscribers finished.
    func shutdown() async {
        deviceTask?.cancel()
        for id in Array(captures.keys) { await destroyCapture(id: id, by: .daemon) }
        for p in presence.values { p.grace?.cancel() }
        presence.removeAll()
        finishSubscribers()
    }
}
