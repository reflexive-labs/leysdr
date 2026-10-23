// SPDX-License-Identifier: GPL-3.0-or-later

// The one path a usage report takes, whether a worker sent it over the socket (`ReportUsage`) or a
// decoder put it on a record (`DecodeRunner`): into the ledger, out on the event plane as the
// whole line it changed (invariant 6), and onto the key it was made with as `last_used_at_ns`
// (docs/dev/engine-internals.md, "Credentials and usage").

import EngineCore
import Foundation
import LeylineProto

struct UsageRecorder: Sendable {
    let ledger: Ledger
    let credentials: CredentialStore
    let store: SessionStore

    func record(_ report: Leyline_V1_UsageReport, by client: ClientContext) async {
        let (line, version) = await ledger.add(report)
        await store.publishUsage(line, version: version, by: client)
        if await credentials.markUsed(provider: report.provider, atNs: line.lastAtNs) {
            await store.publishAI(from: credentials, by: client)
        }
    }
}
