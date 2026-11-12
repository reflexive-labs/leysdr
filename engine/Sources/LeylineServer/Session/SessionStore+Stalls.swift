// SPDX-License-Identifier: GPL-3.0-or-later

// A capture whose stream stops says so. A radio can stay listed and attached while it delivers
// nothing: on 2026-11-09 a dongle logged `PLL not locked` and libusb -4 on its register writes,
// stayed in the USB tree, and its capture read `active` for hours with no samples. So the store
// watches every capture's block count with the decode jobs' rule (`StreamStall`, 5 s): a capture
// that is attached and meant to stream and delivers nothing goes CAPTURE_STALLED with "no samples
// from <radio> for N s", and back to CAPTURE_ACTIVE on the first block. After 30 s of it the
// device is closed and opened again once; a reopen that fails, or a stream still silent 30 s
// after the reopen, makes the device NOT_ANSWERING, which detaches the capture until the radio is
// replugged (docs/dev/engine-internals.md, "A capture whose stream stops").

import EngineCore
import Foundation

/// One capture's watch: the stall rule, what it last published, and the one reopen.
struct CaptureStall: Sendable {
    /// After how long a radio that has stalled gets its one reopen, and after how long a reopened
    /// one that is still silent is given up on.
    static let defaultReopenAfter: Duration = .seconds(30)

    var rule: StreamStall
    /// The CAPTURE_STALLED detail the last capture event carried; nil while samples arrive.
    var detail: String?
    /// When the capture last delivered a block, or last changed what it streams (a rate change,
    /// a reopen, a rebind): the start of the quiet the reopen is timed from.
    var quietSince: ContinuousClock.Instant?
    var blocks: UInt64?
    var generation: UInt64 = 0
    /// The one reopen has been spent on this stall; a block arriving gives it back.
    var reopened = false
    /// A reopen is under way; the watch leaves the capture alone until it is over.
    var reopening = false

    init(after: Duration) {
        rule = StreamStall(after: after)
    }

    /// Takes one look at the stream and returns the CAPTURE_STALLED detail, or nil.
    mutating func look(_ p: StreamProgress, now: ContinuousClock.Instant) -> String? {
        if p.detached {
            quietSince = nil
            blocks = nil
        } else {
            if p.blocks != blocks {
                if blocks != nil { reopened = false }
                blocks = p.blocks
                quietSince = now
            }
            if p.generation != generation || quietSince == nil {
                generation = p.generation
                quietSince = now
            }
        }
        return rule.look(p, now: now)
    }

    /// How long the stream has been quiet, as of `now`.
    func quiet(_ now: ContinuousClock.Instant) -> Duration {
        quietSince.map { now - $0 } ?? .zero
    }
}

extension SessionStore {
    /// Starts the stall watch over every capture: a look every second (or a fifth of `after`, for
    /// a test's shortened rule).
    func startStallWatch(after: Duration = StreamStall.defaultAfter,
                         reopenAfter: Duration = CaptureStall.defaultReopenAfter)
    {
        captureStallAfter = after
        captureReopenAfter = reopenAfter
        stallTask?.cancel()
        let interval = min(after / 5, .seconds(1))
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.checkStalls()
            }
        }
    }

    /// One look at every capture.
    func checkStalls(now: ContinuousClock.Instant = .now) async {
        for id in Array(captures.keys) {
            guard let entry = captures[id], !entry.closing, !(entry.stall?.reopening ?? false),
                  let progress = await streamProgress(id) else { continue }
            // The await above can have let the capture go.
            guard let current = captures[id], !current.closing else { continue }
            var watch = current.stall ?? CaptureStall(after: captureStallAfter)
            let before = watch.detail
            watch.detail = watch.look(progress, now: now)
            captures[id]?.stall = watch
            if (before == nil) != (watch.detail == nil) {
                if let detail = watch.detail {
                    log.warning("capture \(id): \(detail)")
                } else {
                    log.info("capture \(id): samples from \(progress.radio) again")
                }
                await emitCapture(id, by: .daemon)
            }
            guard watch.detail != nil, watch.quiet(now) >= captureReopenAfter else { continue }
            let quiet = Int(watch.quiet(now).components.seconds)
            if !watch.reopened {
                await reopenStalledCapture(id, radio: progress.radio, quietSeconds: quiet)
            } else {
                // The reopen opened the radio and it is silent still: leave it alone.
                log.warning("capture \(id): still no samples from \(progress.radio) \(quiet) s after reopening it")
                await registry.markNotAnswering(id: current.deviceID,
                                                reason: "no samples for \(quiet) s after it was reopened")
            }
        }
    }

    /// The one close-and-open a stalled capture gets. A radio that will not open again is
    /// NOT_ANSWERING; the capture is detached either way until it comes back.
    private func reopenStalledCapture(_ id: CaptureID, radio: String, quietSeconds: Int) async {
        guard let entry = captures[id] else { return }
        captures[id]?.stall?.reopened = true
        captures[id]?.stall?.reopening = true
        log.warning("capture \(id): no samples from \(radio) for \(quietSeconds) s; closing and reopening it once")
        do {
            try await entry.engine.reopenDevice()
            log.info("capture \(id): reopened \(radio)")
        } catch {
            log.warning("capture \(id): reopening \(radio) failed: \(error)")
            await registry.markNotAnswering(id: entry.deviceID,
                                            reason: "no samples for \(quietSeconds) s, and reopening it failed")
        }
        captures[id]?.stall?.reopening = false
        await emitCapture(id, by: .daemon)
    }
}
