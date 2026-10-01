// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Runs blocking, non-cancellable work on a dedicated thread instead of the cooperative pool.
///
/// The Swift concurrency pool has as many threads as cores; a driver call that blocks for hundreds of
/// milliseconds (`rtlsdr_open` claiming a USB interface, a retry sleep, a long `ioctl`) parks one of
/// them and starves every actor in the daemon. Wrapping such calls in `BlockingWork.run` moves the
/// wait onto a fresh `Thread` and suspends the caller until it finishes (docs/dev/engine-internals.md,
/// "Threads and ownership").
///
/// Not for the hot path: spawning a thread per call is fine for open/close-class operations and for
/// the device registry's enumeration pass, which runs once a second. A thread costs microseconds to
/// create against an enumeration that blocks for hundreds of milliseconds, so a pool would save
/// nothing and would have to answer what happens when a call never returns; a thread that leaks is
/// one thread. Anything more frequent than that belongs somewhere else.
/// Cancellation is not propagated — the body always runs to completion once started.
package enum BlockingWork {
    /// Executes `body` on a new thread and resumes the caller with its result or thrown error.
    package static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            let thread = Thread {
                cont.resume(with: Result { try body() })
            }
            thread.name = "leyline.blocking-work"
            thread.start()
        }
    }
}
