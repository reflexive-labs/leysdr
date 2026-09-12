// SPDX-License-Identifier: GPL-3.0-or-later

// The live record plane (docs/design/decoders.md, "Decisions": "Records reach clients on their own
// service"). Drop-oldest, scoped to everything, one job or one protocol, with a retained window per
// job so "start the job, then subscribe" misses nothing. Replay and live delivery both happen on
// this actor, so a subscriber can never see them interleaved.

import EngineCore
import Foundation
import LeylineProto

actor RecordHub {
    /// Records retained per job for `since_seq`, and the depth of each subscriber's buffer.
    static let capacity = 256

    enum Scope: Sendable, Hashable {
        case all
        case job(String)
        case protocolNamed(String)

        func admits(_ rec: Leyline_V1_DecodeRecord) -> Bool {
            switch self {
            case .all: return true
            case .job(let id): return rec.jobID == id
            case .protocolNamed(let name): return rec.protocol == name
            }
        }
    }

    private var sinks: [UUID: (scope: Scope, continuation: AsyncStream<Leyline_V1_DecodeRecord>.Continuation)] = [:]
    private var retained: [String: [Leyline_V1_DecodeRecord]] = [:]

    /// Live records for a scope. `sinceSeq` replays the retained window of a job scope first; nil
    /// is live only.
    func subscribe(scope: Scope, sinceSeq: UInt64?) -> AsyncStream<Leyline_V1_DecodeRecord> {
        let (stream, continuation) = AsyncStream<Leyline_V1_DecodeRecord>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.capacity))
        if let since = sinceSeq, case .job(let id) = scope {
            for rec in retained[id] ?? [] where rec.seq > since {
                continuation.yield(rec)
            }
        }
        let key = UUID()
        sinks[key] = (scope, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.drop(key) }
        }
        return stream
    }

    private func drop(_ key: UUID) { sinks[key] = nil }

    func publish(_ record: Leyline_V1_DecodeRecord) {
        var window = retained[record.jobID] ?? []
        window.append(record)
        if window.count > Self.capacity { window.removeFirst(window.count - Self.capacity) }
        retained[record.jobID] = window
        for sink in sinks.values where sink.scope.admits(record) {
            sink.continuation.yield(record)
        }
    }

    /// Ends every subscription. Shutdown, not a job ending: a kept job's stream survives its client
    /// and only the daemon going away closes it.
    func finishAll() {
        for sink in sinks.values { sink.continuation.finish() }
        sinks.removeAll()
    }

    func forget(job: String) { retained[job] = nil }
}
