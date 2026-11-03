// SPDX-License-Identifier: GPL-3.0-or-later

// `Control.Plan`: what a job or a retune would do, without doing it (docs/design/claims.md, "One
// decision: plan"). The request is checked as StartJob checks it, then `CapturePlanner` answers
// against the state as it is now.

import EngineCore
import Foundation
import LeylineProto

extension JobStore {
    func plan(_ request: Leyline_V1_PlanRequest, by client: ClientContext) async throws -> Leyline_V1_CapturePlan {
        let question: PlanRequest
        switch request.request {
        case .decode(let config)?:
            question = try await decodePlanRequest(config)
        case .record(let config)?:
            let (asked, borrowed) = try await recordPlanRequest(config)
            if let borrowed {
                // A recording of a channel shares that channel's capture, wherever it is.
                return Plan.share(captureID: borrowed.string).proto(in: await store.snapshot(scope: .daemon))
            }
            guard let asked else { throw EngineError.internalError("a record request with nothing to plan") }
            question = asked
        case .scan(let config)?:
            try Self.checkScan(config)
            question = .sweep(rangeHz: config.range.minHz ... config.range.maxHz,
                              deviceID: try Self.checkedDevice(config.deviceID), takeOver: config.takeOver)
        case .monitor(let config)?:
            try Self.checkMonitor(config)
            question = .sweep(rangeHz: config.range.minHz ... config.range.maxHz,
                              deviceID: try Self.checkedDevice(config.deviceID), takeOver: config.takeOver)
        case .retune(let retune)?:
            guard CaptureID(string: retune.captureID) != nil else { throw EngineError.captureNotFound(retune.captureID) }
            question = .retune(captureID: retune.captureID, centerHz: retune.centerHz, sampleRateHz: retune.sampleRateHz,
                               by: client.proto, priority: client.isInteractive ? .priorityPerson : .priorityJob,
                               takeOver: false)
        case nil:
            throw EngineError.invalidArgument("a plan needs a request: a decode, a record, a scan, a monitor or a retune",
                                              target: "")
        }
        let state = await store.snapshot(scope: .daemon)
        return CapturePlanner.plan(question, state: state).proto(in: state)
    }

    /// A device id as a scan or a monitor names it: empty for any radio, and refused when it is
    /// not a device id at all, as the job would fail with.
    private static func checkedDevice(_ id: String) throws -> String? {
        if id.isEmpty { return nil }
        guard DeviceID(string: id) != nil else { throw EngineError.deviceNotFound(id) }
        return id
    }
}

extension Plan {
    /// The plan on the wire, with the capture's radio, centre and rate filled in from `state`.
    func proto(in state: Leyline_V1_GetStateResponse) -> Leyline_V1_CapturePlan {
        var out = Leyline_V1_CapturePlan()
        switch self {
        case .share(let captureID):
            let cap = state.captures.first { $0.captureID == captureID }
            out.share = .with {
                $0.captureID = captureID
                $0.deviceID = cap?.deviceID ?? ""
                $0.centerHz = cap?.centerHz ?? 0
                $0.sampleRateHz = cap?.sampleRate ?? 0
            }
        case .create(let deviceID, let centre, let rate):
            out.create = .with {
                $0.deviceID = deviceID
                $0.centerHz = centre
                $0.sampleRateHz = rate
            }
        case .retune(let captureID, let centre, let rate, let displacing):
            out.retune = .with {
                $0.captureID = captureID
                $0.deviceID = state.captures.first { $0.captureID == captureID }?.deviceID ?? ""
                $0.centerHz = centre
                $0.sampleRateHz = rate
                $0.displaced = displacing
            }
        case .decline(let code, let reason, let blocking):
            out.decline = .with {
                $0.code = code
                $0.reason = reason
                $0.blocking = blocking
            }
        }
        return out
    }
}
