// SPDX-License-Identifier: GPL-3.0-or-later

// Sample buffers: borrowed views over engine-owned memory. Never allocated on the hot path.

import Foundation

/// Sample formats carried by `SampleBuffer`. The wire enum (leyline.v1.SampleFormat) has only
/// CS8/CS16/CF32; `.cu8` (RTL-SDR native offset-binary) and `.f32` (real mono audio) are engine-internal.
public enum SampleFormat: Hashable, Sendable {
    /// Unsigned 8-bit interleaved I/Q, offset-binary (value - 127.5 is the sample). RTL-SDR native.
    case cu8
    /// Signed 8-bit interleaved I/Q.
    case cs8
    /// Signed 16-bit interleaved I/Q.
    case cs16
    /// Float32 interleaved I/Q, nominally in [-1, 1].
    case cf32
    /// Float32 real mono (audio). `count` is frames.
    case f32

    /// Bytes per sample (one complex sample for I/Q formats, one frame for `.f32`).
    public var bytesPerSample: Int {
        switch self {
        case .cu8, .cs8: return 2
        case .cs16: return 4
        case .cf32: return 8
        case .f32: return 4
        }
    }

    public var isComplex: Bool { self != .f32 }
}

/// A borrowed view of samples. It never escapes the call it is passed to; whoever owns `base`
/// guarantees it stays valid and unaliased for the duration of that call.
public struct SampleBuffer {
    public var base: UnsafeMutableRawPointer
    /// Number of samples (complex samples for I/Q formats, frames for `.f32`).
    public var count: Int
    public var format: SampleFormat

    public init(base: UnsafeMutableRawPointer, count: Int, format: SampleFormat) {
        self.base = base
        self.count = count
        self.format = format
    }

    public var byteCount: Int { count * format.bytesPerSample }

    /// Typed view for float formats (`.cf32` has 2 floats per sample, `.f32` has 1).
    public var floats: UnsafeMutableBufferPointer<Float> {
        precondition(format == .cf32 || format == .f32, "not a float buffer")
        let n = format == .cf32 ? count * 2 : count
        return UnsafeMutableBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: n)
    }

    public var bytes: UnsafeMutableRawBufferPointer {
        UnsafeMutableRawBufferPointer(start: base, count: byteCount)
    }
}

/// Owned, preallocated, 16-byte aligned sample storage. Hand out `SampleBuffer` borrows with `view`.
/// Unchecked Sendable: the memory is shared by design; which thread may write it when is the protocol of the ring or core that owns it.
public final class SampleStorage: @unchecked Sendable {
    public let capacity: Int
    public let format: SampleFormat
    public let base: UnsafeMutableRawPointer

    public init(capacity: Int, format: SampleFormat) {
        self.capacity = capacity
        self.format = format
        let bytes = max(1, capacity * format.bytesPerSample)
        base = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
    }

    deinit { base.deallocate() }

    /// Borrow the first `count` samples (defaults to full capacity).
    public func view(count: Int? = nil) -> SampleBuffer {
        let n = count ?? capacity
        precondition(n <= capacity)
        return SampleBuffer(base: base, count: n, format: format)
    }
}
