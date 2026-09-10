@testable import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import XCTest

/// The error table in `docs/engine-internals.md` is the contract every client reads: the stable codes
/// and the gRPC status each is served with. The Go library has the twin of this test, so a code added
/// on one side alone, or a status changed in one switch, fails on both.
final class ErrorTableTests: XCTestCase {
    func testRegistryMatchesDocumentedTable() throws {
        let table = try documentedErrorTable()
        XCTAssertEqual(Set(EngineError.Code.all), Set(table.keys),
                       "EngineError.Code.all and the table in docs/engine-internals.md disagree")
        XCTAssertEqual(EngineError.Code.all.count, Set(EngineError.Code.all).count, "duplicate code in the registry")
    }

    func testStatusCodeMatchesDocumentedTable() throws {
        for (code, want) in try documentedErrorTable() {
            XCTAssertEqual(ProtoMapping.statusCode(for: code), want, "gRPC status for \(code)")
        }
    }

    /// Reads the "### Error codes" table as code -> gRPC status.
    private func documentedErrorTable() throws -> [String: RPCError.Code] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/engine-internals.md"), encoding: .utf8)
        let statuses: [String: RPCError.Code] = [
            "NOT_FOUND": .notFound, "FAILED_PRECONDITION": .failedPrecondition, "UNAVAILABLE": .unavailable,
            "INVALID_ARGUMENT": .invalidArgument, "UNIMPLEMENTED": .unimplemented, "INTERNAL": .internalError,
        ]
        var table: [String: RPCError.Code] = [:]
        var inSection = false
        for line in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### ") {
                inSection = line == "### Error codes"
                continue
            }
            guard inSection, line.hasPrefix("| `") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            let code = cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            let status = cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard let mapped = statuses[status] else {
                XCTFail("the table gives \(code) a status this test does not know: \(status)")
                continue
            }
            table[code] = mapped
        }
        XCTAssertFalse(table.isEmpty, "no error-code rows found in docs/engine-internals.md")
        return table
    }
}
