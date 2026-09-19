// SPDX-License-Identifier: Apache-2.0

// One connection to one daemon: the gRPC client over the Unix socket, the identity interceptor,
// and the six typed service clients. Lazy like the Go client (`go/pkg/leyline/client.go`): nothing
// connects until the first RPC, and a socket with no listener fails that RPC with `UNAVAILABLE`.
// Everything else in this module is built on it.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import LeylineProto

public typealias Transport = HTTP2ClientTransport.Posix

public final class DaemonConnection: Sendable {
    public let socketPath: String
    public let identity: ClientIdentity

    public let control: Leyline_V1_Control.Client<Transport>
    public let telemetry: Leyline_V1_Telemetry.Client<Transport>
    public let bulk: Leyline_V1_Bulk.Client<Transport>
    public let jobs: Leyline_V1_Jobs.Client<Transport>
    public let resources: Leyline_V1_Resources.Client<Transport>
    public let decoders: Leyline_V1_Decoders.Client<Transport>

    let client: GRPCClient<Transport>
    private let runner: Task<Void, any Error>

    /// Dials `socketPath` (the platform default when nil) as `identity`. The connection's
    /// housekeeping runs in a task of its own until `close()`; RPCs before then queue on it.
    public init(socketPath: String? = nil, identity: ClientIdentity = .process) throws {
        let path = socketPath ?? SocketPath.default()
        self.socketPath = path
        self.identity = identity
        let transport = try Transport.http2NIOPosix(
            target: .unixDomainSocket(path: path),
            transportSecurity: .plaintext
        )
        let client = GRPCClient(
            transport: transport, interceptors: [IdentityInterceptor(identity: identity)])
        self.client = client
        self.control = .init(wrapping: client)
        self.telemetry = .init(wrapping: client)
        self.bulk = .init(wrapping: client)
        self.jobs = .init(wrapping: client)
        self.resources = .init(wrapping: client)
        self.decoders = .init(wrapping: client)
        self.runner = Task { try await client.runConnections() }
    }

    /// Ends the connection: in-flight RPCs finish, new ones fail, open streams end with
    /// `CANCELED`. Idempotent.
    public func close() {
        client.beginGracefulShutdown()
        runner.cancel()
    }

    deinit { close() }

    /// A daemon-scoped `GetState`, every list sorted by id so two snapshots of one daemon
    /// compare equal (ids are ULIDs, so this is creation order).
    public func state() async throws -> Leyline_V1_GetStateResponse {
        var req = Leyline_V1_GetStateRequest()
        req.scope.daemon = true
        do {
            var st = try await control.getState(req)
            st.devices.sort { $0.deviceID < $1.deviceID }
            st.captures.sort { $0.captureID < $1.captureID }
            st.channels.sort { $0.channelID < $1.channelID }
            st.sinks.sort { $0.sinkID < $1.sinkID }
            st.jobs.sort { $0.jobID < $1.jobID }
            st.playbacks.sort { $0.playbackID < $1.playbackID }
            return st
        } catch {
            throw LeylineError(error)
        }
    }

    /// `WatchEvents` as a stream. Pass `sinceSeq` from a snapshot's `eventSeq` to have the daemon
    /// replay what happened after it, so "GetState then WatchEvents" misses nothing. Holding the
    /// stream open is what keeps this client's non-persistent channels alive (5 s grace after the
    /// last open stream ends). Buffered without bound: an event dropped here would be a seq gap
    /// the mirror has to repair with another snapshot.
    public func events(sinceSeq: UInt64? = nil, capture: String? = nil) -> AsyncThrowingStream<
        Leyline_V1_Event, any Error
    > {
        var scope = Leyline_V1_EventScope()
        if let capture { scope.captureID = capture } else { scope.daemon = true }
        if let sinceSeq { scope.sinceSeq = sinceSeq }
        let request = scope
        return pump(bufferingPolicy: .unbounded) { deliver in
            try await self.control.watchEvents(request) { response in
                for try await event in response.messages { await deliver(event) }
            }
        }
    }

    /// `Telemetry.Subscribe` as a stream: meters, squelch edges, detections, sub-audible tones.
    /// Latest-wins on this side too (a bounded buffer, newest kept), which is the plane's own
    /// policy; a `seq` gap is the only trace of a reading missed anywhere.
    public func telemetry(_ subscription: Leyline_V1_TelemetrySubscription, buffer: Int = 64)
        -> AsyncThrowingStream<Leyline_V1_TelemetryMsg, any Error>
    {
        pump(bufferingPolicy: .bufferingNewest(buffer)) { deliver in
            try await self.telemetry.subscribe(subscription) { response in
                for try await msg in response.messages { await deliver(msg) }
            }
        }
    }

    /// Runs a server-streaming RPC in a task of its own and hands its messages out as an
    /// `AsyncThrowingStream`. Ending the consumer cancels the RPC; the RPC ending (or failing)
    /// ends the consumer, with the error mapped to `LeylineError`.
    func pump<M: Sendable>(
        bufferingPolicy: AsyncThrowingStream<M, any Error>.Continuation.BufferingPolicy,
        _ open:
            @escaping @Sendable (_ deliver: @escaping @Sendable (M) async -> Void) async throws ->
            Void
    ) -> AsyncThrowingStream<M, any Error> {
        let (stream, continuation) = AsyncThrowingStream<M, any Error>.makeStream(
            bufferingPolicy: bufferingPolicy)
        let task = Task {
            do {
                try await open { m in continuation.yield(m) }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: LeylineError(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Adds the identity metadata to every RPC (the daemon parses it into the event's `caused_by`).
struct IdentityInterceptor: ClientInterceptor {
    let identity: ClientIdentity

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws ->
            StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.add(contentsOf: identity.metadata)
        return try await next(request, context)
    }
}
