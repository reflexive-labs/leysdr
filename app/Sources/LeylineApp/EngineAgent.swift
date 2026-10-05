// SPDX-License-Identifier: Apache-2.0

// The calls behind `DaemonAgent`'s decisions: ServiceManagement for the launch agent the bundle
// carries (`Contents/Library/LaunchAgents/com.leysdr.daemon.plist`) and `launchctl kickstart` to
// restart the daemon onto a new build. Nothing here decides anything; docs/plans/distribution.md,
// "The daemon runs from the bundle", is the behaviour.

import Foundation
import LeylineClient
import ServiceManagement

@MainActor
enum EngineAgent {
    private static var service: SMAppService { .agent(plistName: DaemonAgent.plistName) }

    static func status() -> DaemonAgent.Status {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// Registers the agent, which loads it and, with `RunAtLoad`, starts the daemon. macOS posts
    /// its own notification that a login item was added.
    static func register() throws { try service.register() }

    static func sourceBuildPlistExists() -> Bool {
        FileManager.default.fileExists(atPath: DaemonAgent.sourceBuildPlist())
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// `launchctl kickstart -k gui/<uid>/com.leysdr.daemon`: kills the running daemon and starts
    /// the job again from the bundle's binary. Nil when launchctl exits 0, else what went wrong.
    nonisolated static func kickstart() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(DaemonAgent.label)"]
        process.standardOutput = FileHandle.nullDevice
        let status: Int32? = await withCheckedContinuation { done in
            process.terminationHandler = { p in done.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                // A process that never launched never terminates, so the handler never runs.
                process.terminationHandler = nil
                done.resume(returning: nil)
            }
        }
        guard let status else { return "launchctl could not be run" }
        return status == 0 ? nil : "launchctl kickstart exited \(status)"
    }
}
