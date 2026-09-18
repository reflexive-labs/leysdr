// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Control (docs/dev/engine-internals.md "Control service").

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct ControlService: Leyline_V1_Control.SimpleServiceProtocol {
    let store: SessionStore
    /// Where a `ley://recordings/` uri resolves to a file, for `StartPlayback`.
    let recordings: RecordingStore

    private var client: ClientContext { ClientContext.current }

    func listDevices(request: Leyline_V1_ListDevicesRequest, context: ServerContext) async throws -> Leyline_V1_ListDevicesResponse {
        await store.touchUnary(client)
        var out = Leyline_V1_ListDevicesResponse()
        out.devices = await store.listDevices().map(ProtoMapping.descriptor)
        return out
    }

    func watchEvents(request: Leyline_V1_EventScope, response: RPCWriter<Leyline_V1_Event>, context: ServerContext) async throws {
        let c = client
        let scope = try await mapErrors { try await store.validated(EventScopeFilter(request)) }
        await store.streamOpened(c)
        defer { Task { await store.streamClosed(c) } }
        let events = await store.events(scope: scope, sinceSeq: request.hasSinceSeq ? request.sinceSeq : nil)
        // RPC cancellation is not task cancellation in grpc-swift: an idle watcher would otherwise sit
        // in `for await` (keeping its client present) until the store finishes subscribers on shutdown.
        // Drain in a child task that cancellation ends; cancelling the iterator also drops the
        // subscription. Shutdown still ends the loop by finishing the stream.
        let drain = Task {
            for await ev in events {
                try await response.write(ev)
            }
        }
        try await withRPCCancellationHandler {
            try await withTaskCancellationHandler {
                try await drain.value
            } onCancel: {
                drain.cancel()
            }
        } onCancelRPC: {
            drain.cancel()
        }
    }

    func getState(request: Leyline_V1_GetStateRequest, context: ServerContext) async throws -> Leyline_V1_GetStateResponse {
        await store.touchUnary(client)
        let scope = try await mapErrors { try await store.validated(request.hasScope ? EventScopeFilter(request.scope) : .daemon) }
        return await store.snapshot(scope: scope)
    }

    func createCapture(request: Leyline_V1_CreateCaptureRequest, context: ServerContext) async throws -> Leyline_V1_Capture {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = DeviceID(string: request.deviceID) else { throw EngineError.deviceNotFound(request.deviceID) }
            return try await store.createCapture(deviceID: id, centerHz: request.centerHz, sampleRate: request.sampleRate, by: client).proto
        }
    }

    func destroyCapture(request: Leyline_V1_DestroyCaptureRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = CaptureID(string: request.captureID) else { throw EngineError.captureNotFound(request.captureID) }
            try await store.destroyCaptureChecked(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }

    func createChannel(request: Leyline_V1_CreateChannelRequest, context: ServerContext) async throws -> Leyline_V1_Channel {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = CaptureID(string: request.captureID) else { throw EngineError.captureNotFound(request.captureID) }
            return try await store.createChannel(captureID: id, offsetHz: request.offsetHz, bandwidthHz: request.bandwidthHz,
                                                 mode: request.mode, persistent: request.persistent, requiredHz: request.requiredHz, by: client)
        }
    }

    func destroyChannel(request: Leyline_V1_DestroyChannelRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = ChannelID(string: request.channelID) else { throw EngineError.channelNotFound(request.channelID) }
            try await store.destroyChannelChecked(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }

    func attachSink(request: Leyline_V1_AttachSinkRequest, context: ServerContext) async throws -> Leyline_V1_Sink {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = ChannelID(string: request.channelID) else { throw EngineError.channelNotFound(request.channelID) }
            return try await store.attachSink(channelID: id, request: request.sink, by: client)
        }
    }

    func detachSink(request: Leyline_V1_DetachSinkRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = SinkID(string: request.sinkID) else { throw EngineError.sinkNotFound(request.sinkID) }
            try await store.detachSinkChecked(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }

    /// Plays a recording through the daemon's own audio device (docs/design/recording.md, "Playing
    /// a recording back"). The daemon owns the speakers, so a client on another machine hears it
    /// where the radio is and a client on this one needs no player of its own.
    func startPlayback(request: Leyline_V1_StartPlaybackRequest, context: ServerContext) async throws -> Leyline_V1_Playback {
        await store.touchUnary(client)
        return try await mapErrors {
            guard case .recording(let jobID, let part) = ResourceURI(request.resourceUri) else {
                throw EngineError.invalidArgument(
                    "\(request.resourceUri) is not a recording; playback takes ley://recordings/<id> or ley://recordings/<id>/<part>",
                    target: request.resourceUri)
            }
            guard let manifest = await recordings.manifest(jobID: jobID) else {
                throw EngineError.jobNotFound(jobID)
            }
            // Raw samples are tuned, not played: the daemon pushing baseband at an audio device
            // would be noise, and `ley play` on the file is what hears an IQ recording.
            guard manifest.kind != "iq" else {
                throw EngineError.invalidArgument(
                    "\(jobID) is an IQ recording: those are tuned rather than played. Attach it as a device instead",
                    target: request.resourceUri)
            }
            let wanted = part ?? manifest.parts.first?.part ?? 1
            guard let path = await recordings.localPath(jobID: jobID, part: wanted) else {
                throw EngineError.invalidArgument("\(jobID) has no part \(wanted)", target: request.resourceUri)
            }
            let volume = request.hasVolume ? Swift.max(0, Swift.min(1, request.volume)) : 1
            let device = request.audioDeviceUid.isEmpty ? nil : request.audioDeviceUid
            return try await store.startPlayback(path: path, resourceURI: "ley://recordings/\(jobID)/\(wanted)",
                                                 volume: volume, deviceUID: device, by: client)
        }
    }

    func stopPlayback(request: Leyline_V1_StopPlaybackRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = PlaybackID(string: request.playbackID) else {
                throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: request.playbackID)
            }
            try await store.stopPlaybackChecked(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }

    func writeParams(request: RPCAsyncSequence<Leyline_V1_ParamWrite, any Error>, context: ServerContext) async throws -> Leyline_V1_WriteSummary {
        let c = client
        await store.streamOpened(c)
        defer { Task { await store.streamClosed(c) } }
        return await WriteCoalescer(store: store, client: c).run(request)
    }

    func attachDevice(request: Leyline_V1_AttachDeviceRequest, context: ServerContext) async throws -> Leyline_V1_DeviceDescriptor {
        await store.touchUnary(client)
        return try await mapErrors {
            switch request.source.source {
            case .file(let f):
                guard !f.path.isEmpty else { throw EngineError.invalidArgument("path is required") }
                return ProtoMapping.descriptor(try await store.attachFileDevice(path: f.path, loop: f.loop, by: client))
            case .rtlTcp(let r):
                guard !r.host.isEmpty else { throw EngineError.invalidArgument("host is required") }
                guard r.port > 0, r.port <= UInt32(UInt16.max) else {
                    throw EngineError.invalidArgument("port \(r.port) is outside 1...65535")
                }
                return ProtoMapping.descriptor(try await store.attachRemoteDevice(host: r.host, port: UInt16(r.port), by: client))
            case .none:
                throw EngineError.invalidArgument("a source is required")
            }
        }
    }

    func detachDevice(request: Leyline_V1_DetachDeviceRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = DeviceID(string: request.deviceID) else { throw EngineError.deviceNotFound(request.deviceID) }
            try await store.detachDevice(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }

    func attachFileDevice(request: Leyline_V1_AttachFileDeviceRequest, context: ServerContext) async throws -> Leyline_V1_DeviceDescriptor {
        await store.touchUnary(client)
        return try await mapErrors {
            guard !request.path.isEmpty else { throw EngineError.invalidArgument("path is required") }
            return ProtoMapping.descriptor(try await store.attachFileDevice(path: request.path, loop: request.loop, by: client))
        }
    }

    func detachFileDevice(request: Leyline_V1_DetachFileDeviceRequest, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(client)
        return try await mapErrors {
            guard let id = DeviceID(string: request.deviceID) else { throw EngineError.deviceNotFound(request.deviceID) }
            try await store.detachDevice(id: id, by: client, fileOnly: true)
            return Leyline_V1_Empty()
        }
    }
}
