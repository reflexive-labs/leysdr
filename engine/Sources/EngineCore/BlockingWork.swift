import Foundation

/// Runs blocking, non-cancellable work on a dedicated thread instead of the cooperative pool.
///
/// The Swift concurrency pool has as many threads as cores; a driver call that blocks for hundreds of
/// milliseconds (`rtlsdr_open` claiming a USB interface, a retry sleep, a long `ioctl`) parks one of
/// them and starves every actor in the daemon. Wrapping such calls in `BlockingWork.run` moves the
/// wait onto a fresh `Thread` and suspends the caller until it finishes (docs/engine-internals.md,
/// "Threads").
///
/// Not for the hot path: spawning a thread per call is fine for open/close-class operations and
/// nothing else. Cancellation is not propagated — the body always runs to completion once started.
public enum BlockingWork {
    /// Executes `body` on a new thread and resumes the caller with its result or thrown error.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            let thread = Thread {
                cont.resume(with: Result { try body() })
            }
            thread.name = "leyline.blocking-work"
            thread.start()
        }
    }
}
