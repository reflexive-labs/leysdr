// SPDX-License-Identifier: GPL-3.0-or-later

// Sinks: attaching and detaching them, and following a channel to a new audio rate.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Sinks

    func attachSink(channelID: ChannelID, request: Leyline_V1_Sink, by: ClientContext) async throws -> Leyline_V1_Sink {
        guard let entry = channels[channelID] else { throw EngineError.channelNotFound(channelID.string) }
        var proto = request
        proto.sinkID = ""
        proto.channelID = channelID.string
        let sink: any AudioSink
        var isSystemAudio = false
        switch request.kind {
        case .systemAudio(var sa)?:
            // Proto3 presence: an absent volume means full (1.0); an explicit 0 means muted.
            let volume = sa.hasVolume ? sa.volume : 1.0
            guard volume >= 0, volume <= 1 else { throw EngineError.invalidArgument("volume must be within 0..1", target: channelID.string) }
            sa.volume = volume
            sink = try SinkFactory.systemAudio(rate: entry.engine.audioRate, volume: volume, deviceUID: sa.audioDeviceUid.isEmpty ? nil : sa.audioDeviceUid)
            proto.systemAudio = sa
            isSystemAudio = true
        case .stream?:
            throw EngineError.unimplemented("attaching a stream sink directly (use Bulk.Subscribe on the channel)")
        case .file?:
            throw EngineError.unimplemented("file sinks")
        case nil:
            throw EngineError.invalidArgument("sink kind is required", target: channelID.string)
        }
        try await entry.engine.attach(sink)
        proto.sinkID = sink.id.string
        proto.state = .sinkActive
        sinks[sink.id] = SinkEntry(proto: proto, channelID: channelID, sink: sink, isSystemAudio: isSystemAudio)
        if isSystemAudio, var cap = captures[entry.captureID] {
            cap.meta.liveAudioSinks += 1
            captures[entry.captureID] = cap
            await emitCapture(entry.captureID, by: by)
        }
        emit(.sink(proto), captureID: entry.captureID, by: by)
        return proto
    }

    func detachSinkChecked(id: SinkID, by: ClientContext) async throws {
        guard sinks[id] != nil else { throw EngineError.sinkNotFound(id.string) }
        await detachSink(id: id, by: by)
    }

    func detachSink(id: SinkID, by: ClientContext) async {
        guard let entry = sinks.removeValue(forKey: id) else { return }
        let captureID = channels[entry.channelID]?.captureID
        if let ch = channels[entry.channelID] { await ch.engine.detach(id) }
        await entry.sink.closeSink()
        if entry.isSystemAudio, let capID = captureID, var cap = captures[capID], cap.meta.liveAudioSinks > 0 {
            cap.meta.liveAudioSinks -= 1
            captures[capID] = cap
            await emitCapture(capID, by: by)
        }
        // Terminal event: state unset marks it gone, the same tombstone destroyChannel
        // uses. Without it a detach is byte-identical to the attach that preceded it.
        var terminal = entry.proto
        terminal.state = .unspecified
        emit(.sink(terminal), captureID: captureID, by: by)
    }

    /// A channel's decimation chain was re-planned at a new audio rate: system-audio sinks are
    /// rebuilt at the new rate under their existing ids (a sink that cannot be rebuilt is detached)
    /// and bulk audio streams negotiated at the old rate are ended.
    func audioRateChanged(_ chanID: ChannelID, by: ClientContext) async {
        guard let ch = channels[chanID] else { return }
        let rate = ch.engine.audioRate
        for (sinkID, entry) in sinks where entry.channelID == chanID && entry.isSystemAudio {
            await ch.engine.detach(sinkID)
            await entry.sink.closeSink()
            let sa = entry.proto.systemAudio
            do {
                let rebuilt = try makeSystemAudioSink(id: sinkID, rate: rate, volume: sa.volume, deviceUID: sa.audioDeviceUid.isEmpty ? nil : sa.audioDeviceUid)
                try await ch.engine.attach(rebuilt)
                sinks[sinkID]?.sink = rebuilt
            } catch {
                log.error("system audio sink \(sinkID) could not follow the new audio rate \(rate): \(error)")
                await detachSink(id: sinkID, by: by)
            }
        }
        await teardownHook?(.channelAudioRate(chanID))
    }

    /// Whether a channel write made the audio descriptor a client holds stale with the audio rate
    /// unchanged: the mode moved, or the full-scale deviation the descriptor answered for it did.
    /// A squelch or offset write moves neither.
    static func audioDescriptorMoved(from before: ChannelConfig, to after: ChannelConfig) -> Bool {
        before.mode != after.mode
            || DemodulatorFactory.fullScaleDeviationHz(mode: before.mode, bandwidthHz: before.bandwidthHz)
            != DemodulatorFactory.fullScaleDeviationHz(mode: after.mode, bandwidthHz: after.bandwidthHz)
    }

    /// Snapshot of every channel's audio rate on a capture, taken before a write that may re-plan chains.
    func audioRates(captureID: CaptureID) -> [ChannelID: UInt32] {
        channels.filter { $0.value.captureID == captureID }.mapValues { $0.engine.audioRate }
    }

    /// After a retune or rate change: rebuilds sinks for every channel whose audio rate moved
    /// (see `audioRateChanged`) and emits the full state of every channel on the capture.
    func reconcileAudioRates(captureID: CaptureID, before: [ChannelID: UInt32], by: ClientContext) async {
        for (chanID, ch) in channels where ch.captureID == captureID {
            if ch.engine.audioRate != before[chanID] { await audioRateChanged(chanID, by: by) }
            await emitChannel(chanID, by: by)
        }
    }
}
