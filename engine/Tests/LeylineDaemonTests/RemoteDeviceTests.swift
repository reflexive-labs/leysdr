// AttachDevice/DetachDevice for radios served by rtl_tcp, and the list the daemon remembers them in.

import EngineCore
import Foundation
import GRPCCore
@testable import LeylineDaemon
import LeylineProto
import TestSupport
import XCTest

/// `{"rtl_tcp":[{"host":…,"port":…}]}` beside a socket, as `host:port` strings. An absent file is
/// an empty list, which is what a daemon that never attached anything leaves behind.
func rememberedEndpoints(dir: String) throws -> [String] {
    let path = dir + "/devices.json"
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let list = file["rtl_tcp"] as? [[String: Any]] ?? []
    return list.map { "\($0["host"] ?? ""):\($0["port"] ?? "")" }
}

func rtlTcpSource(host: String, port: UInt16) -> Leyline_V1_AttachDeviceRequest {
    var src = Leyline_V1_RtlTcpSource()
    src.host = host
    src.port = UInt32(port)
    var source = Leyline_V1_DeviceSource()
    source.rtlTcp = src
    var request = Leyline_V1_AttachDeviceRequest()
    request.source = source
    return request
}

/// A directory the caller owns for the life of one test.
func withTempDir(_ body: (String) async throws -> Void) async throws {
    let dir = NSTemporaryDirectory() + "leyline-remote-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await body(dir)
}

final class RemoteDeviceTests: XCTestCase {
    /// Attaching an rtl_tcp endpoint hosts it as a device and writes it to the remembered list.
    func testAttachRemoteDevice() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                let d = try await c.control.attachDevice(rtlTcpSource(host: "127.0.0.1", port: server.port), metadata: testMetadata)
                XCTAssertEqual(d.driver, "rtltcp")
                XCTAssertEqual(d.serial, "127.0.0.1:\(server.port)")
                XCTAssertEqual(d.model, "rtl_tcp 127.0.0.1:\(server.port) (R820T)")
                XCTAssertEqual(d.features["remote"]?.text, "127.0.0.1:\(server.port)")
                XCTAssertFalse(d.gainElements.isEmpty)

                let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                XCTAssertEqual(testDevices(state.devices).map(\.deviceID), [d.deviceID])
                XCTAssertEqual(try rememberedEndpoints(dir: dir), ["127.0.0.1:\(server.port)"])
            }
        }
    }

    /// One endpoint is one radio: a second attach hands back the device already hosting it and
    /// remembers it once.
    func testAttachingTheSameEndpointTwiceReturnsTheSameDevice() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                let request = rtlTcpSource(host: "127.0.0.1", port: server.port)
                let first = try await c.control.attachDevice(request, metadata: testMetadata)
                let second = try await c.control.attachDevice(request, metadata: testMetadata)
                XCTAssertEqual(second.deviceID, first.deviceID)
                let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                XCTAssertEqual(testDevices(state.devices).count, 1)
                XCTAssertEqual(try rememberedEndpoints(dir: dir), ["127.0.0.1:\(server.port)"])
            }
        }
    }

    /// A server that cannot be reached is DEVICE_IO naming the endpoint, and nothing is remembered.
    func testAttachingAnUnreachableEndpointRemembersNothing() async throws {
        let closed = try FakeRTLTCPServer.closedPort()
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                do {
                    _ = try await c.control.attachDevice(rtlTcpSource(host: "127.0.0.1", port: closed), metadata: testMetadata)
                    XCTFail("expected DEVICE_IO")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "DEVICE_IO")
                    XCTAssertEqual(errorCode(error).trailer?.target, "127.0.0.1:\(closed)")
                    XCTAssertTrue("\(error)".contains("127.0.0.1:\(closed)"), "error must name the endpoint: \(error)")
                }
                let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                XCTAssertTrue(testDevices(state.devices).isEmpty)
                XCTAssertEqual(try rememberedEndpoints(dir: dir), [])
            }
        }
    }

    /// A host that does not resolve fails the same way.
    func testAttachingAnUnresolvableHostFails() async throws {
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                do {
                    _ = try await c.control.attachDevice(rtlTcpSource(host: "nowhere.invalid", port: 1234), metadata: testMetadata)
                    XCTFail("expected DEVICE_IO")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "DEVICE_IO")
                }
                XCTAssertEqual(try rememberedEndpoints(dir: dir), [])
            }
        }
    }

    /// Detaching a remote radio removes it and forgets the endpoint; detaching it again is
    /// DEVICE_NOT_FOUND.
    func testDetachRemoteDeviceForgetsTheEndpoint() async throws {
        let server = try FakeRTLTCPServer()
        defer { server.stop() }
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                let d = try await c.control.attachDevice(rtlTcpSource(host: "127.0.0.1", port: server.port), metadata: testMetadata)
                XCTAssertEqual(try rememberedEndpoints(dir: dir), ["127.0.0.1:\(server.port)"])

                var detach = Leyline_V1_DetachDeviceRequest()
                detach.deviceID = d.deviceID
                _ = try await c.control.detachDevice(detach, metadata: testMetadata)
                let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                XCTAssertTrue(testDevices(state.devices).isEmpty)
                XCTAssertEqual(try rememberedEndpoints(dir: dir), [])

                do {
                    _ = try await c.control.detachDevice(detach, metadata: testMetadata)
                    XCTFail("expected DEVICE_NOT_FOUND")
                } catch {
                    XCTAssertEqual(errorCode(error).code, "DEVICE_NOT_FOUND")
                }
            }
        }
    }

    /// The list outlives the daemon: a radio attached to one daemon is there when the next one
    /// starts in the same directory, with no flag and nobody asking again.
    func testRememberedEndpointComesBackWithTheNextDaemon() async throws {
        let first = try FakeRTLTCPServer()
        let port = first.port
        try await withTempDir { dir in
            try await withDaemon(dir: dir) { c in
                _ = try await c.control.attachDevice(rtlTcpSource(host: "127.0.0.1", port: port), metadata: testMetadata)
            }
            XCTAssertEqual(try rememberedEndpoints(dir: dir), ["127.0.0.1:\(port)"])
            // The fake serves one client, so the restart of the daemon is a restart of the server too.
            first.stop()
            let second = try FakeRTLTCPServer(port: port)
            defer { second.stop() }
            try await withDaemon(dir: dir) { c in
                let state = try await c.control.getState(Leyline_V1_GetStateRequest(), metadata: testMetadata)
                let devices = testDevices(state.devices)
                XCTAssertEqual(devices.map(\.serial), ["127.0.0.1:\(port)"])
                XCTAssertEqual(devices.first?.driver, "rtltcp")
            }
        }
    }
}
