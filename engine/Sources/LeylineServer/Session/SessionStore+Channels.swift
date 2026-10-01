// SPDX-License-Identifier: GPL-3.0-or-later

// Channels: creating and destroying them, and the channel events.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Channels

    func channelEngine(_ id: ChannelID) -> (any ChannelEngine)? { channels[id]?.engine }

    /// Channel engines in scope, for telemetry fan-in.
    /// The capture engines in a scope: one, or every capture the daemon holds.
    func captureEngines(captureID: CaptureID?) -> [(CaptureID, DefaultCaptureEngine)] {
        captures.compactMap { id, e in
            if let c = captureID, id != c { return nil }
            return (id, e.engine)
        }
    }

    func channelEngines(captureID: CaptureID?) -> [(ChannelID, any ChannelEngine)] {
        channels.compactMap { id, e in
            if let c = captureID, e.captureID != c { return nil }
            return (id, e.engine)
        }
    }

    /// The capture a channel sits in. A record job borrowing somebody's channel needs it to date
    /// the samples and to find the anchor (invariant 5).
    func channelCapture(_ id: ChannelID) -> CaptureID? { channels[id]?.captureID }

    /// Re-emits a channel after something changed it that was not a client write: the squelch a
    /// record job set on the channel the allocator built for it, say.
    func publishChannel(_ id: ChannelID) async {
        guard let entry = channels[id] else { return }
        await emitChannel(id, by: entry.owner)
    }

    func channelProto(_ id: ChannelID) async -> Leyline_V1_Channel? {
        guard let entry = channels[id] else { return nil }
        let config = await entry.engine.config
        let state = await entry.engine.state
        return ProtoMapping.channel(id: id, captureID: entry.captureID, config: config, state: state, owner: entry.owner.proto)
    }

    func emitChannel(_ id: ChannelID, by: ClientContext) async {
        guard let p = await channelProto(id) else { return }
        emit(.channel(p), captureID: CaptureID(string: p.captureID), by: by)
    }

    func createChannel(captureID: CaptureID, offsetHz: Int64, bandwidthHz: UInt32, mode: Leyline_V1_DemodMode,
                       persistent: Bool, requiredHz: UInt64, by: ClientContext) async throws -> Leyline_V1_Channel {
        guard let cap = captures[captureID] else { throw EngineError.captureNotFound(captureID.string) }
        try refuseIfSwept(captureID)
        // DEMOD_MODE_UNSPECIFIED defaults to NFM (contract parity with the Go reference daemon).
        guard let m = ProtoMapping.demodMode(mode == .unspecified ? .nfm : mode) else {
            throw EngineError.modeUnsupported(String(describing: mode), target: captureID.string)
        }
        let bw = bandwidthHz == 0 ? m.defaultBandwidthHz : bandwidthHz
        let rate = await cap.engine.snapshot.sampleRate
        guard Self.fits(offsetHz: offsetHz, bandwidthHz: bw, sampleRate: rate) else {
            throw EngineError.offsetOutOfCapture(offsetHz, target: captureID.string)
        }
        // Sub-audible detection is on for NFM, which is the only mode CTCSS is sent under. It costs
        // the DSP thread two decimation stages -- about 0.6 Mmult/s -- and never gates audio.
        // Making it a per-channel request is a control-plane change (Channel field 12 is the
        // contract for it); until then, the mode is the answer.
        let config = ChannelConfig(offsetHz: offsetHz, bandwidthHz: bw, mode: m, persistent: persistent,
                                   requiredHz: requiredHz == 0 ? nil : requiredHz,
                                   subAudibleDetect: m == .nfm)
        let engine = try await cap.engine.addChannel(config)
        channels[engine.id] = ChannelEntry(engine: engine, captureID: captureID, owner: by)
        touchActivity(captureID, by: by)
        await emitCapture(captureID, by: by)
        let proto = await channelProto(engine.id)!
        emit(.channel(proto), captureID: captureID, by: by)
        return proto
    }

    /// `|offset| + bw/2 <= Fs/2`.
    static func fits(offsetHz: Int64, bandwidthHz: UInt32, sampleRate: UInt64) -> Bool {
        // `magnitude`, not `abs`: `abs(Int64.min)` traps.
        Double(offsetHz.magnitude) + Double(bandwidthHz) / 2 <= Double(sampleRate) / 2
    }

    func destroyChannelChecked(id: ChannelID, by: ClientContext) async throws {
        guard channels[id] != nil else { throw EngineError.channelNotFound(id.string) }
        await destroyChannel(id: id, by: by, engineAlreadyClosed: false)
    }

    /// Removes a channel, its sinks and its bulk streams; emits a terminal (state UNSPECIFIED) event.
    func destroyChannel(id: ChannelID, by: ClientContext, engineAlreadyClosed: Bool) async {
        guard let entry = channels[id] else { return }
        for (sinkID, s) in sinks where s.channelID == id {
            await detachSink(id: sinkID, by: by)
        }
        await teardownHook?(.channel(id))
        let config = await entry.engine.config
        if !engineAlreadyClosed, let cap = captures[entry.captureID] {
            await cap.engine.removeChannel(id)
        }
        channels[id] = nil
        let proto = ProtoMapping.channel(id: id, captureID: entry.captureID, config: config, state: nil, owner: entry.owner.proto)
        emit(.channel(proto), captureID: entry.captureID, by: by)
    }
}
