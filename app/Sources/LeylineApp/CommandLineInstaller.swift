// SPDX-License-Identifier: Apache-2.0

// The Mac UI for installing the bundled `ley` command. A drag-and-drop disk image cannot write
// `/usr/local/bin`, so the app menu uses macOS's administrator approval for one symlink.

import AppKit
import Foundation
import LeylineClient

@MainActor
enum CommandLineInstaller {
    private static var sourcePath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/ley"
    }

    static func install() {
        switch CommandLineTool.status(sourcePath: sourcePath) {
        case .unavailable:
            show(
                headline: "This build does not include ley",
                detail: "Install Leyline from its disk image, then try again.")
            return
        case .installed:
            show(
                headline: "The ley command is installed",
                detail: "Run ley version in a new Terminal window.")
            return
        case .conflict:
            show(
                headline: "/usr/local/bin/ley already exists",
                detail: "Remove or rename the existing file, then choose Install CLI Tools again.")
            return
        case .missing, .replaceable:
            break
        }

        let command = CommandLineTool.installCommand(sourcePath: sourcePath)
        guard
            let script = NSAppleScript(
                source:
                    "do shell script \(appleScriptString(command)) with administrator privileges")
        else {
            show(
                headline: "The ley command could not be installed",
                detail: "macOS could not prepare the administrator request.")
            return
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if (error?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue == -128 { return }
        if let error {
            let reason = error["NSAppleScriptErrorMessage"] as? String ?? "macOS refused the change"
            show(
                headline: "The ley command could not be installed",
                detail: "\(reason).")
            return
        }
        show(
            headline: "The ley command is installed",
            detail: "Run ley version in a new Terminal window.")
    }

    @discardableResult
    private static func show(
        headline: String, detail: String, primary: String = "OK"
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = headline
        alert.informativeText = detail
        alert.addButton(withTitle: primary)
        return alert.runModal()
    }

    private static func appleScriptString(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
