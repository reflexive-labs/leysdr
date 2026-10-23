// SPDX-License-Identifier: Apache-2.0

// A key the command file's `key` and `type` send (docs/dev/app.md, "The command file"): its
// modifiers, the characters an `NSEvent` carries and the virtual key code of the US ANSI layout.
// Plain data, so the spellings the Go client writes (`cmd+g`, `escape`, `down`) are tested on
// Linux; the app builds the events.

import Foundation

public struct KeyChord: Sendable, Equatable {
    public enum Modifier: String, Sendable, CaseIterable {
        case command, shift, option, control
    }

    /// The keys with a name rather than a character.
    public enum Named: String, Sendable, CaseIterable {
        case `return`, escape, tab, space, delete
        case forwardDelete = "forward_delete"
        case up, down, left, right, home, end
        case pageUp = "page_up"
        case pageDown = "page_down"
    }

    public enum Key: Sendable, Equatable {
        case named(Named)
        case character(Character)
    }

    public var modifiers: Set<Modifier>
    public var key: Key

    public init(modifiers: Set<Modifier> = [], key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    private static let modifierWords: [String: Modifier] = [
        "cmd": .command, "command": .command, "shift": .shift, "opt": .option,
        "option": .option, "alt": .option, "ctrl": .control, "control": .control,
    ]

    private static let namedAliases: [String: Named] = [
        "enter": .return, "esc": .escape, "backspace": .delete, "pageup": .pageUp,
        "pagedown": .pageDown,
    ]

    /// Parses `cmd+g`, `shift+cmd+left`, `escape`, `return`: modifiers joined by `+`, then one
    /// character or a key's name, case-insensitive. nil for anything else.
    public init?(_ spelled: String) {
        let parts = spelled.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // `cmd++` is the plus key: the last empty part and the one before it.
        var words = parts
        var last = words.popLast() ?? ""
        if last.isEmpty, words.last?.isEmpty == true {
            words.removeLast()
            last = "+"
        }
        var mods: Set<Modifier> = []
        for w in words {
            guard let m = Self.modifierWords[w] else { return nil }
            mods.insert(m)
        }
        if let n = Named(rawValue: last) ?? Self.namedAliases[last] {
            self.init(modifiers: mods, key: .named(n))
        } else if last.count == 1, let c = last.first {
            self.init(modifiers: mods, key: .character(c))
        } else {
            return nil
        }
    }

    /// The key that types one character of `type`'s text: shift for a capital letter, which
    /// the US layout types with it.
    public static func typing(_ c: Character) -> KeyChord {
        let lower = Character(c.lowercased())
        let shifted = c.isLetter && c != lower
        return KeyChord(modifiers: shifted ? [.shift] : [], key: .character(c))
    }

    /// `NSEvent.characters`: what the key types. A named key gives AppKit's character for it
    /// (`NSUpArrowFunctionKey` for up), which is what a menu's key equivalent and a field's
    /// `keyDown` compare.
    public var characters: String {
        switch key {
        case .character(let c): String(c)
        case .named(let n): String(UnicodeScalar(n.scalar).map(Character.init) ?? " ")
        }
    }

    /// `NSEvent.charactersIgnoringModifiers`: the character without shift, so ⇧⌘B matches a
    /// key equivalent of `b` with shift.
    public var charactersIgnoringModifiers: String {
        switch key {
        case .character(let c): c.lowercased()
        case .named: characters
        }
    }

    /// The virtual key code on a US ANSI keyboard (`kVK_*` in Carbon's Events.h), 0xFFFF for a
    /// character that layout has no key for.
    public var keyCode: UInt16 {
        switch key {
        case .named(let n): n.keyCode
        case .character(let c): Self.characterKeyCodes[Character(c.lowercased())] ?? 0xFFFF
        }
    }

    /// Whether AppKit marks this key as a function key (the arrows, Home, End, the page keys,
    /// forward delete), as a real keyboard's event is marked.
    public var isFunctionKey: Bool {
        guard case .named(let n) = key else { return false }
        return n.scalar >= 0xF700
    }

    /// Whether AppKit marks this key as on the numeric pad: the arrows are.
    public var isArrow: Bool {
        guard case .named(let n) = key else { return false }
        return [.up, .down, .left, .right].contains(n)
    }

    private static let characterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]
}

extension KeyChord.Named {
    /// The character AppKit gives the key: ASCII for the first five, the function-key range of
    /// `NSEvent` (`NSUpArrowFunctionKey` is 0xF700) for the rest.
    var scalar: UInt32 {
        switch self {
        case .return: 0x0D
        case .escape: 0x1B
        case .tab: 0x09
        case .space: 0x20
        case .delete: 0x7F
        case .forwardDelete: 0xF728
        case .up: 0xF700
        case .down: 0xF701
        case .left: 0xF702
        case .right: 0xF703
        case .home: 0xF729
        case .end: 0xF72B
        case .pageUp: 0xF72C
        case .pageDown: 0xF72D
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .return: 36
        case .escape: 53
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .forwardDelete: 117
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        }
    }
}
