// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import LeylineDaemon
import LeylineProto
import XCTest

/// The WriteParams tick loop is paced by its sleep alone, so it has to notice when the sleep stops
/// sleeping.
final class WriteCoalescerTests: XCTestCase {
    /// A cancelled handler ends its tick loop instead of spinning on a sleep that throws at once and
    /// hammering the store actor for as long as the client's stream takes to fail.
    func testCancelledRunStopsTicking() async throws {
        try await withDaemon { c in
            let coalescer = WriteCoalescer(store: c.daemon.store,
                                           client: ClientContext(id: "cli_coalescer", kind: "cli", label: "xctest"))
            let (writes, continuation) = AsyncStream<Leyline_V1_ParamWrite>.makeStream()
            let done = LockedFlag()
            let task = Task {
                _ = await coalescer.run(writes)
                done.set()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            for _ in 0..<50 where !done.value { try await Task.sleep(nanoseconds: 20_000_000) }
            // The stream outlives the assertion: a loop that ignored the cancel would otherwise spin
            // for the rest of the suite.
            continuation.finish()
            XCTAssertTrue(done.value, "a cancelled write stream must end the tick loop")
        }
    }
}
