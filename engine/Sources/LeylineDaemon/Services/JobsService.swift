// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Jobs — scan is implemented (Milestone D.13); watch, record and Resources arrive with
// the durable job store at D.15.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

private func unimplemented(_ what: String) -> RPCError {
    ProtoMapping.rpcError(EngineError.unimplemented(what))
}

struct JobsService: Leyline_V1_Jobs.SimpleServiceProtocol {
    let jobs: JobStore
    /// Presence, not state: a job-only client -- an agent or a script that starts a scan and polls
    /// -- holds no stream, so without a touch on every call the session store reaps it mid-sweep
    /// and the client-gone hook cancels the job it is still asking about.
    let store: SessionStore

    func startJob(request: Leyline_V1_StartJobRequest, context _: ServerContext) async throws -> Leyline_V1_Job {
        let client = ClientContext.current
        await store.touchUnary(client)
        switch request.config {
        case .scan(let config)?:
            return try await mapErrors { try await jobs.startScan(config: config, by: client) }
        case .watch?:
            throw unimplemented("Jobs.StartJob(watch)")
        case .record?:
            throw unimplemented("Jobs.StartJob(record)")
        case .decode(let config)?:
            return try await mapErrors { try await jobs.startDecode(config: config, by: client) }
        case .monitor?:
            // Implemented by the band-monitor work (docs/plans/band-watching.md); stubbed so the
            // switch stays exhaustive until then.
            throw unimplemented("Jobs.StartJob(monitor)")
        case nil:
            throw ProtoMapping.rpcError(EngineError.invalidArgument("StartJob needs a config: scan and decode are the ones in v0", target: ""))
        }
    }

    func listJobs(request: Leyline_V1_ListJobsRequest, context _: ServerContext) async throws -> Leyline_V1_ListJobsResponse {
        await store.touchUnary(ClientContext.current)
        let want = Set(request.states)
        var out = Leyline_V1_ListJobsResponse()
        out.jobs = await jobs.snapshot().filter { want.isEmpty || want.contains($0.state) }
        return out
    }

    func getJob(request: Leyline_V1_JobRef, context _: ServerContext) async throws -> Leyline_V1_Job {
        await store.touchUnary(ClientContext.current)
        guard let id = JobID(string: request.jobID), let job = await jobs.job(id) else {
            throw ProtoMapping.rpcError(EngineError.jobNotFound(request.jobID))
        }
        return job
    }

    func cancelJob(request: Leyline_V1_JobRef, context _: ServerContext) async throws -> Leyline_V1_Job {
        await store.touchUnary(ClientContext.current)
        guard let id = JobID(string: request.jobID), let job = await jobs.cancel(id) else {
            throw ProtoMapping.rpcError(EngineError.jobNotFound(request.jobID))
        }
        return job
    }

    func getTranscript(request _: Leyline_V1_TranscriptRequest, context _: ServerContext) async throws -> Leyline_V1_Transcript {
        throw unimplemented("Jobs.GetTranscript")
    }

    func getScan(request: Leyline_V1_ScanRef, context _: ServerContext) async throws -> Leyline_V1_Scan {
        await store.touchUnary(ClientContext.current)
        guard let id = ScanID(string: request.scanID), let scan = await jobs.scan(id) else {
            throw ProtoMapping.rpcError(EngineError.scanNotFound(request.scanID))
        }
        return scan
    }
}

struct ResourcesService: Leyline_V1_Resources.SimpleServiceProtocol {
    func listResources(request _: Leyline_V1_ListResourcesRequest, context _: ServerContext) async throws -> Leyline_V1_ListResourcesResponse {
        throw unimplemented("Resources.ListResources")
    }

    func getResource(request _: Leyline_V1_ResourceRef, context _: ServerContext) async throws -> Leyline_V1_Resource {
        throw unimplemented("Resources.GetResource")
    }

    func resolveLocalPath(request _: Leyline_V1_ResourceRef, context _: ServerContext) async throws -> Leyline_V1_LocalPath {
        throw unimplemented("Resources.ResolveLocalPath")
    }
}
