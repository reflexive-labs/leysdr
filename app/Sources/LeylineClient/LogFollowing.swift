// SPDX-License-Identifier: Apache-2.0

// Whether a decoder's log follows its newest record, the rule MapFraming keeps for the map: never
// move what a person has taken over. The log reads oldest at the top and newest at the bottom, as
// `ley decode` prints it, and opens scrolled to the bottom, following: a record that arrives
// scrolls into view. A person who scrolls up stops it, and what arrives after waits below,
// counted, without moving the rows they are reading, until they scroll back to the bottom or press
// the jump button. Selecting a record changes nothing here. The view holds one per log it draws, so
// opening a page or switching decoders starts following again.

import Foundation

public struct LogFollowing: Sendable, Equatable {
    /// Whether the log scrolls to each new record.
    public private(set) var following = true
    /// The records that arrived below since the person scrolled up.
    public private(set) var unseen = 0
    /// A scroll to the bottom the log asked for has not landed yet: the geometry changes it makes
    /// on the way are not the person's.
    public private(set) var pending = true

    /// How far from the bottom, in points, still counts as at the bottom: a row is 22.
    public static let tolerance: Double = 8
    /// How far up a move with no scroll phase must go to be a person's wheel: more than a row
    /// or two, which is what a record landing as the scroll view settles can shift it by.
    public static let wheelStep: Double = 44

    public init() {}

    /// Whether a scroll view's viewport reaches the end of its content, within `tolerance`. Content
    /// shorter than the viewport is always at the bottom.
    public static func atBottom(offset: Double, contentHeight: Double, viewportHeight: Double)
        -> Bool
    {
        contentHeight - (offset + viewportHeight) <= tolerance
    }

    /// What the rule reads of the log's scroll view, in points.
    public struct Geometry: Sendable, Equatable {
        public var offset: Double
        public var contentHeight: Double
        public var viewportHeight: Double

        public init(offset: Double, contentHeight: Double, viewportHeight: Double) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
        }

        public var atBottom: Bool {
            LogFollowing.atBottom(
                offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
        }
    }

    /// What is moving the scroll view, from SwiftUI's scroll phase.
    public enum Hand: Sendable, Equatable {
        /// No gesture: the log's own scroll, content changing, the scroll view settling, or a
        /// mouse wheel's step, which need not report a phase.
        case none
        /// A finger on the trackpad, or the scroller held (`interacting`, `tracking`).
        case touching
        /// The scroll view coasting after the hand lifted (`decelerating`): momentum, or the
        /// bounce back from past the bottom.
        case coasting
    }

    /// The scroll view moved from `old` to `new`. Only a move toward the top stops following:
    /// one while a hand touches it, or with no phase one of more than `wheelStep` with the
    /// content and viewport as they were and no record landed on the way (a wheel). Coasting never stops it, since the bounce
    /// back from past the bottom lags a bottom that records keep moving; a flick's momentum
    /// follows a touch that already did. Any move that reaches the bottom resumes following;
    /// content growing under a still offset changes nothing. Returns whether `following`
    /// changed.
    @discardableResult
    public mutating func moved(from old: Geometry, to new: Geometry, hand: Hand) -> Bool {
        let was = following
        let up = new.offset < old.offset - 0.5
        let sameSize =
            abs(new.contentHeight - old.contentHeight) < 0.5
            && abs(new.viewportHeight - old.viewportHeight) < 0.5
        let byPerson: Bool
        switch hand {
        case .touching: byPerson = true
        case .coasting: byPerson = false
        case .none: byPerson = sameSize && !pending && old.offset - new.offset > Self.wheelStep
        }
        if up && byPerson {
            personScrolled(atBottom: new.atBottom)
        } else {
            settled(atBottom: new.atBottom)
        }
        return was != following
    }

    /// The person scrolled (a wheel, a trackpad, the scroller) and the log now stands here:
    /// following is whether they left it at the bottom.
    public mutating func personScrolled(atBottom: Bool) {
        pending = false
        following = atBottom
        if atBottom { unseen = 0 }
    }

    /// The log's geometry changed with no person scrolling: content grew, rows dropped off the
    /// top, the window was resized, or a scroll the log asked for moved it. Only reaching the
    /// bottom changes anything: it resumes following.
    public mutating func settled(atBottom: Bool) {
        guard atBottom else { return }
        pending = false
        following = true
        unseen = 0
    }

    /// `count` records arrived at the bottom. Returns whether the log scrolls to them: it does
    /// while following, and otherwise counts them for the jump button.
    public mutating func arrived(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        if following {
            pending = true
            return true
        }
        unseen += count
        return false
    }

    /// The jump button: scroll to the bottom and follow again.
    public mutating func jump() {
        following = true
        unseen = 0
        pending = true
    }

    /// Whether the jump button shows: whenever the log is not following.
    public var showsJump: Bool { !following }

    /// The jump button's words: `3 new` with records waiting below, else `Latest`.
    public var jumpWords: String { unseen == 0 ? "Latest" : "\(unseen) new" }

    /// How many of `entries`, newest first, are newer than `newest`, the newest the log held
    /// before: the ones that arrived at the bottom. A history landing adds older records, which
    /// count for nothing; with no newest before (an empty log), none count, since the log opens
    /// at the bottom anyway.
    public static func arrivals<ID: Equatable>(_ ids: [ID], since newest: ID?) -> Int {
        guard let newest else { return 0 }
        return ids.firstIndex(of: newest) ?? ids.count
    }
}
