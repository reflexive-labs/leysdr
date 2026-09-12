// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Decoders: what is installed, the live record stream and the store
// (docs/design/decoders.md, "Decisions": "Records reach clients on their own service"). A meter
// reading is a sample of a level and a record is a thing that was said, so this is not telemetry.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct DecodersService: Leyline_V1_Decoders.SimpleServiceProtocol {
    let jobs: JobStore
    /// Presence, like every other stream: a client subscribed to records is here, and a client
    /// that only calls ListDecoders is touched so the store does not reap it mid-job.
    let store: SessionStore

    func listDecoders(request _: Leyline_V1_ListDecodersRequest, context _: ServerContext) async throws -> Leyline_V1_ListDecodersResponse {
        await store.touchUnary(ClientContext.current)
        let registry = await jobs.decoders
        var out = Leyline_V1_ListDecodersResponse()
        out.decoders = registry.scan().map(\.manifest)
        out.searchPath = registry.searchPath
        let stats = await jobs.records.stats
        out.storePath = stats.path
        out.storeCapBytes = stats.capBytes
        out.storeAgeDays = stats.ageDays
        return out
    }

    func subscribeRecords(request: Leyline_V1_RecordSubscription, response: RPCWriter<Leyline_V1_DecodeRecord>,
                          context _: ServerContext) async throws
    {
        let client = ClientContext.current
        let scope: RecordHub.Scope
        switch request.scope {
        case .jobID(let id)?: scope = .job(id)
        case .protocol(let name)?: scope = .protocolNamed(name)
        case .all?, nil: scope = .all
        }
        // `since_seq` replays the retained window of one job before going live, so "start the job,
        // then subscribe" misses nothing.
        let since: UInt64? = request.hasSinceSeq ? request.sinceSeq : nil
        let stream = await jobs.hub.subscribe(scope: scope, sinceSeq: since)
        await store.streamOpened(client)
        defer { Task { await store.streamClosed(client) } }
        for await record in stream {
            if Task.isCancelled { return }
            try await response.write(record)
        }
    }

    func queryRecords(request: Leyline_V1_RecordQuery, context _: ServerContext) async throws -> Leyline_V1_RecordPage {
        await store.touchUnary(ClientContext.current)
        return await jobs.records.query(request)
    }
}
