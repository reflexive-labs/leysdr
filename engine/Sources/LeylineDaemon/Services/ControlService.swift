// leyline.v1.Control (docs/engine-internals.md "Control service").

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct ControlService: Leyline_V1_Control.SimpleServiceProtocol {
    let store: SessionStore

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
        let events = await store.events(scope: scope)
        for await ev in events {
            try await response.write(ev)
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
            return try await store.createCapture(deviceID: id, centerHz: request.centerHz, sampleRate: request.sampleRate, by: client)
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

    func writeParams(request: RPCAsyncSequence<Leyline_V1_ParamWrite, any Error>, context: ServerContext) async throws -> Leyline_V1_WriteSummary {
        let c = client
        await store.streamOpened(c)
        defer { Task { await store.streamClosed(c) } }
        return await WriteCoalescer(store: store, client: c).run(request)
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
            try await store.detachFileDevice(id: id, by: client)
            return Leyline_V1_Empty()
        }
    }
}
