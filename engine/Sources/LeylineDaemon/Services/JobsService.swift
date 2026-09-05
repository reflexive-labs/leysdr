// leyline.v1.Jobs and leyline.v1.Resources — UNIMPLEMENTED in v0 (milestones D/E).

import EngineCore
import GRPCCore
import LeylineProto

private func unimplemented(_ what: String) -> RPCError {
    ProtoMapping.rpcError(EngineError.unimplemented(what))
}

struct JobsService: Leyline_V1_Jobs.SimpleServiceProtocol {
    func startJob(request: Leyline_V1_StartJobRequest, context: ServerContext) async throws -> Leyline_V1_Job { throw unimplemented("Jobs.StartJob") }
    func listJobs(request: Leyline_V1_ListJobsRequest, context: ServerContext) async throws -> Leyline_V1_ListJobsResponse { throw unimplemented("Jobs.ListJobs") }
    func getJob(request: Leyline_V1_JobRef, context: ServerContext) async throws -> Leyline_V1_Job { throw unimplemented("Jobs.GetJob") }
    func cancelJob(request: Leyline_V1_JobRef, context: ServerContext) async throws -> Leyline_V1_Job { throw unimplemented("Jobs.CancelJob") }
    func getTranscript(request: Leyline_V1_TranscriptRequest, context: ServerContext) async throws -> Leyline_V1_Transcript { throw unimplemented("Jobs.GetTranscript") }
    func getScan(request: Leyline_V1_ScanRef, context: ServerContext) async throws -> Leyline_V1_Scan { throw unimplemented("Jobs.GetScan") }
}

struct ResourcesService: Leyline_V1_Resources.SimpleServiceProtocol {
    func listResources(request: Leyline_V1_ListResourcesRequest, context: ServerContext) async throws -> Leyline_V1_ListResourcesResponse { throw unimplemented("Resources.ListResources") }
    func getResource(request: Leyline_V1_ResourceRef, context: ServerContext) async throws -> Leyline_V1_Resource { throw unimplemented("Resources.GetResource") }
    func resolveLocalPath(request: Leyline_V1_ResourceRef, context: ServerContext) async throws -> Leyline_V1_LocalPath { throw unimplemented("Resources.ResolveLocalPath") }
}
