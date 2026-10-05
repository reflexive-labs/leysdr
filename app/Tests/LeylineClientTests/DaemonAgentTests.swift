// SPDX-License-Identifier: Apache-2.0

// The launch agent's decisions without ServiceManagement: what the app does on launch for each
// agent status, and when it restarts the daemon after an update.

import LeylineProto
import XCTest

@testable import LeylineClient

final class DaemonAgentTests: XCTestCase {
    private func launch(
        _ status: DaemonAgent.Status, sourcePlist: Bool = false, socket: String? = nil
    ) -> DaemonAgent.Launch {
        var env = ["HOME": "/Users/t"]
        if let socket { env["LEYLINE_SOCKET"] = socket }
        return DaemonAgent.launch(environment: env, status: status, sourcePlistExists: sourcePlist)
    }

    func testLaunchFollowsTheAgentStatus() {
        XCTAssertEqual(launch(.notRegistered), .register)
        XCTAssertEqual(
            launch(.notRegistered, sourcePlist: true), .connect,
            "a source build's job holds the label")
        XCTAssertEqual(launch(.requiresApproval), .askForApproval)
        XCTAssertEqual(launch(.requiresApproval, sourcePlist: true), .askForApproval)
        XCTAssertEqual(launch(.enabled), .connect)
        XCTAssertEqual(
            launch(.notFound), .connect, "a bundle without the daemon, or a bare executable")
    }

    func testASocketFromTheEnvironmentTouchesNoAgent() {
        for status in [DaemonAgent.Status.notRegistered, .requiresApproval, .enabled, .notFound] {
            XCTAssertEqual(launch(status, socket: "/tmp/e2e.sock"), .connect)
        }
        XCTAssertEqual(launch(.notRegistered, socket: ""), .register, "an empty value is unset")
    }

    func testTheSourceBuildPlistIsInTheUsersLaunchAgents() {
        XCTAssertEqual(
            DaemonAgent.sourceBuildPlist(environment: ["HOME": "/Users/t"]),
            "/Users/t/Library/LaunchAgents/com.leysdr.daemon.plist")
        XCTAssertEqual(DaemonAgent.plistName, "com.leysdr.daemon.plist")
    }

    func testABareDaemonVersionIsComparedWithTheShortVersion() {
        XCTAssertTrue(
            DaemonAgent.sameBuild(daemon: "0.1.0-dev", version: "0.1.0-dev", build: "412"))
        XCTAssertTrue(DaemonAgent.sameBuild(daemon: "0.1.0", version: "0.1.0", build: nil))
        XCTAssertFalse(DaemonAgent.sameBuild(daemon: "0.1.0", version: "0.1.1", build: "412"))
        XCTAssertFalse(DaemonAgent.sameBuild(daemon: "", version: "", build: nil))
    }

    func testBuildMetadataIsComparedWithTheBundleVersion() {
        XCTAssertTrue(
            DaemonAgent.sameBuild(
                daemon: "0.1.0-alpha.2+412", version: "0.1.0-alpha.2", build: "412"))
        XCTAssertFalse(
            DaemonAgent.sameBuild(
                daemon: "0.1.0-alpha.2+411", version: "0.1.0-alpha.2", build: "412"))
        XCTAssertFalse(
            DaemonAgent.sameBuild(
                daemon: "0.1.0-alpha.1+412", version: "0.1.0-alpha.2", build: "412"))
        XCTAssertFalse(
            DaemonAgent.sameBuild(daemon: "0.1.0+412", version: "0.1.0", build: nil),
            "a bundle without a build cannot match a daemon that names one")
    }

    private func after(
        daemon: String = "0.1.0", version: String? = "0.1.1", build: String? = "412",
        owns: Bool = true, jobs: Int = 0, restarted: Bool = false
    ) -> DaemonAgent.AfterConnect {
        DaemonAgent.afterConnect(
            daemonVersion: daemon, bundleVersion: version, bundleBuild: build,
            appOwnsAgent: owns, runningJobs: jobs, alreadyRestarted: restarted)
    }

    func testAnUpdatedBundleRestartsItsOwnDaemon() {
        XCTAssertEqual(after(), .restartNow)
        XCTAssertEqual(after(jobs: 1), .askToRestart, "a restart would end the job")
        XCTAssertEqual(after(daemon: "0.1.1"), .nothing)
    }

    func testNothingRestartsADaemonThatIsNotTheApps() {
        XCTAssertEqual(after(owns: false), .nothing)
        XCTAssertEqual(after(owns: false, jobs: 2), .nothing)
        XCTAssertEqual(after(version: nil), .nothing, "a bare executable has no bundle version")
    }

    func testOneRestartPerLaunch() {
        XCTAssertEqual(after(restarted: true), .nothing)
        XCTAssertEqual(after(jobs: 1, restarted: true), .nothing)
    }

    func testRunningJobsCountWhatARestartWouldEnd() {
        let jobs: [Leyline_V1_Job] = [.running, .degraded, .completed, .cancelled, .failed].map {
            s in .with { $0.state = s }
        }
        XCTAssertEqual(DaemonAgent.runningJobs(jobs), 2)
        XCTAssertEqual(DaemonAgent.runningJobs([]), 0)
    }

    func testTheApprovalWordsNameLoginItems() {
        let words = DaemonAgent.loginItemsOffWords(retryIn: .seconds(3))
        XCTAssertEqual(words.headline, "Login Items has the engine switched off")
        XCTAssertTrue(words.detail.hasPrefix("Switch Leyline on in System Settings"))
        XCTAssertTrue(words.detail.contains("retrying in"))
    }
}
