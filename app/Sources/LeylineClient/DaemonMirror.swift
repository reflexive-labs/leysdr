// SPDX-License-Identifier: Apache-2.0

// The daemon's state as this client sees it, kept current by subscription. State lives in the
// daemon (CLAUDE.md invariant 7); this is a render of it, and this client's own writes show up
// here the way everyone else's do: as the event that confirmed them.
//
// The fold is the one `ley` does (`go/internal/cli/session.go`): every event carries the whole
// object (invariant 6), so folding is a replace by id, and an object whose `state` is unset is the
// tombstone -- the one and only signal it is gone (`Capture.state` in control.proto). Reconnect is
// `GetState` then `WatchEvents(since_seq)`; a gap in `seq` means the snapshot fell out of the
// daemon's retained window, and the fix is another snapshot (the seq-gap rule).

import Foundation
import LeylineProto

/// Where the mirror stands with its daemon.
public enum MirrorConnection: Sendable, Equatable {
    /// Not started, or `run()` has returned.
    case idle
    /// Dialling, or waiting to dial again.
    case connecting
    /// A snapshot is held and the event stream is open.
    case live
    /// The last attempt failed; the mirror retries after `retryIn`. `error.daemonUnreachable`
    /// is "the daemon is not running", which the app names rather than sits on.
    case unavailable(LeylineError, retryIn: Duration)
}

/// The pure fold: what the mirror holds and how an event changes it. Kept apart from the actor
/// so the rules are unit-tested without a daemon.
public struct MirrorState: Sendable, Equatable {
    public var daemon = Leyline_V1_DaemonInfo()
    public var devices: [Leyline_V1_DeviceDescriptor] = []
    public var captures: [Leyline_V1_Capture] = []
    public var channels: [Leyline_V1_Channel] = []
    public var sinks: [Leyline_V1_Sink] = []
    public var jobs: [Leyline_V1_Job] = []
    public var playbacks: [Leyline_V1_Playback] = []
    /// The newest event folded (the snapshot's `event_seq` at open). Events at or below it are
    /// already reflected and are skipped.
    public var seq: UInt64 = 0
    /// Rejections of this client's writes, newest last, at most `rejectionsKept`. Not state:
    /// a rejection is the daemon's answer to one write, and it is never stale.
    public var rejections: [Leyline_V1_WriteRejected] = []
    public static let rejectionsKept = 32

    public init() {}

    /// Replaces everything with a snapshot.
    public init(snapshot: Leyline_V1_GetStateResponse) {
        daemon = snapshot.daemon
        devices = snapshot.devices
        captures = snapshot.captures
        channels = snapshot.channels
        sinks = snapshot.sinks
        jobs = snapshot.jobs
        playbacks = snapshot.playbacks
        seq = snapshot.eventSeq
    }

    /// Folds one event and reports whether it changed anything. A stale event (seq at or below
    /// what is held) is skipped, except a rejection, which no snapshot could have reflected.
    @discardableResult
    public mutating func apply(_ event: Leyline_V1_Event) -> Bool {
        if case .writeRejected(let r) = event.body {
            rejections.append(r)
            if rejections.count > Self.rejectionsKept { rejections.removeFirst(rejections.count - Self.rejectionsKept) }
            return true
        }
        if event.seq != 0, event.seq <= seq { return false }
        if event.seq > seq { seq = event.seq }
        switch event.body {
        case .device(let d):
            // A device has no tombstone: an unplugged dongle is listed DISCONNECTED and rebinds
            // when it returns; a detached file or rtl_tcp device is emitted DISCONNECTED once too.
            replace(&devices, d, by: \.deviceID)
        case .capture(let c):
            // Unset is the destroy tombstone; CAPTURE_DETACHED is a yanked dongle whose capture
            // rebinds when it returns, so only the former leaves the mirror.
            if c.state == .unspecified { captures.removeAll { $0.captureID == c.captureID } } else { replace(&captures, c, by: \.captureID) }
        case .channel(let c):
            if c.state == .unspecified { channels.removeAll { $0.channelID == c.channelID } } else { replace(&channels, c, by: \.channelID) }
        case .sink(let s):
            if s.state == .unspecified { sinks.removeAll { $0.sinkID == s.sinkID } } else { replace(&sinks, s, by: \.sinkID) }
        case .playback(let p):
            if p.state == .unspecified { playbacks.removeAll { $0.playbackID == p.playbackID } } else { replace(&playbacks, p, by: \.playbackID) }
        case .job(let j):
            // Jobs are never tombstoned: a finished job stays listed with its state, which is
            // how a client shows "done" and the resource it produced.
            replace(&jobs, j, by: \.jobID)
        case .anchor(let a):
            if let i = captures.firstIndex(where: { $0.captureID == a.captureID }) { captures[i].anchor = a }
        case .writeRejected, .none:
            break
        }
        return true
    }

