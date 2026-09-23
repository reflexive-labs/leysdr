// SPDX-License-Identifier: GPL-3.0-or-later

// The daemon's stop path: what runs after a signal, and in which task.

import Foundation
@testable import LeylineDaemon
import XCTest

/// Records that a piece of teardown reached its end.
private actor Completion {
    private(set) var finished = false
    func markFinished() { finished = true }
}

final class DaemonLifecycleTests: XCTestCase {
    /// Teardown stops the listener before it hands back captures and devices, so serving ends while
    /// the rest of teardown is still running. The stop path has to let that work finish: cancelling
    /// it when serving returns leaves a sweep holding a capture lease that is never released.
    func testTeardownFinishesAfterServingReturns() async throws {
        let listener = AsyncStream<Void>.makeStream()
        let stop = AsyncStream<Void>.makeStream()
        let teardown = Completion()
        stop.continuation.yield(())
        try await serveUntilStopped(
            serve: { for await _ in listener.stream {} },
            stopRequested: { for await _ in stop.stream { break } },
            teardown: {
                listener.continuation.finish()
                // The shape of the daemon's own teardown: bounded waits that give up as soon as
                // their task is cancelled.
                for _ in 0 ..< 10 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                await teardown.markFinished()
            }
        )
        let finished = await teardown.finished
        XCTAssertTrue(finished, "teardown was cut short when serving returned")
    }

    /// A listener that dies on its own reports why, and the signal watcher parked beside it does not
    /// keep the process alive.
    func testServingFailureIsReportedWithoutTeardown() async {
        struct ListenerDied: Error {}
        do {
            try await serveUntilStopped(
                serve: { throw ListenerDied() },
                stopRequested: { try? await Task.sleep(nanoseconds: 60_000_000_000) },
                teardown: { XCTFail("teardown ran without a stop request") }
            )
            XCTFail("expected the serve failure to propagate")
        } catch is ListenerDied {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
