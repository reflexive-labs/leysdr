// SPDX-License-Identifier: GPL-3.0-or-later

// The remembered attach list: radios a client asked the daemon to keep (docs/engine-internals.md
// "Remembered devices").

import Foundation
import Logging

/// `devices.json` beside the socket: the endpoints of every rtl_tcp radio a client attached, so a
/// station survives a restart the way the radios plugged into the machine do. A file a client plays
/// is not here -- persistence follows intent (CLAUDE.md invariant 8), and a file is a thing you
/// looked at once.
///
/// The file is rewritten on every change and read once at startup. It is advisory: a missing or
/// unreadable file means an empty list, because a daemon that cannot serve local dongles because it
/// could not parse a list of remote ones is worse than one that forgets a Pi.
actor RememberedDevices {
    struct Endpoint: Codable, Equatable, Sendable {
        var host: String
        var port: UInt16

        init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }

        /// The `host:port` an rtl_tcp descriptor carries as its serial, back into an endpoint.
        init?(serial: String) {
            guard let colon = serial.lastIndex(of: ":"), colon != serial.startIndex,
                  let port = UInt16(serial[serial.index(after: colon)...]), port > 0 else { return nil }
            self.init(host: String(serial[..<colon]), port: port)
        }
    }

    private struct File: Codable {
        var rtlTcp: [Endpoint]

        enum CodingKeys: String, CodingKey {
            case rtlTcp = "rtl_tcp"
        }
    }

    private let path: String
    private var endpoints: [Endpoint] = []
    private var loaded = false
    private let log = Logger(label: "leyline.devices")

    init(path: String) {
        self.path = path
    }

    /// `devices.json` beside a socket path.
    static func pathBeside(socket: String) -> String {
        URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent("devices.json").path
    }

    /// The remembered endpoints, read from disk the first time.
    func list() -> [Endpoint] {
        if !loaded {
            loaded = true
            if let data = FileManager.default.contents(atPath: path) {
                if let file = try? JSONDecoder().decode(File.self, from: data) {
                    endpoints = file.rtlTcp
                } else {
                    log.warning("\(path) is not a device list; starting with none")
                }
            }
        }
        return endpoints
    }

    /// Adds an endpoint and rewrites the file. Attaching a radio already remembered changes nothing.
    func remember(_ endpoint: Endpoint) {
        var list = list()
        guard !list.contains(endpoint) else { return }
        list.append(endpoint)
        endpoints = list
        write()
    }

    /// Drops an endpoint and rewrites the file. Forgetting one that was never remembered -- a radio
    /// attached by `--rtltcp` -- changes nothing.
    func forget(_ endpoint: Endpoint) {
        let list = list().filter { $0 != endpoint }
        guard list.count != endpoints.count else { return }
        endpoints = list
        write()
    }

    private func write() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(File(rtlTcp: endpoints))
            data.append(0x0a)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log.error("cannot write \(path): \(error)")
        }
    }
}
