// SPDX-License-Identifier: Apache-2.0

// The payload decoders against the wire rules in bulk.proto and docs/dev/engine-internals.md
// ("Bulk service"): DB_U8 is round((dB + 120) * 2), DB_F32 and F32 audio are little-endian floats,
// S16 audio divides by 32768.

import Foundation
import LeylineProto
import XCTest

@testable import LeylineClient

final class BulkDecodeTests: XCTestCase {
    func testDBU8() {
        let levels = BulkDecode.fftLevels(Data([0, 120, 240, 255]), format: .dbU8)
        XCTAssertEqual(levels, [-120, -60, 0, 7.5])
    }

    func testDBF32IsLittleEndian() {
        var data = Data()
        for v: Float in [-42.5, 0, 3.25] {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        XCTAssertEqual(BulkDecode.fftLevels(data, format: .dbF32), [-42.5, 0, 3.25])
        XCTAssertEqual(
            BulkDecode.fftLevels(data, format: .unspecified), [-42.5, 0, 3.25],
            "unknown reads as the wire default")
    }

    func testAudioS16FullScaleNegativeIsMinusOne() {
        let data = Data([0x00, 0x80, 0xff, 0x7f, 0x00, 0x00])
        let samples = BulkDecode.audio(data, format: .s16)
        XCTAssertEqual(samples[0], -1)
        XCTAssertEqual(samples[1], Float(32767) / 32768)
        XCTAssertEqual(samples[2], 0)
    }
}
