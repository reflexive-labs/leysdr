// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Jobs — scan, monitor, decode and record are implemented; watch and transcripts arrive
// with the durable job store at D.15. `Resources` is its own file.

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
        case .record(let config)?:
            return try await mapErrors { try await jobs.startRecord(config: config, by: client) }
        case .decode(let config)?:
            return try await mapErrors { try await jobs.startDecode(config: config, by: client) }
        case .monitor(let config)?:
            return try await mapErrors { try await jobs.startMonitor(config: config, by: client) }
        case nil:
            throw ProtoMapping.rpcError(EngineError.invalidArgument("StartJob needs a config: scan, monitor, decode and record are the ones in v0", target: ""))
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
