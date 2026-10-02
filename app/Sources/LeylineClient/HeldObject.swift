// SPDX-License-Identifier: Apache-2.0

// The capture or channel the window shows, by id, while the mirror catches up with it. A
// `CreateCapture` or `CreateChannel` response arrives before the event that puts the object in the
// mirror, so for that gap the window keeps the object the RPC returned. The id is let go only once
// the mirror has carried the object and then lost it (a tombstone, or a resync without it): an id
// never seen and an id deleted look the same otherwise, and treating the gap as a deletion once
// made ten channels from ten tunes. An id the mirror never carries is let go after a deadline, so
// an object the daemon made and lost before its first event does not leave the window pointing at
// an id no event will carry (`docs/dev/swift-style.md`, "State and data flow in the app").

import Foundation

/// One id the window holds, the object its RPC returned until the mirror carries it, and whether
/// the mirror has carried it yet. A value, so the app's observable session stores it as one
/// property and a view sees every change.
public struct HeldObject<Object: Sendable>: Sendable {
    /// What the mirror's latest state means for the held id.
    public enum Verdict: Sendable, Equatable {
        /// No id is held, or the mirror has not carried it yet and the deadline has not passed.
        case waiting
        /// The mirror carries the object; the RPC's copy has been let go.
        case present
        /// The mirror carried the object and no longer does.
        case lost
        /// The mirror never carried the object and the deadline has passed.
        case neverArrived
    }

    public private(set) var id: String?
    /// The object the RPC returned, until the mirror carries it.
    public private(set) var pending: Object?
    /// Whether the mirror has carried the object since the id was taken or the connection came
    /// back.
    public private(set) var seen = false
    /// When the id was taken, for the never-seen deadline.
    public private(set) var takenAt = Date.distantPast

    public init() {}

    /// The window made the object: the RPC's copy is held until the mirror carries it.
    public mutating func made(_ object: Object, id: String, at now: Date) {
        self.id = id
        seen = false
        takenAt = now
        pending = object
    }

    /// The window took an object the mirror already lists (another client's, or its own from
    /// before a reconnect), so there is no RPC copy to hold.
    public mutating func adopted(id: String, at now: Date) {
        self.id = id
        takenAt = now
    }

    /// Folds one mirror state: `inMirror` is whether it lists the held id. `.lost` and
    /// `.neverArrived` leave the id held; the caller drops it, with whatever else goes with it.
    public mutating func observe(inMirror: Bool, now: Date, dropAfter seconds: TimeInterval)
        -> Verdict
    {
        guard id != nil else { return .waiting }
        if inMirror {
            seen = true
            pending = nil
            return .present
        }
        if seen { return .lost }
        if now.timeIntervalSince(takenAt) > seconds { return .neverArrived }
        return .waiting
    }

    /// The connection went down: whether the mirror carried the object is asked again of the
    /// next snapshot, so an object the restarted daemon no longer has is waited on, then let go.
    public mutating func disconnected() { seen = false }

    /// Forgets the id and the RPC's copy.
    public mutating func drop() {
        id = nil
        seen = false
        pending = nil
    }

    /// The held object: the mirror's copy through `lookup`, else the RPC's.
    public func current(_ lookup: (String) -> Object?) -> Object? {
        id.flatMap(lookup) ?? pending
    }
}

/// Equatable when the object is, so the session can fold a mirror state on a copy and store it
/// back only when something changed.
extension HeldObject: Equatable where Object: Equatable {}
