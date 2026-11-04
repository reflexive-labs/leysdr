// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Decoders: what is installed, the live record stream and the store
// (docs/design/decoders.md, "Decisions": "Records reach clients on their own service"). A meter
// reading samples a level; a record is a decoded message. Records are not telemetry.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct DecodersService: Leyline_V1_Decoders.SimpleServiceProtocol {
    let jobs: JobStore
    /// Presence, like every other stream: a client subscribed to records is here, and a client
    /// that only calls ListDecoders is touched so the store does not reap it mid-job.
    let store: SessionStore
    /// Whether ListDecoders includes the manifests marked `test_only`: true only for a daemon
    /// started with `--no-hardware`, which is how tests, evals and check scenes run it, so a
    /// fixture decoder (`speech-scripted`, `iqstat`) stays out of a person's list; a site scene's
    /// adds `--hide-test-decoders` to hide them too (`Daemon.Config.listsTestOnly`). A job may still
    /// name one either way; only the listing hides it.
    let listsTestOnly: Bool

    /// The manifests ListDecoders answers with: all of them, or those not marked `test_only`.
    static func listed(_ manifests: [Leyline_V1_DecoderManifest], testOnly: Bool) -> [Leyline_V1_DecoderManifest] {
        testOnly ? manifests : manifests.filter { !$0.testOnly }
    }

    func listDecoders(request _: Leyline_V1_ListDecodersRequest, context _: ServerContext) async throws -> Leyline_V1_ListDecodersResponse {
        await store.touchUnary(ClientContext.current)
        let registry = await jobs.decoders
        var out = Leyline_V1_ListDecodersResponse()
        out.decoders = Self.listed(registry.scan().map(\.manifest), testOnly: listsTestOnly)
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
