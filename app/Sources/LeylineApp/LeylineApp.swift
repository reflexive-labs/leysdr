// SPDX-License-Identifier: Apache-2.0

// The Mac app: a peer client of the daemon (CLAUDE.md invariant 1). It renders what the mirror
// holds and writes through the coalescer; nothing here is authoritative (invariant 7). The layout
// is a walking skeleton until the design handoff lands: it proves the package builds, links the
// façade and shows the daemon's state, and no more (docs/plans/app.md, APP-1).

import LeylineClient
import SwiftUI

@main
struct LeylineApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup("Leyline") {
            ContentView()
                .environment(session)
                .task { await session.start() }
        }
        .defaultSize(width: 960, height: 640)
    }
}

/// What every view reaches for: the daemon's state and where the connection stands, copied out
/// of the mirror on every change, and the coalescer that writes through it. One identity per
/// process, so the window and its writes are one client to the daemon and `ley state` shows one
/// row for the app. Views read `state` and never the mirror, so a value they hold is one render's.
@MainActor
@Observable
final class AppSession {
    private(set) var state = MirrorState()
    private(set) var connection: MirrorConnection = .idle
    private(set) var socketPath = SocketPath.default()
    private(set) var writes: WriteCoalescer?
    private(set) var startupError: LeylineError?
    private var mirror: DaemonMirror?
    private var running: Task<Void, Never>?

    func start() async {
        guard running == nil else { return }
        do {
            let daemon = try DaemonConnection(identity: .fresh(kind: "app", label: "Leyline"))
            socketPath = daemon.socketPath
            let mirror = DaemonMirror(connection: daemon)
            mirror.onChange = { [weak self] m in
                self?.state = m.state
                self?.connection = m.connection
            }
            self.mirror = mirror
            self.writes = WriteCoalescer(connection: daemon)
            running = Task { await mirror.run() }
            await running?.value
        } catch {
            startupError = LeylineError(error)
        }
    }
}
