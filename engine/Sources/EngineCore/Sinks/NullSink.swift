// SPDX-License-Identifier: GPL-3.0-or-later

// A sink that discards everything it receives. Used by tests, the S2 harness and the channel
// engine's squelch path; allocation-free in `write`.

import Foundation
import Synchronization

/// An `AudioSink` that discards everything it receives, counting frames for diagnostics.
public final class NullSink: AudioSink, @unchecked Sendable {
    public let id: SinkID
    private let frameCount = Atomic<UInt64>(0)
    private let writeCount = Atomic<UInt64>(0)

    public init(id: SinkID = SinkID()) {
        self.id = id
    }

    /// Total frames written so far.
    public var framesWritten: UInt64 { frameCount.load(ordering: .relaxed) }
    /// Total `write` calls so far.
    public var writes: UInt64 { writeCount.load(ordering: .relaxed) }

    /// Hot path: two relaxed atomic adds, nothing else.
    public func write(_ audio: SampleBuffer, at time: SampleTime) {
        frameCount.wrappingAdd(UInt64(audio.count), ordering: .relaxed)
        writeCount.wrappingAdd(1, ordering: .relaxed)
    }

    public func flush() async {}
    public func closeSink() async {}
}
