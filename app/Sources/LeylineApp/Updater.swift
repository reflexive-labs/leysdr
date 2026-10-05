// SPDX-License-Identifier: Apache-2.0

// Sparkle, which updates the distributed app from the appcast its Info.plist names (`SUFeedURL`,
// verified against `SUPublicEDKey`): docs/plans/distribution.md, "Sparkle". The standard
// controller draws Sparkle's own windows; the app adds only "Check for Updates…" to its menu. The
// updater starts only in a bundle that names the key (`AppUpdates.shouldStart`), so `make app-run`
// and the screenshot runs neither check nor show Sparkle's failure alert. After an
// update the session restarts the daemon onto the new build (`DaemonAgent.afterConnect`).

import Combine
import Foundation
import LeylineClient
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    /// Sparkle's `canCheckForUpdates`: false while a check or an update is under way, and while
    /// the updater is not started.
    @Published private(set) var canCheck = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        let start = AppUpdates.shouldStart(
            bundlePath: Bundle.main.bundlePath,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            environment: ProcessInfo.processInfo.environment)
        if start {
            controller.startUpdater()
        } else {
            log("updates", "updater not started: not a bundle with a public key, or a staged run")
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// The app menu's item, after "About Leyline". A view rather than a bare button so it follows
/// `canCheck`, which a Commands body alone is not guaranteed to re-read.
struct CheckForUpdatesItem: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
