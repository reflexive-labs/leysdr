// SPDX-License-Identifier: Apache-2.0

// The menu bar's items by their titles, for the command file's `menu` and the stage's
// `settings` (docs/dev/app.md, "The command file"). A path is the titles from the menu bar down,
// joined by `>`: `View>Show Assistant`, `File>Import CHIRP…`. Three dots stand for an ellipsis,
// so a path can be typed either way. Each menu is updated before it is read, as AppKit updates a
// menu before it opens, so an item's enabled state and title are the ones a person would see.

import AppKit

@MainActor
enum AppMenus {
    /// The item at `path`: its menu and its index there, or why there is none.
    static func item(path: String) -> Result<(NSMenu, Int), MenuPathError> {
        guard var menu = NSApp.mainMenu else { return .failure(.noMenuBar) }
        let titles = path.split(separator: ">", omittingEmptySubsequences: false).map {
            normal(String($0))
        }
        for (depth, title) in titles.enumerated() {
            refresh(menu)
            guard let index = menu.items.firstIndex(where: { matches($0, title, top: depth == 0) })
            else {
                let names = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                return .failure(
                    .missing(title, in: depth == 0 ? "the menu bar" : menu.title, names: names))
            }
            if depth == titles.count - 1 { return .success((menu, index)) }
            guard let sub = menu.items[index].submenu else {
                return .failure(.notAMenu(title))
            }
            menu = sub
        }
        return .failure(.missing("", in: "the menu bar", names: []))
    }

    /// The app menu's Settings… item, found by its key equivalent (⌘,) rather than its title.
    static func settingsItem() -> (NSMenu, Int)? {
        guard let app = NSApp.mainMenu?.items.first?.submenu else { return nil }
        refresh(app)
        guard
            let index = app.items.firstIndex(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
            })
        else { return nil }
        return (app, index)
    }

    /// The menu's items as a person would see them: hidden ones left out, separators as `-`.
    static func titles(of menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// Updates the menu's items and their enabled states, as AppKit does before it opens.
    static func refresh(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    /// The menu bar's first menu is the app's, titled with the app's name in the bar but
    /// often empty in its item: `Leyline` names it either way.
    private static func matches(_ item: NSMenuItem, _ title: String, top: Bool) -> Bool {
        if item.isSeparatorItem || item.isHidden { return false }
        if normal(item.title) == title || normal(item.submenu?.title ?? "") == title {
            return true
        }
        return top && item === NSApp.mainMenu?.items.first && title == "Leyline"
    }

    private static func normal(_ s: String) -> String {
        s.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespaces)
    }
}

enum MenuPathError: Error, CustomStringConvertible {
    case noMenuBar
    case missing(String, in: String, names: [String])
    case notAMenu(String)

    var description: String {
        switch self {
        case .noMenuBar: "the app has no menu bar"
        case .missing(let title, let menu, let names):
            "\(menu) has no item \(title); it has \(names.joined(separator: ", "))"
        case .notAMenu(let title): "\(title) is an item, not a menu"
        }
    }
}
