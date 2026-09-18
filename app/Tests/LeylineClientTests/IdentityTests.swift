// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRPCCore
@testable import LeylineClient
import LeylineProto
import XCTest

final class IdentityTests: XCTestCase {
    func testULIDShapeAndOrder() {
        let a = ULID.new()
        let b = ULID.new()
        XCTAssertEqual(a.string.count, 26)
        XCTAssertTrue(a.string.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertLessThan(a, b, "two ids from one process sort in the order they were made")
        XCTAssertLessThan(a.string, b.string, "and so do their strings")
        XCTAssertTrue(ClientIdentity.fresh().id.hasPrefix("app_"))
        XCTAssertEqual(ClientIdentity.fresh(kind: "cli").id.count, 4 + 26)
    }

    func testULIDEncodesTimeInTheFirstTenCharacters() {
        // 2024-01-01T00:00:00Z is 1704067200000 ms; the canonical encoding of that prefix.
        let t = Date(timeIntervalSince1970: 1_704_067_200)
        let id = ULID.new(now: t)
        XCTAssertEqual(String(id.string.prefix(10)), "01HK153X00")
    }

    func testMetadataCarriesTheThreeKeys() {
        let md = ClientIdentity(id: "app_x", kind: "app", label: "Leyline").metadata
        XCTAssertEqual(Array(md[stringValues: ClientIdentity.idKey]), ["app_x"])
        XCTAssertEqual(Array(md[stringValues: ClientIdentity.kindKey]), ["app"])
        XCTAssertEqual(Array(md[stringValues: ClientIdentity.labelKey]), ["Leyline"])
    }

    func testErrorFromTrailerKeepsTheDaemonsCode() throws {
        var detail = Leyline_V1_ErrorDetail()
        detail.code = "FREQ_OUT_OF_RANGE"
        detail.message = "1.000 GHz is outside 24.000 MHz to 1.766 GHz"
        detail.target = "cap_1"
        var md = Metadata()
        md.addBinary(try detail.serializedBytes(), forKey: LeylineError.trailerKey)
        let rpc = RPCError(code: .invalidArgument, message: "FREQ_OUT_OF_RANGE: ...", metadata: md)
        let err = LeylineError(rpc)
        XCTAssertEqual(err.code, "FREQ_OUT_OF_RANGE")
        XCTAssertEqual(err.target, "cap_1")
        XCTAssertEqual(err.status, .invalidArgument)
        XCTAssertFalse(err.daemonUnreachable)
    }

    func testErrorWithoutTrailerIsNamedByStatus() {
        let err = LeylineError(RPCError(code: .unavailable, message: "connect: no such file"))
        XCTAssertEqual(err.code, LeylineError.unavailable)
        XCTAssertTrue(err.daemonUnreachable)
        XCTAssertEqual(LeylineError(LeylineError(code: "X", message: "y")).code, "X")
    }

    func testSocketPathRule() {
        XCTAssertEqual(SocketPath.default(environment: ["LEYLINE_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        #if os(macOS)
        XCTAssertEqual(SocketPath.default(environment: ["HOME": "/Users/me"]), "/Users/me/Library/Application Support/Leyline/leyline.sock")
        #else
        XCTAssertEqual(SocketPath.default(environment: ["XDG_RUNTIME_DIR": "/run/user/1"]), "/run/user/1/leyline.sock")
        XCTAssertTrue(SocketPath.default(environment: [:]).hasPrefix("/tmp/leyline-"))
        #endif
    }
}
