// SPDX-License-Identifier: GPL-3.0-or-later

// A fake rtl_tcp server, shared by the device tests in EngineCoreTests and the attach/detach tests
// in LeylineDaemonTests. Not part of the product: this target exists only so both suites can drive
// the same fake server.

import EngineCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Minimal fake rtl_tcp server: accepts one client, sends the 12-byte header, streams a running
/// byte counter (`byte k == UInt8(k)`) and records every 5-byte command it receives.
/// Unchecked Sendable: mutable state is read and written only under `lock`.
package final class FakeRTLTCPServer: @unchecked Sendable {
    package let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var _commands: [[UInt8]] = []
    private var _clientGone = false
    private var stopped = false
    private let tuner: UInt32
    private let gainCount: UInt32
    /// Liveness of the two threads that hold the client descriptor. A descriptor closed while a
    /// thread still holds its number can be reissued to the next socket this process opens, and that
    /// thread's next send or recv then lands in someone else's connection: the server is closed and
    /// re-created on the same port in these tests, so that someone else is the device under test.
    private let acceptGroup = DispatchGroup()
    private let senderGroup = DispatchGroup()
    private var senderRunning = false

    /// - Parameter port: 0 picks an ephemeral port; pass a previous server's `port` to "restart" it.
    package init(tuner: UInt32 = 5, gainCount: UInt32 = 29, port: UInt16 = 0) throws {
        self.tuner = tuner
        self.gainCount = gainCount
        #if os(Linux)
        listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let l = listener
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(l, 1) == 0 else { close(l); throw EngineError.deviceIO("fake server bind failed") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(l, $0, &len) } }
        self.port = UInt16(bigEndian: bound.sin_port)
        let t = Thread { [self] in self.acceptLoop() }
        acceptGroup.enter()
        t.start()
    }

    package var commands: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _commands }
    package var clientGone: Bool { lock.lock(); defer { lock.unlock() }; return _clientGone }

    /// Ephemeral port that is currently closed (for connection-refused tests).
    package static func closedPort() throws -> UInt16 {
        let s = try FakeRTLTCPServer()
        let p = s.port
        s.stop()
        return p
    }

    /// Polled accept so `stop()` is noticed without closing the listener under this thread: a thread
    /// parked in accept() on a closed descriptor can be handed the next listener the process binds,
    /// and would then swallow a connection meant for it. Returns nil once the server is stopped.
    private func waitForClient() -> Int32? {
        while true {
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            lock.lock(); let done = stopped; lock.unlock()
            if done { return nil }
            if ready <= 0 { continue }
            let c = accept(listener, nil, nil)
            if c >= 0 { return c }
            if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            return nil
        }
    }

    private func acceptLoop() {
        defer { acceptGroup.leave() }
        guard let c = waitForClient() else { return }
        #if !os(Linux)
        // macOS raises SIGPIPE on a write to a closed peer (the device under test closes first
        // in several cases); Linux gets the same effect from MSG_NOSIGNAL in `sendFlags`.
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        lock.lock(); client = c; lock.unlock()
        var header: [UInt8] = [0x52, 0x54, 0x4c, 0x30]
        for v in [tuner, gainCount] { header += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        header.withUnsafeBytes { _ = send(c, $0.baseAddress!, 12, sendFlags) }
        let sender = Thread { [self] in self.streamLoop(c) }
        senderGroup.enter()
        lock.lock(); senderRunning = true; lock.unlock()
        sender.start()
        // Command reader: blocking 5-byte reads until EOF.
        var buf = [UInt8](repeating: 0, count: 5)
        outer: while true {
            var filled = 0
            while filled < 5 {
                let n = buf.withUnsafeMutableBytes { recv(c, $0.baseAddress! + filled, 5 - filled, 0) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break outer }
                filled += n
            }
            lock.lock(); _commands.append(buf); lock.unlock()
        }
        lock.lock(); _clientGone = true; lock.unlock()
    }

    private var sendFlags: Int32 {
        #if os(Linux)
        return Int32(MSG_NOSIGNAL)
        #else
        return 0
        #endif
    }

    /// Streams `UInt8(k)` for k = 0, 1, 2, ... in 4096-byte chunks, ~4 MB/s, until the client is gone.
    private func streamLoop(_ c: Int32) {
        defer { senderGroup.leave() }
        var chunk = [UInt8](repeating: 0, count: 4096)
        var k: UInt64 = 0
        while true {
            for i in 0..<4096 { chunk[i] = UInt8(truncatingIfNeeded: k &+ UInt64(i)) }
            let n = chunk.withUnsafeBytes { send(c, $0.baseAddress!, 4096, sendFlags) }
            if n <= 0 { return }
            k &+= UInt64(n)
            usleep(1000)
        }
    }

    /// Server-side drop of the client connection (simulates rtl_tcp dying). `shutdown` wakes the
    /// sender and the command reader; both are joined before the descriptor is closed, so neither
    /// can touch the number once it is back in the pool.
    package func closeClient() {
        lock.lock()
        let c = client
        client = -1
        let hadSender = senderRunning
        senderRunning = false
        lock.unlock()
        guard c >= 0 else { return }
        shutdown(c, Int32(SHUT_RDWR))
        if hadSender { _ = senderGroup.wait(timeout: .now() + 2) }
        _ = acceptGroup.wait(timeout: .now() + 2)
        close(c)
    }

    package func stop() {
        lock.lock(); let already = stopped; stopped = true; lock.unlock()
        guard !already else { return }
        closeClient()
        _ = acceptGroup.wait(timeout: .now() + 2) // the accept loop is out of the listener
        close(listener)
    }

    deinit { stop() }
}
