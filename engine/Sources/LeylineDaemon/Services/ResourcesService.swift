// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Resources — the stores on disk, read back (docs/design/recording.md, "The wire").
//
// Every kind that has a store is answered, rather than one kind of the service: RECORDING from the
// recordings store's manifests, RECORDS from the kept-decode store's sidecars, SCAN from the jobs
// the daemon still remembers. SNAPSHOT and TRANSCRIPT return nothing until their milestones --
// an empty list, not an error, because there are none.
//
// Samples are never streamed. `ResolveLocalPath` hands a client on this machine a path and it
// opens the file (docs/design/data-planes.md, "no lossless network stream").

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct ResourcesService: Leyline_V1_Resources.SimpleServiceProtocol {
    let jobs: JobStore
    /// Presence, not state: a client that only reads resources holds no stream, and without a
    /// touch on every call the session store reaps it.
    let store: SessionStore

    func listResources(request: Leyline_V1_ListResourcesRequest, context _: ServerContext) async throws -> Leyline_V1_ListResourcesResponse {
        await store.touchUnary(ClientContext.current)
        var out = Leyline_V1_ListResourcesResponse()
        var found: [Leyline_V1_Resource] = []
        if request.kind == .recording || request.kind == .unspecified {
            for manifest in await jobs.recordings.manifests() {
                found.append(recording(manifest, sizeBytes: await jobs.recordings.sizeOnDisk(jobID: manifest.jobID)))
            }
        }
        if request.kind == .records || request.kind == .unspecified {
            found.append(contentsOf: await jobs.records.resources())
        }
        if request.kind == .scan || request.kind == .unspecified {
            found.append(contentsOf: await scanResources())
        }
        // Newest first, whichever store a resource came from.
        out.resources = found
            .filter { matches($0, request.metadataFilter) }
            .sorted { $0.createdAtNs > $1.createdAtNs }
        return out
    }

    func getResource(request: Leyline_V1_ResourceRef, context _: ServerContext) async throws -> Leyline_V1_Resource {
        await store.touchUnary(ClientContext.current)
        let parsed = ResourceURI(request.uri)
        switch parsed {
        case .recording(let jobID, _):
            guard let manifest = await jobs.recordings.manifest(jobID: jobID) else {
                throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID))
            }
            return recording(manifest, sizeBytes: await jobs.recordings.sizeOnDisk(jobID: jobID))
        case .records(let jobID):
            guard let resource = await jobs.records.resource(jobID: jobID) else {
                throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID))
            }
            return resource
        case .scan(let scanID):
            guard let id = ScanID(string: scanID), let scan = await jobs.scan(id) else {
                throw ProtoMapping.rpcError(EngineError.scanNotFound(scanID))
            }
            return scanResource(scan)
        case .unknown:
            throw ProtoMapping.rpcError(EngineError.invalidArgument(
                "\(request.uri) is not a resource uri; they look like ley://recordings/job_01J…", target: request.uri))
        }
    }

    func resolveLocalPath(request: Leyline_V1_ResourceRef, context _: ServerContext) async throws -> Leyline_V1_LocalPath {
        await store.touchUnary(ClientContext.current)
        switch ResourceURI(request.uri) {
        case .recording(let jobID, let part):
            guard let path = await jobs.recordings.localPath(jobID: jobID, part: part) else {
                // A missing part and a missing recording get different errors, so the caller
                // can tell which it was.
                if part != nil, await jobs.recordings.manifest(jobID: jobID) != nil {
                    throw ProtoMapping.rpcError(EngineError.invalidArgument(
                        "\(request.uri) names a part this recording does not have", target: request.uri))
                }
                throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID))
            }
            var out = Leyline_V1_LocalPath()
            out.path = path
            return out
        case .records(let jobID):
            guard let path = await jobs.records.localPath(jobID: jobID) else {
                throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID))
            }
            var out = Leyline_V1_LocalPath()
            out.path = path
            return out
        case .scan, .unknown:
            // A scan lives in the daemon's memory, not on disk: there is no file to open.
            throw ProtoMapping.rpcError(EngineError.invalidArgument(
                "\(request.uri) has no file on this machine; recordings and kept records do", target: request.uri))
        }
    }

    /// A recording is deleted whole, and never while its job runs: the runner has a part open in
    /// that directory, and cancelling first finalises it (docs/design/recording.md, "The wire").
    /// Nothing goes out on the event plane -- a recording is a resource, not state -- and the job's
    /// entry stays as it is.
    func deleteResource(request: Leyline_V1_ResourceRef, context _: ServerContext) async throws -> Leyline_V1_DeletedResource {
        let client = ClientContext.current
        await store.touchUnary(client)
        switch ResourceURI(request.uri) {
        case .recording(let jobID, let part):
            if part != nil {
                throw ProtoMapping.rpcError(EngineError.invalidArgument(
                    "\(request.uri) names one part; a recording is deleted whole, as ley://recordings/\(jobID)",
                    target: request.uri))
            }
            guard await jobs.recordings.manifest(jobID: jobID) != nil else {
                throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID))
            }
            if let id = JobID(string: jobID), await jobs.jobIsLive(id) {
                throw ProtoMapping.rpcError(EngineError.failedPrecondition(
                    "\(jobID) is still recording; cancel the job first, then delete it", target: jobID))
            }
            let freed: UInt64?
            do {
                freed = try await jobs.recordings.delete(jobID: jobID, by: client.id)
            } catch {
                throw ProtoMapping.rpcError(EngineError.internalError(
                    "could not remove the recording's directory: \(error.localizedDescription)", target: jobID))
            }
            guard let freed else { throw ProtoMapping.rpcError(EngineError.jobNotFound(jobID)) }
            var out = Leyline_V1_DeletedResource()
            out.uri = "ley://recordings/\(jobID)"
            out.freedBytes = freed
            return out
        case .records, .scan, .unknown:
            // Kept records have their own lifetime (docs/design/decoders.md) and a scan is in
            // memory; only recordings are deleted through the contract in v1.
            throw ProtoMapping.rpcError(EngineError.invalidArgument(
                "\(request.uri) is not a recording; only ley://recordings/<id> can be deleted", target: request.uri))
        }
    }

    // MARK: Shapes

    private func recording(_ manifest: RecordingManifest, sizeBytes: UInt64) -> Leyline_V1_Resource {
        var r = Leyline_V1_Resource()
        r.uri = manifest.uri
        r.kind = .recording
        r.createdAtNs = manifest.startedAtNs
        r.sizeBytes = sizeBytes
        r.originatingJobID = manifest.jobID
        r.metadata = manifest.resourceMetadata
        return r
    }

    private func scanResources() async -> [Leyline_V1_Resource] {
        await jobs.snapshot().compactMap { job in
            guard case .scan = job.config, let uri = job.resultUris.first else { return nil }
            var r = Leyline_V1_Resource()
            r.uri = uri
            r.kind = .scan
            r.createdAtNs = job.createdAtNs
            r.originatingJobID = job.jobID
            r.metadata = ["state": "\(job.state)"]
            return r
        }
    }

    private func scanResource(_ scan: Leyline_V1_Scan) -> Leyline_V1_Resource {
        var r = Leyline_V1_Resource()
        r.uri = "ley://scans/\(scan.scanID)"
        r.kind = .scan
        r.createdAtNs = scan.startedAtNs
        r.metadata = [
            "detections": String(scan.detections.count),
            "min_hz": String(scan.covered.minHz),
            "max_hz": String(scan.covered.maxHz),
        ]
        return r
    }

    /// Every filter key must be present and equal. An unknown key matches nothing, because the
    /// resource does not have that field.
    private func matches(_ resource: Leyline_V1_Resource, _ filter: [String: String]) -> Bool {
        for (key, want) in filter where resource.metadata[key] != want { return false }
        return true
    }
}

/// The `ley://` forms the Resources service answers.
enum ResourceURI {
    case recording(jobID: String, part: Int?)
    case records(jobID: String)
    case scan(String)
    case unknown

    init(_ uri: String) {
        guard let rest = uri.hasPrefix("ley://") ? String(uri.dropFirst("ley://".count)) : nil else {
            self = .unknown
            return
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "recordings" where parts.count == 2:
            self = .recording(jobID: parts[1], part: nil)
        case "recordings" where parts.count == 3:
            guard let n = Int(parts[2]), n > 0 else {
                self = .unknown
                return
            }
            self = .recording(jobID: parts[1], part: n)
        case "records" where parts.count == 2:
            self = .records(jobID: parts[1])
        case "scans" where parts.count == 2:
            self = .scan(parts[1])
        default:
            self = .unknown
        }
    }
}
