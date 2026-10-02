// SPDX-License-Identifier: Apache-2.0

// One centre move at a time. A tune outside the capture moves the centre first and writes the
// channel's offset only once the capture's event confirms the move, because an offset applied
// against the old centre tunes a frequency nobody asked for. A second move asked for meanwhile
// waits here rather than racing the first: two at once leave the coalescer holding only the last
// centre, and the first offset written against a centre that never applied
// (`docs/dev/swift-style.md`, "State and data flow in the app"). The last move asked for wins.
//
// The queue does no I/O. `perform` is handed the centre write and its wait, and the offset write,
// so the app's session supplies the coalescer and the mirror and the tests supply fakes.

/// The centre write in flight and the move waiting behind it.
@MainActor
public final class RetuneQueue {
    /// A centre move and the offset that puts the channel back on its frequency after it.
    public struct Move: Sendable, Equatable {
        public var centre: Int64
        public var offset: Int64
        public var captureID: String
        public var channelID: String

        public init(centre: Int64, offset: Int64, captureID: String, channelID: String) {
            self.centre = centre
            self.offset = offset
            self.captureID = captureID
            self.channelID = channelID
        }
    }

    /// What `request` decided.
    public enum Request: Sendable, Equatable {
        /// Nothing is in flight: the caller starts `perform` with the move.
        case start
        /// A centre is in flight: the move waits, replacing `superseded` if one was waiting.
        case queued(superseded: Move?)
    }

    /// The centre written and not yet confirmed. Clicks meanwhile are computed against it rather
    /// than the mirror's old centre, and moves that would write a second centre wait or refuse.
    public private(set) var centreInFlight: Int64?
    /// The move asked for while a centre was in flight; `perform` runs it next.
    public private(set) var waiting: Move?

    public init() {}

    /// A move asked for. It waits when a centre is in flight, replacing any move already waiting.
    /// A started move holds the queue at once, so a second request made before `perform` runs
    /// waits instead of starting a second loop.
    public func request(_ move: Move) -> Request {
        guard centreInFlight != nil else {
            centreInFlight = move.centre
            return .start
        }
        let superseded = waiting
        waiting = move
        return .queued(superseded: superseded)
    }

    /// A centre written outside `perform` (a pan, a rate change, `Tune inside`, the first
    /// channel's move) holds the queue until it is released.
    public func hold(centre: Int64) { centreInFlight = centre }

    /// Releases the queue whatever is in flight.
    public func release() { centreInFlight = nil }

    /// Releases the queue only if `centre` is still the one in flight, so a wait that ends after
    /// a newer move began does not release the newer one.
    public func release(ifCentre centre: Int64) {
        if centreInFlight == centre { centreInFlight = nil }
    }

    /// Runs `first`, then every move that was asked for while one ran, before the queue is
    /// released, so a request made meanwhile never starts a second loop. For each move,
    /// `moveCentre` writes the centre and waits for its event; `writeOffset` follows only when
    /// nothing is waiting, because a superseded move's centre is already on its way elsewhere.
    /// `onNext` is told each time a waiting move takes over.
    public func perform(
        _ first: Move,
        moveCentre: (Move) async -> Void,
        writeOffset: (Move) -> Void,
        onNext: (_ from: Move, _ to: Move) -> Void = { _, _ in }
    ) async {
        var move = first
        while true {
            centreInFlight = move.centre
            await moveCentre(move)
            if waiting == nil { writeOffset(move) }
            guard let next = waiting else { break }
            waiting = nil
            onNext(move, next)
            move = next
        }
        centreInFlight = nil
    }
}
