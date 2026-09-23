// SPDX-License-Identifier: Apache-2.0

// The bulk plane from the client side (docs/design/data-planes.md). Frames carry descriptor-shaped
// bytes, and a frame is decoded only against the descriptor the daemon returned: the daemon may
// not grant what was requested, and DB_U8 read as DB_F32 does not look obviously wrong. These
// decoders are the Swift half of the same contract `go/pkg/leyline/bulk.go` implements, so every
// client reads a spectrum on the scale the daemon wrote it.

import Foundation
import GRPCCore
import LeylineProto

/// The DB_U8 quantisation: the daemon sends round((dB + 120) * 2) clamped to a byte, so a bin
/// covers 0.5 dB from -120 dBFS up to +7.5.
public enum DBU8 {
    public static let offset: Float = 120
    public static let scale: Float = 2
    public static let step: Float = 1 / scale
}

/// One FFT row, decoded.
public struct FFTRow: Sendable {
    public var seq: UInt64
    public var time: Leyline_V1_SampleTime
    /// dBFS per bin, lowest frequency first, `descriptor.fft.bins` long.
    public var levelsDB: [Float]
    /// Set when the daemon dropped rows before this one and the subscription is GAP_MARKED.
    public var gap: Leyline_V1_Gap?
}

public enum BulkDecode {
    /// Decodes `frames` into rows, keeping only the newest `buffer` rows waiting to be read: the
    /// same latest-wins bound as the frames. A decode stage that buffered without bound undid
    /// it, because it drains the frames as fast as they arrive: a main actor that fell behind
    /// left a backlog of minutes of rows, and the waterfall then scrolled two and three times
    /// its rate for minutes while it caught up, showing rows that were minutes old.
    /// `onTermination` runs once the consumer goes away.
    public static func fftRows(
        _ frames: AsyncThrowingStream<Leyline_V1_Frame, any Error>,
        format: Leyline_V1_FftBinFormat, buffer: Int,
        onTermination: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<FFTRow, any Error> {
        let (rows, continuation) = AsyncThrowingStream<FFTRow, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(buffer))
        let task = Task {
            do {
                for try await frame in frames {
                    continuation.yield(
                        FFTRow(
                            seq: frame.seq, time: frame.time,
                            levelsDB: fftLevels(frame.payload, format: format),
                            gap: frame.hasGap ? frame.gap : nil))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await onTermination() }
        }
        return rows
    }

    /// Turns an FFT payload into dBFS levels. Pass the format from the descriptor. An
    /// unrecognised format is read as DB_F32, the wire default.
    public static func fftLevels(_ payload: Data, format: Leyline_V1_FftBinFormat) -> [Float] {
        if format == .dbU8 {
            return payload.map { Float($0) / DBU8.scale - DBU8.offset }
        }
        return f32(payload)
    }

    /// Turns an audio payload into mono samples in [-1, 1]. Anything but F32 is read as
    /// little-endian S16, which is what the daemon serves when no format is named; the divisor is
    /// 32768 so a full-scale negative sample lands on exactly -1.
    public static func audio(_ payload: Data, format: Leyline_V1_AudioSampleFormat) -> [Float] {
        if format == .f32 { return f32(payload) }
        let count = payload.count / 2
        var out = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = Int16(
                    littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }

    static func f32(_ payload: Data) -> [Float] {
        // One unaligned load per sample rather than four byte reads or-ed together: the same
        // bytes, and an expression the type checker resolves at once (a four-term shift chain
        // hit its complexity limit under Xcode 26).
        let count = payload.count / 4
        var out = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            for i in 0..<count {
                let bits = UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
                out[i] = Float(bitPattern: bits)
            }
        }
        return out
    }
}

/// A live bulk subscription: the daemon's descriptor and the frames under it. Ending the consumer
/// cancels the `Stream` RPC; `unsubscribe()` tells the daemon so rather than waiting for the 10 s
/// reap of a subscription nobody reads.
public struct BulkSubscription: Sendable {
    public let descriptor: Leyline_V1_StreamDescriptor
    public let frames: AsyncThrowingStream<Leyline_V1_Frame, any Error>
    let connection: DaemonConnection

    public func unsubscribe() async {
        var ref = Leyline_V1_StreamRef()
        ref.streamID = descriptor.streamID
        _ = try? await connection.bulk.unsubscribe(ref)
    }
}

extension DaemonConnection {
    /// `Bulk.Subscribe` then `Bulk.Stream`, latest-wins on this side as on the daemon's: the
    /// buffer keeps the newest `buffer` frames, so a renderer that falls behind skips ahead.
    public func subscribe(_ request: Leyline_V1_SubscribeRequest, buffer: Int = 8) async throws
        -> BulkSubscription
    {
        let descriptor: Leyline_V1_StreamDescriptor
        do { descriptor = try await bulk.subscribe(request) } catch { throw LeylineError(error) }
        var ref = Leyline_V1_StreamRef()
        ref.streamID = descriptor.streamID
        let streamRef = ref
        let frames = pump(bufferingPolicy: .bufferingNewest(buffer)) { deliver in
            try await self.bulk.stream(streamRef) { response in
                for try await frame in response.messages { await deliver(frame) }
            }
        }
        return BulkSubscription(descriptor: descriptor, frames: frames, connection: self)
    }

    /// An FFT of a capture's band: `bins` from the daemon's ladder (a power of two), `rowsPerSecond`
    /// as high as the ladder allows, `format` DB_U8 (one byte a bin, plenty for pixels) unless
    /// the caller wants the float. Rows are decoded against the answered descriptor.
    public func fft(
        capture: String, bins: UInt32, rowsPerSecond: Double,
        format: Leyline_V1_FftBinFormat = .dbU8,
        accumulation: Leyline_V1_FftAccumulation = .rowSnapshot,
        policy: Leyline_V1_DeliveryPolicy = .latestWins,
        buffer: Int = 8
    ) async throws -> (
        descriptor: Leyline_V1_StreamDescriptor, rows: AsyncThrowingStream<FFTRow, any Error>
    ) {
        var req = Leyline_V1_SubscribeRequest()
        req.captureID = capture
        req.kind = .fft
        req.policy = policy
        req.fft.bins = bins
        req.fft.binFormat = format
        req.fft.rowsPerSecond = rowsPerSecond
        req.fft.accumulation = accumulation
        let sub = try await subscribe(req, buffer: buffer)
        let rows = BulkDecode.fftRows(
            sub.frames, format: sub.descriptor.fft.binFormat, buffer: buffer,
            onTermination: { await sub.unsubscribe() })
        return (sub.descriptor, rows)
    }
}
