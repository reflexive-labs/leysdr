// SPDX-License-Identifier: Apache-2.0

// The daemon's errors as a client sees them: a stable machine code, its own sentence, and the id
// it concerns. The codes are the "Error codes" table in docs/dev/engine-internals.md; the daemon
// serialises the `ErrorDetail` into the trailer `leyline-error-bin`, and a call that never reached
// the daemon is named by its transport status instead, as `go/pkg/leyline/errors.go` does.

import Foundation
import GRPCCore
import LeylineProto
import SwiftProtobuf

public struct LeylineError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The trailer the daemon puts an `ErrorDetail` in. Binary keys travel base64 on the wire and
    /// arrive as bytes here.
    public static let trailerKey = "leyline-error-bin"

    /// A stable machine code, `FREQ_OUT_OF_RANGE`, or a transport code (`UNAVAILABLE`) when no
    /// daemon answered.
    public var code: String
    /// The daemon's prose, or the transport's.
    public var message: String
    /// The id of the object the error concerns, when the daemon named one.
    public var target: String
    /// The gRPC status the error arrived with.
    public var status: RPCError.Code?

    public init(code: String, message: String, target: String = "", status: RPCError.Code? = nil) {
        self.code = code
        self.message = message
        self.target = target
        self.status = status
    }

    /// Maps any error a call threw. An `RPCError` with the daemon's trailer keeps the daemon's
    /// code; one without gets its status's name (`UNAVAILABLE` is the daemon not running);
    /// anything else is `UNKNOWN` with its description, and a `LeylineError` passes through.
    public init(_ error: any Error) {
        if let already = error as? LeylineError {
            self = already
            return
        }
        guard let rpc = error as? RPCError else {
            self.init(code: Self.unknown, message: String(describing: error))
            return
        }
        for bytes in rpc.metadata[binaryValues: Self.trailerKey] {
            if let detail = try? Leyline_V1_ErrorDetail(serializedBytes: bytes), !detail.code.isEmpty {
                self.init(code: detail.code, message: detail.message, target: detail.target, status: rpc.code)
                return
            }
        }
        self.init(code: Self.code(for: rpc.code), message: rpc.message, status: rpc.code)
    }

    public var description: String { message.isEmpty ? code : "\(message) [\(code)]" }

    // Transport-level codes: no daemon mints these, but a call that never reached the daemon still
    // has to name what happened. Same spellings as the Go client library.
    public static let unavailable = "UNAVAILABLE"
    public static let canceled = "CANCELED"
    public static let deadlineExceeded = "DEADLINE_EXCEEDED"
    public static let notFound = "NOT_FOUND"
    public static let unknown = "UNKNOWN"

    static func code(for status: RPCError.Code) -> String {
        switch status {
        case .unavailable: return unavailable
        case .cancelled: return canceled
        case .deadlineExceeded: return deadlineExceeded
        case .notFound: return notFound
        case .invalidArgument: return "INVALID_ARGUMENT"
        case .failedPrecondition: return "FAILED_PRECONDITION"
        case .unimplemented: return "UNIMPLEMENTED"
        case .internalError: return "INTERNAL"
        default: return unknown
        }
    }

    /// True when the call never reached a daemon: the socket has no listener, or the connection
    /// dropped. The app renders this as "the daemon is not running" and keeps retrying.
    public var daemonUnreachable: Bool { code == Self.unavailable }
}
