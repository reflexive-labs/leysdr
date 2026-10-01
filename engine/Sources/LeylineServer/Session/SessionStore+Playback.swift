// SPDX-License-Identifier: GPL-3.0-or-later

// Playing a recording back through the daemon's own audio device
// (docs/dev/engine-internals.md, "Recording").

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Playing a recording back

    /// Opens the file, starts the audio device and publishes the playback. The caller has already
    /// resolved the uri to a path; this handles the audio output.
    func startPlayback(path: String, resourceURI: String, volume: Double, deviceUID: String?,
                       by client: ClientContext) async throws -> Leyline_V1_Playback
    {
        let id = PlaybackID()
        let engine = try PlaybackEngine(id: id, path: path, resourceURI: resourceURI, volume: volume,
                                        deviceUID: deviceUID, makeSink: playbackSink) { [weak self] ended in
            // The file ran out: the playback goes the way a stopped one does, so a client watching
            // its own sees the same tombstone either way.
            await self?.endPlayback(ended, by: .daemon)
        }
        playbacks[id] = PlaybackEntry(engine: engine, owner: client)
        await engine.start()
        let proto = await playbackProto(id)!
        emit(.playback(proto), captureID: nil, by: client)
        playbacks[id]?.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.playbackInterval)
                guard let self, !Task.isCancelled else { return }
                guard await self.publishPlayback(id) else { return }
            }
        }
        return proto
    }

    /// Publishes a playing playback's full state with its current position, as the daemon does
    /// on `playbackInterval` (invariant 6: the whole object every time, never a delta). False once
    /// the playback has ended, which stops the ticker.
    private func publishPlayback(_ id: PlaybackID) async -> Bool {
        guard let entry = playbacks[id], var proto = await playbackProto(id, entry: entry) else { return false }
        // Checked again after the await: an `endPlayback` that ran meanwhile has already emitted the
        // tombstone, and a playing event after it would bring the playback back in every mirror.
        guard playbacks[id] != nil else { return false }
        // A paused playback's position does not move, and `setPlaybackPaused` already published
        // it: repeating it four times a second would only push real events out of the replay
        // window. The ticker keeps running and speaks again on resume.
        if proto.paused { return true }
        proto.state = .playbackPlaying
        emit(.playback(proto), captureID: nil, by: .daemon)
        return true
    }

    /// Pauses or resumes a playback and publishes its full state at once, caused by `by`. Any
    /// client may, as any client may stop one (`stopPlaybackChecked`); the event names who did.
    /// Asking for the state it is already in publishes nothing new and is not an error.
    func setPlaybackPaused(id: PlaybackID, paused: Bool, by: ClientContext) async throws -> Leyline_V1_Playback {
        guard let entry = playbacks[id] else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        let was = await entry.engine.paused
        await entry.engine.setPaused(paused)
        guard var proto = await playbackProto(id, entry: entry) else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        // The playback may have ended during the awaits above, and its tombstone is already out.
        guard playbacks[id] != nil else {
            proto.state = .unspecified
            return proto
        }
        if was != paused { emit(.playback(proto), captureID: nil, by: by) }
        return proto
    }

    func stopPlaybackChecked(id: PlaybackID, by: ClientContext) async throws {
        guard playbacks[id] != nil else {
            throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such playback", target: id.string)
        }
        await endPlayback(id, by: by)
    }

    /// Ends a playback and emits the tombstone: the same message with `state` unset, so a client
    /// can tell "it finished" from "somebody stopped it" by who caused the event.
    private func endPlayback(_ id: PlaybackID, by: ClientContext) async {
        guard let entry = playbacks.removeValue(forKey: id) else { return }
        entry.ticker?.cancel()
        await entry.engine.stop()
        var proto = await playbackProto(id, entry: entry) ?? Leyline_V1_Playback()
        proto.playbackID = id.string
        proto.state = .unspecified
        emit(.playback(proto), captureID: nil, by: by)
    }

    func playbackProto(_ id: PlaybackID, entry: PlaybackEntry? = nil) async -> Leyline_V1_Playback? {
        guard let entry = entry ?? playbacks[id] else { return nil }
        var p = Leyline_V1_Playback()
        p.playbackID = id.string
        p.resourceUri = await entry.engine.resourceURI
        p.path = entry.engine.path
        p.sampleRate = entry.engine.sampleRate
        p.samples = entry.engine.frames
        p.position = await entry.engine.position
        p.paused = await entry.engine.paused
        p.volume = entry.engine.volume
        p.createdBy = entry.owner.proto
        p.state = .playbackPlaying
        return p
    }

    /// Every playback, for `GetState`.
    func playbackProtos() async -> [Leyline_V1_Playback] {
        var out: [Leyline_V1_Playback] = []
        for id in playbacks.keys.sorted(by: { $0.string < $1.string }) {
            if let p = await playbackProto(id) { out.append(p) }
        }
        return out
    }

    /// Ends every playback of a part of `recordingURI` (`ley://recordings/<id>`), each with its
    /// tombstone caused by `by`, as `StopPlayback` ends one. `DeleteResource` calls it before the
    /// directory goes, so nothing is left playing a file that no longer exists.
    func stopPlaybacks(of recordingURI: String, by: ClientContext) async {
        let prefix = recordingURI + "/"
        let doomed = playbacks.filter { $0.value.engine.resourceURI == recordingURI || $0.value.engine.resourceURI.hasPrefix(prefix) }
        for id in doomed.keys.sorted(by: { $0.string < $1.string }) {
            log.info("stopping playback \(id.string): \(recordingURI) is being deleted")
            await endPlayback(id, by: by)
        }
    }

    /// Ends every playback a departing client started: a playback belongs to the client that
    /// started it, so Ctrl-C in `ley play` stops it.
    func reapPlaybacks(clientID: String) async {
        for (id, entry) in playbacks where entry.owner.id == clientID {
            log.info("stopping playback \(id.string) of absent client \(clientID)")
            await endPlayback(id, by: .daemon)
        }
    }
}
