import Foundation
import XCTest
@testable import EngineCore

/// `BlockingWork.run` (engine-review WI-9): blocking driver calls leave the cooperative pool.
final class BlockingWorkTests: XCTestCase {
    struct Boom: Error, Equatable {}

    func testReturnsValue() async throws {
        let v = try await BlockingWork.run { 6 * 7 }
        XCTAssertEqual(v, 42)
    }

    func testPropagatesThrownError() async {
        do {
            _ = try await BlockingWork.run { () throws -> Int in throw Boom() }
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testRunsOffCallerThread() async throws {
        let caller = Thread.current
        // (Thread.name is not read back reliably on Linux Foundation, so only identity is checked.)
        let (isMain, sameAsCaller) = try await BlockingWork.run {
            (Thread.isMainThread, Thread.current === caller)
        }
        XCTAssertFalse(isMain)
        XCTAssertFalse(sameAsCaller)
    }

    /// A body that blocks must not stall unrelated tasks: they keep making progress while it sleeps.
    func testBlockingBodyDoesNotStallOtherTasks() async throws {
        let gate = DispatchSemaphore(value: 0)
        async let blocked: Bool = BlockingWork.run {
            gate.wait()
            return true
        }
        // Runs on the pool while the thread above is parked in `gate.wait()`.
        let side = await Task { 1 + 1 }.value
        XCTAssertEqual(side, 2)
        gate.signal()
        let done = try await blocked
        XCTAssertTrue(done)
    }
}
