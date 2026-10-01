// SPDX-License-Identifier: GPL-3.0-or-later

// A sink that hands every audio block to a caller-supplied closure on the DSP thread.

import Foundation
import Synchronization

/// An `AudioSink` that invokes `handler` synchronously for each block, on the DSP thread.
///
/// The `SampleBuffer` is a borrow valid only for the duration of the call: copy what you need.
/// The handler runs on the hot path, so it must not block, allocate heavily, or await. Tests and
/// the bulk-stream adapter use it to collect audio; `closeSink` disables further delivery.
public final class CallbackSink: AudioSink, Sendable {
    public typealias Handler = @Sendable (SampleBuffer, SampleTime) -> Void

    public let id: SinkID
    public let tap: AudioTap
    private let handler: Handler
    private let closed = Atomic<Bool>(false)

    public init(id: SinkID = SinkID(), tap: AudioTap = .audio, handler: @escaping Handler) {
        self.id = id
        self.tap = tap
        self.handler = handler
    }

    /// Hot path: one relaxed load and the closure call.
    public func write(_ audio: SampleBuffer, at time: SampleTime) {
        if closed.load(ordering: .relaxed) { return }
        let sp = Signpost.begin(.audioWrite)
        defer { Signpost.end(.audioWrite, sp) }
        handler(audio, time)
    }

    public func flush() async {}

    /// Stops delivery; any `write` after this returns immediately.
    public func closeSink() async {
        closed.store(true, ordering: .relaxed)
    }
}
