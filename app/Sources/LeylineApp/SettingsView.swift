// SPDX-License-Identifier: Apache-2.0

// The Settings window, which SwiftUI's `Settings` scene opens from the app menu and with ⌘,. One
// pane today, AI (`AISettingsView`). It is dark whatever the system's appearance, like the main
// window: `Theme`'s colours are drawn for a dark ground and have no light values
// (`docs/dev/app.md`, "Palette and type"), so following the system would put that ink on a
// light window.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(
            width: Theme.Layout.settingsWindow.width, height: Theme.Layout.settingsWindow.height
        )
        .background(Theme.ground)
        .preferredColorScheme(.dark)
    }
}
