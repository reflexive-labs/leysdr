// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Usage: the ledger (docs/dev/engine-internals.md, "Credentials and usage"). Workers
// report over the socket like any client, so any socket client can add to the ledger; the numbers
// are what the reporters said, and the ledger shows them as that.

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct UsageService: Leyline_V1_Usage.SimpleServiceProtocol {
    let recorder: UsageRecorder
    let store: SessionStore

    func getUsage(request: Leyline_V1_GetUsageRequest, context _: ServerContext) async throws -> Leyline_V1_GetUsageResponse {
        await store.touchUnary(ClientContext.current)
        var out = Leyline_V1_GetUsageResponse()
        out.lines = await recorder.ledger.lines(matching: request)
        return out
    }

    func reportUsage(request: Leyline_V1_UsageReport, context _: ServerContext) async throws -> Leyline_V1_Empty {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            for (field, value) in [("provider", request.provider), ("model", request.model), ("feature", request.feature)]
            where value.isEmpty {
                throw EngineError.invalidArgument("a usage report names its \(field)", target: field)
            }
            await recorder.record(request, by: client)
            return Leyline_V1_Empty()
        }
    }
}
