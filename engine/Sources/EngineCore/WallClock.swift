// SPDX-License-Identifier: GPL-3.0-or-later

// The wall clock the daemon dates things from. `leylined --wall-clock HH:MM` sets a fixed offset
// once at start, before any capture exists, so staged screenshots can read as a chosen time of
// day. Capture anchors, recording and job times and record-store times go through `nowNs()`;
// retention, rate limits and idle timers measure real elapsed time with `realNowNs()`.

import Foundation
import Synchronization

package enum WallClock {
    /// Nanoseconds added to CLOCK_REALTIME by `nowNs()`; zero unless `--wall-clock` set it.
    private static let offset = Atomic<Int64>(0)

    /// CLOCK_REALTIME in nanoseconds, unshifted.
    @inline(__always)
    package static func realNowNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    /// The daemon's wall clock in nanoseconds: CLOCK_REALTIME plus the `--wall-clock` offset.
    /// Lock-free and allocation-free; the capture device thread calls it.
    @inline(__always)
    package static func nowNs() -> Int64 {
        realNowNs() &+ offset.load(ordering: .relaxed)
    }

    /// The current offset in nanoseconds.
    package static var offsetNs: Int64 { offset.load(ordering: .relaxed) }

    /// Sets the offset. Called once at daemon start, before any capture exists; tests reset it to 0.
    package static func setOffsetNs(_ ns: Int64) {
        offset.store(ns, ordering: .relaxed)
    }

    /// Parses `HH:MM` (24-hour, 00:00 to 23:59).
    /// - Throws: `INVALID_ARGUMENT` for anything else.
    package static func parseClockTime(_ s: String) throws -> (hour: Int, minute: Int) {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else {
            throw EngineError.invalidArgument(
                "--wall-clock expects a 24-hour local time as HH:MM, got \"\(s)\". Pass a time such as --wall-clock 19:42",
                target: s)
        }
        return (hour, minute)
    }

    /// Nanoseconds from `now` to today's `hour:minute:00` in `timeZone`: negative when that time
    /// has passed, positive when it is still to come.
    package static func offsetNs(toHour hour: Int, minute: Int, now: Date, timeZone: TimeZone = .current) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        return Int64((target.timeIntervalSince(now) * 1e9).rounded())
    }
}