    private func replace<T>(_ list: inout [T], _ item: T, by id: KeyPath<T, String>) {
        if let i = list.firstIndex(where: { $0[keyPath: id] == item[keyPath: id] }) { list[i] = item } else { list.append(item) }
    }

    // Lookups the views need.
    public func capture(_ id: String) -> Leyline_V1_Capture? { captures.first { $0.captureID == id } }
    public func channel(_ id: String) -> Leyline_V1_Channel? { channels.first { $0.channelID == id } }
    public func device(_ id: String) -> Leyline_V1_DeviceDescriptor? { devices.first { $0.deviceID == id } }
    public func channels(in capture: String) -> [Leyline_V1_Channel] { channels.filter { $0.captureID == capture } }
    public func sinks(of channel: String) -> [Leyline_V1_Sink] { sinks.filter { $0.channelID == channel } }
    /// A channel's absolute frequency: its capture's centre plus its offset, or nil when there is
    /// no such frequency. Another client can retune a shared capture below this channel's negative
    /// offset — the channel goes `OUT_OF_CAPTURE` and keeps the offset it was given
    /// (`docs/dev/engine-internals.md`, "Control service") — and a channel below 0 Hz is not a
    /// frequency, so it is reported absent rather than trapping the render that reads it.
    public func frequencyHz(of channel: Leyline_V1_Channel) -> UInt64? {
        guard let c = capture(channel.captureID) else { return nil }
        let hz = Int64(c.centerHz) + channel.offsetHz
        guard hz >= 0 else { return nil }
        return UInt64(hz)
    }
}

/// The mirror a view renders. Main-actor, because it exists to be rendered: control events are
/// a few a second at most, and folding them on the main actor is cheaper than a hop per event.
/// Bulk rows and telemetry never pass through here; they have their own streams.
///
/// No UI framework is imported here (the façade serves AppKit, SwiftUI and tests alike, and
/// Linux's Observation library does not link into a test bundle): `onChange` fires after every
/// change, and the app's `@Observable` session copies `state` and `connection` out of it.
@MainActor
public final class DaemonMirror {
    public private(set) var state = MirrorState() { didSet { onChange?(self) } }
    public private(set) var connection: MirrorConnection = .idle { didSet { onChange?(self) } }
    /// Counts snapshots taken: one per (re)connect, plus one per seq gap. A test reads it to know
    /// the mirror re-synced rather than guessed.
    public private(set) var snapshots = 0
    /// Called on the main actor after `state` or `connection` changes.
    public var onChange: (@MainActor (DaemonMirror) -> Void)?

    public let connectionToDaemon: DaemonConnection
    private let backoff: [Duration]

    /// `connection` is the dial; `backoff` is how long to wait after a failed attempt, the last
    /// entry repeating (a daemon that is not running is polled every few seconds, not hammered).
    public init(connection: DaemonConnection, backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5)]) {
        self.connectionToDaemon = connection
        self.backoff = backoff
    }

    /// Keeps the mirror current until the task is cancelled: snapshot, subscribe from the
    /// snapshot's seq, fold; on any failure, report it in `connection` and try again after the
    /// backoff. Never throws; the failure is state the view renders.
    public func run() async {
        var attempt = 0
        defer { connection = .idle }
        while !Task.isCancelled {
            connection = .connecting
            do {
                try await syncAndFollow()
                attempt = 0  // a stream that ended cleanly (daemon shutdown) reconnects promptly
            } catch is CancellationError {
                return
            } catch {
                let wait = backoff[min(attempt, backoff.count - 1)]
                attempt += 1
                connection = .unavailable(LeylineError(error), retryIn: wait)
                do { try await Task.sleep(for: wait) } catch { return }
            }
        }
    }

    /// One snapshot and one event stream, returning when the stream ends. A seq gap resets the
    /// snapshot without leaving the stream: the events after the gap are still newer than the
    /// fresh snapshot only if their seq says so, and `apply` skips the rest.
    private func syncAndFollow() async throws {
        let snapshot = try await connectionToDaemon.state()
        state = MirrorState(snapshot: snapshot)
        snapshots += 1
        connection = .live
        var expected = state.seq &+ 1
        for try await event in connectionToDaemon.events(sinceSeq: snapshot.eventSeq) {
            if event.seq != 0, event.seq > expected {
                // The snapshot fell out of the daemon's retained window before the replay
                // reached it; the events in between are lost, and only a new snapshot is
                // whole (docs/dev/engine-internals.md, "SessionStore").
                let again = try await connectionToDaemon.state()
                let rejections = state.rejections
                state = MirrorState(snapshot: again)
                state.rejections = rejections
                snapshots += 1
            }
            state.apply(event)
            if event.seq != 0 { expected = max(expected, event.seq &+ 1) }
        }
    }
}
