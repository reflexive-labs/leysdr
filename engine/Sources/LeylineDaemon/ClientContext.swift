// Client identity (docs/engine-internals.md "Client identity and ownership").

import EngineCore
import GRPCCore
import LeylineProto

/// Identity a client declares on every RPC via metadata. Missing metadata yields a fresh id and
/// kind "unknown" so every event still has a `caused_by`.
struct ClientContext: Sendable, Hashable {
    static let idKey = "leyline-client-id"
    static let kindKey = "leyline-client-kind"
    static let labelKey = "leyline-client-label"

    var id: String
    var kind: String
    var label: String

    /// The identity of the RPC being served; the daemon's own identity outside an RPC.
    @TaskLocal static var current: ClientContext = .daemon

    /// Attribution for daemon-originated changes (reaping, device hot-plug).
    static let daemon = ClientContext(id: "daemon", kind: "daemon", label: "leylined")

    /// True for clients whose writes count as interactive activity (the don't-disturb signal).
    var isInteractive: Bool { kind != "job" }

    init(id: String, kind: String, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }

    init(metadata: Metadata) {
        let id = metadata[stringValues: Self.idKey].first(where: { !$0.isEmpty }) ?? ClientID().string
        let kind = metadata[stringValues: Self.kindKey].first(where: { !$0.isEmpty }) ?? "unknown"
        let label = metadata[stringValues: Self.labelKey].first(where: { _ in true }) ?? ""
        self.init(id: id, kind: kind, label: label)
    }

    var proto: Leyline_V1_ClientInfo {
        var out = Leyline_V1_ClientInfo()
        out.clientID = id
        out.kind = kind
        out.label = label
        return out
    }
}

/// Server interceptor that parses the identity metadata into `ClientContext.current` for the
/// duration of each RPC.
struct ClientContextInterceptor: ServerInterceptor {
    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let client = ClientContext(metadata: request.metadata)
        var response = try await ClientContext.$current.withValue(client) {
            try await next(request, context)
        }
        // Streaming producers run after this scope ends; re-enter the context for them too.
        if case .success(var contents) = response.accepted {
            let producer = contents.producer
            contents.producer = { writer in
                try await ClientContext.$current.withValue(client) { try await producer(writer) }
            }
            response.accepted = .success(contents)
        }
        return response
    }
}
