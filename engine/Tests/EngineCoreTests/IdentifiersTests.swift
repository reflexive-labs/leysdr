import XCTest

@testable import EngineCore

/// ULIDs key the control plane's dictionaries and sort rows for clients, so equality, hashing and
/// order have to agree with the bytes and with the string form they are printed as.
final class IdentifiersTests: XCTestCase {
    private func ulid(_ bytes: [UInt8]) -> ULID { ULID(bytes: bytes) }

    func testEqualityAndHashingFollowTheBytes() {
        let bytes: [UInt8] = [1, 2, 3, 250, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 200]
        XCTAssertEqual(ulid(bytes), ulid(bytes))
        XCTAssertEqual(ulid(bytes).hashValue, ulid(bytes).hashValue)
        for i in 0 ..< 16 {
            var other = bytes
            other[i] &+= 1
            XCTAssertNotEqual(ulid(bytes), ulid(other), "a difference in byte \(i) must not compare equal")
        }
        let table = [CaptureID(ulid: ulid(bytes)): "kept"]
        XCTAssertEqual(table[CaptureID(ulid: ulid(bytes))], "kept", "a rebuilt id must find its row")
    }

    /// A difference anywhere in the 128 bits orders the same way the bytes and the string do --
    /// including in the low half, which a comparison of only the high words would miss.
    func testOrderMatchesTheByteAndStringOrder() {
        var ids: [ULID] = []
        for i in 0 ..< 16 {
            var bytes = [UInt8](repeating: 0x7F, count: 16)
            bytes[i] = 0x80
            ids.append(ulid(bytes))
            bytes[i] = 0
            ids.append(ulid(bytes))
        }
        for a in ids {
            for b in ids {
                XCTAssertEqual(a < b, a.byteArray.lexicographicallyPrecedes(b.byteArray), "\(a) vs \(b)")
                XCTAssertEqual(a < b, a.string < b.string, "string order must be value order: \(a) vs \(b)")
            }
        }
    }

    /// Ids minted in the same millisecond still sort in creation order, which is what lets a client
    /// number rows by id.
    func testMintedIDsSortInCreationOrder() {
        let minted = (0 ..< 200).map { _ in ULID() }
        XCTAssertEqual(minted, minted.sorted())
        XCTAssertEqual(Set(minted).count, minted.count, "ids must be distinct")
    }
}
