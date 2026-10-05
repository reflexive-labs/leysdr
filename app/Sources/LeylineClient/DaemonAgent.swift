// SPDX-License-Identifier: Apache-2.0

// The daemon's launch agent as the distributed app owns it (docs/plans/distribution.md, "The
// daemon runs from the bundle"): the app carries `Contents/Library/LaunchAgents/
// com.leysdr.daemon.plist`, registers it through `SMAppService` on launch and restarts the daemon
// onto a new build after an update. A source build's `ley daemon install` writes a job under the
// same label in ~/Library/LaunchAgents, and the app leaves that one alone. The decisions are here,
// without ServiceManagement or a process, so the Linux tests reach them; `LeylineApp` makes the
// calls.

import Foundation
import LeylineProto

public enum DaemonAgent {
    /// The launchd label both the app's agent and `ley daemon install`'s job use
    /// (`go/internal/cli/daemon.go`, `launchAgentLabel`).
    public static let label = "com.leysdr.daemon"
    /// The agent's plist in the app bundle, as `SMAppService.agent(plistName:)` names it.
    public static let plistName = label + ".plist"

    /// Where `ley daemon install` writes its job. When the file exists, a daemon built from
    /// source owns the label and the app registers nothing.
    public static func sourceBuildPlist(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/LaunchAgents/" + plistName
    }

    /// `SMAppService.Status`, without importing ServiceManagement. `notFound` is what a bundle
    /// laid out without the daemon (`bundle-app.sh` without `--with-daemon`) and a bare executable
    /// (`make app-run`) read: neither carries the plist, so the app registers nothing and a daemon
    /// that is down is reported with the `ley daemon start` words, as for a source build.
    public enum Status: Sendable, Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    /// What the app does about the agent before it dials.
    public enum Launch: Sendable, Equatable {
        /// Dial as a build from source does: the daemon is someone else's, or already the app's.
        case connect
        /// Register the agent, which starts the daemon (`RunAtLoad`), then dial.
        case register
        /// The agent is registered but switched off in Login Items: dial, and while the daemon
        /// cannot be reached say so and offer System Settings (`Unreachable.openLoginItems`).
        case askForApproval
    }

    /// Whether this run has anything to do with the agent. A run with `LEYLINE_SOCKET` set (the
    /// screenshots, the e2e suite) dials that socket and neither registers nor restarts the
    /// machine's daemon.
    public static func agentApplies(environment: [String: String]) -> Bool {
        (environment["LEYLINE_SOCKET"] ?? "").isEmpty
    }

    /// The launch decision. An unregistered agent is registered unless a source build's job holds
    /// the label (`sourcePlistExists`), because two jobs under one label cannot both load.
    public static func launch(
        environment: [String: String], status: Status, sourcePlistExists: Bool
    ) -> Launch {
        guard agentApplies(environment: environment) else { return .connect }
        switch status {
        case .notRegistered: return sourcePlistExists ? .connect : .register
        case .requiresApproval: return .askForApproval
        case .enabled, .notFound: return .connect
        }
    }

    /// What the empty state says and offers while the daemon cannot be reached, by who owns it.
    public enum Unreachable: Sendable, Equatable {
        /// No agent of the app's (a source build, a bundle without the daemon, a run with its own
        /// socket): the daemon is started by hand with `ley daemon start`, and nothing is offered.
        case startByHand
        /// The app's agent is switched off in Login Items: offer System Settings.
        case openLoginItems
        /// The app's agent is on but its daemon does not answer: offer `launchctl kickstart -k`.
        /// A tester who installed the app may have no `ley` on the PATH, so the words never send
        /// them to it.
        case restartEngine
    }

    /// Which unreachable state applies, from the agent status read at launch (nil when this run
    /// touches no agent).
    public static func unreachable(agentStatus: Status?) -> Unreachable {
        switch agentStatus {
        case .requiresApproval: return .openLoginItems
        case .enabled: return .restartEngine
        case .notRegistered, .notFound, nil: return .startByHand
        }
    }

    /// The empty state's words for `unreachable`. The daemon's log is where the agent's plist
    /// (`com.leysdr.daemon.plist`, `--log-file`) writes it.
    public static func unreachableWords(
        _ unreachable: Unreachable, retryIn: Duration
    ) -> (headline: String, detail: String) {
        switch unreachable {
        case .startByHand:
            return (
                "The daemon is not running",
                "Start it with `ley daemon start`; retrying in \(retryIn)."
            )
        case .openLoginItems:
            return (
                "Login Items has the engine switched off",
                "Switch Leyline on in System Settings > General > Login Items & Extensions;"
                    + " retrying in \(retryIn)."
            )
        case .restartEngine:
            return (
                "The engine is not running",
                "Restart it, or read ~/Library/Logs/Leyline/leylined.log for why it stopped;"
                    + " retrying in \(retryIn)."
            )
        }
    }

    /// The empty state's button for `unreachable`; nil when there is nothing to click.
    public static func unreachableActionTitle(_ unreachable: Unreachable) -> String? {
        switch unreachable {
        case .startByHand: return nil
        case .openLoginItems: return "Open Login Items"
        case .restartEngine: return "Restart engine"
        }
    }

    /// What the app does about the daemon once it is connected.
    public enum AfterConnect: Sendable, Equatable {
        case nothing
        /// `launchctl kickstart -k`: the daemon is restarted onto the bundle's binary.
        case restartNow
        /// A job is running and a restart would end it: show `updatedWords` with a Restart button.
        case askToRestart
    }

    public static let updatedWords = "Leyline was updated; restart the engine to finish"
    public static let restartTitle = "Restart"

    /// The decision after an update. Sparkle replaces the bundle while the daemon keeps running
    /// the old binary, and `KeepAlive` restarts it only after a crash, so the app restarts it when
    /// the daemon reports another build than the bundle's. Only the app's own agent (`appOwnsAgent`,
    /// status `.enabled`) is restarted: a source build's daemon is not the bundle's to replace.
    /// A restart ends every job, so with one running the app asks instead. `alreadyRestarted`
    /// stops a loop: a daemon that still reports another build after one restart is not one a
    /// second restart would change.
    public static func afterConnect(
        daemonVersion: String, bundleVersion: String?, bundleBuild: String?,
        appOwnsAgent: Bool, runningJobs: Int, alreadyRestarted: Bool
    ) -> AfterConnect {
        guard appOwnsAgent, !alreadyRestarted, let bundleVersion else { return .nothing }
        if sameBuild(daemon: daemonVersion, version: bundleVersion, build: bundleBuild) {
            return .nothing
        }
        return runningJobs > 0 ? .askToRestart : .restartNow
    }

    /// Whether the daemon runs the bundle's build. `leylined` reports the root VERSION file's
    /// string (`scripts/gen-version.sh`), so a daemon that reports a bare version is compared
    /// with `CFBundleShortVersionString` alone. One that carries semver build metadata,
    /// `0.1.0-alpha.2+412`, is compared with the version and `CFBundleVersion` together. An empty
    /// daemon version (one that predates the field) never matches.
    public static func sameBuild(daemon: String, version: String, build: String?) -> Bool {
        guard !daemon.isEmpty else { return false }
        guard let plus = daemon.firstIndex(of: "+") else { return daemon == version }
        guard let build, !build.isEmpty else { return false }
        return daemon[..<plus] == version && daemon[daemon.index(after: plus)...] == build
    }

    /// The jobs a restart would end: running or degraded (still running, with gaps).
    public static func runningJobs(_ jobs: [Leyline_V1_Job]) -> Int {
        jobs.filter { $0.state == .running || $0.state == .degraded }.count
    }
}
