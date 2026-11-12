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

    /// The scroll view moved from `old` to `new`; `handOn` while a gesture or the scroller has it
    /// (SwiftUI's scroll phase). A move of the offset is the person's while a hand is on it, or
    /// with the content and viewport as they were and no scroll of the log's own on the way,
    /// since a mouse wheel's step need not report a phase. Content growing under a still offset
    /// is never the person, even mid-gesture. Returns whether `following` changed.
    @discardableResult
    public mutating func moved(from old: Geometry, to new: Geometry, handOn: Bool) -> Bool {
        let was = following
        let offsetMoved = abs(new.offset - old.offset) >= 0.5
        let sameSize =
            abs(new.contentHeight - old.contentHeight) < 0.5
            && abs(new.viewportHeight - old.viewportHeight) < 0.5
        if offsetMoved && (handOn || (sameSize && !pending)) {
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
