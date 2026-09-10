// leyline.v1.Bulk — thin RPC layer over StreamRegistry.

import EngineCore
import GRPCCore
import LeylineProto

struct BulkService: Leyline_V1_Bulk.SimpleServiceProtocol {
    let store: SessionStore
    let registry: StreamRegistry

    func subscribe(request: Leyline_V1_SubscribeRequest, context: ServerContext) async throws -> Leyline_V1_StreamDescriptor {
        await store.touchUnary(ClientContext.current)
        return try await mapErrors { try await registry.subscribe(request) }
    }

    func stream(request: Leyline_V1_StreamRef, response: RPCWriter<Leyline_V1_Frame>, context: ServerContext) async throws {
        let c = ClientContext.current
        let sub = try await mapErrors { () throws -> BulkSubscription in
            guard let id = StreamID(string: request.streamID) else {
                throw EngineError.streamNotFound(request.streamID)
            }
            return try await registry.beginReading(id)
        }
        await store.streamOpened(c)
        defer {
            Task {
                await registry.endReading(sub.id)
                await store.streamClosed(c)
            }
        }
        // RPC cancellation is not task cancellation in grpc-swift: with no frame due (a slow FFT rate,
        // squelched audio) the drain would otherwise park on the source's poke stream until the
        // subscription is closed. `cancelReader` flags the reader and wakes the loop; the poke stream
        // stays open for a reader that reconnects within the grace period.
        try await withRPCCancellationHandler {
            try await withTaskCancellationHandler {
                try await StreamRegistry.run(sub) { try await response.write($0) }
            } onCancel: {
                sub.cancelReader()
            }
        } onCancelRPC: {
            sub.cancelReader()
        }
    }

    func unsubscribe(request: Leyline_V1_StreamRef, context: ServerContext) async throws -> Leyline_V1_Empty {
        await store.touchUnary(ClientContext.current)
        return try await mapErrors {
            guard let id = StreamID(string: request.streamID) else {
                throw EngineError.streamNotFound(request.streamID)
            }
            try await registry.unsubscribe(id)
            return Leyline_V1_Empty()
        }
    }
}
