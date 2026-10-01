// SPDX-License-Identifier: GPL-3.0-or-later

// Parameter writes, applied to captures and channels, and their rejections.

import EngineCore
import Foundation
import LeylineProto
import Logging

extension SessionStore {
    // MARK: Writes

    /// Applies one coalesced parameter write. Returns the rejection (nil = applied). Success emits
    /// the full state of every object the write touched.
    func applyWrite(_ w: Leyline_V1_ParamWrite, by: ClientContext) async -> EngineError? {
        do {
            switch w.param {
            case .centerHz(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                // A sweep is stepping this capture; a client write here would conflict with its
                // retunes. The lease is the only tuning path while it is held.
                try refuseIfSwept(id)
                guard let d = devices[entry.deviceID], d.canTune(hz) else { throw EngineError.freqOutOfRange(hz, target: w.targetID) }
                // A retune can bring a channel back into capture after a rate change: its chain is
                // re-planned at the current rate only then, so audio rates are reconciled here too.
                let ratesBefore = audioRates(captureID: id)
                try await entry.engine.retune(centerHz: hz)
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
            case .captureSampleRate(let hz)?:
                let (id, entry) = try captureTarget(w.targetID)
                try refuseIfSwept(id)
                guard let d = devices[entry.deviceID], d.sampleRates.isEmpty || d.sampleRates.contains(hz) else {
                    throw EngineError.rateUnsupported(hz, target: w.targetID)
                }
                let ratesBefore = audioRates(captureID: id)
                do {
                    try await entry.engine.setSampleRate(hz)
                } catch {
                    // A failed rate change still moved the engine: it is either detached (the
                    // restore failed too) or streaming again at whatever rate the device ended up
                    // on, with its channels re-planned accordingly. Publish that state before the
                    // rejection so watchers never need a GetState to learn the capture's state.
                    touchActivity(id, by: by)
                    await emitCapture(id, by: by)
                    await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
                    await teardownHook?(.captureRate(id))
                    throw error
                }
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
                await reconcileAudioRates(captureID: id, before: ratesBefore, by: by)
                // Whatever the channels re-planned to, the capture rate itself moved: bulk audio
                // scales its frame spans by it, so those streams end even when no audio rate did.
                await teardownHook?(.captureRate(id))
            case .gain(let g)?:
                let (id, entry) = try captureTarget(w.targetID)
                // The lease pins gain for the length of a sweep so every dB it reports is measured
                // against one sensitivity; a write here would move the reference mid-sweep and be
                // silently undone when the lease restores what it pinned.
                try refuseIfSwept(id)
                // Argument shape first, then the element: a NaN/inf level is malformed whatever
                // the device offers (`snapped` would otherwise search the table with NaN).
                if case .db(let db)? = g.value, !db.isFinite {
                    throw EngineError.invalidArgument("gain db must be finite", target: w.targetID)
                }
                // An empty element is the first the device lists (`common.proto`, `GainWrite`), the
                // rule the scan allocator already applies; the confirmed level and the manual level
                // are kept under the resolved name, so a client that names it and one that does not
                // read the same state back.
                guard let d = devices[entry.deviceID] else {
                    throw EngineError.gainElementUnknown(g.element, target: w.targetID)
                }
                let element = resolvedGainElement(g.element, in: d.gainElements)
                guard let el = d.gainElement(named: element) else {
                    throw unknownGainElement(element, in: d.gainElements, target: w.targetID)
                }
                func manual(_ db: Double) -> Double { el.validDB.isEmpty ? db : el.snapped(db) }
                let value: GainValue
                switch g.value {
                case .db(let db)?:
                    value = .db(manual(db))
                case .auto(true)?:
                    guard el.supportsAuto else { throw EngineError.gainElementUnknown(element, target: w.targetID) }
                    value = .auto
                case .auto(false)?:
                    // Manual, level unchanged: the confirmed manual level, else the driver's current
                    // manual level, else a mid-range default (never the minimum — that deafens the radio).
                    let current = await entry.engine.snapshot.gains.first { $0.element == element }?.value
                    if let db = entry.manualGainDB[element] {
                        value = .db(db)
                    } else if case .db(let db)? = current {
                        value = .db(db)
                    } else {
                        let sorted = el.validDB.sorted()
                        value = .db(manual(sorted.isEmpty ? (el.minDB + el.maxDB) / 2 : sorted[sorted.count / 2]))
                    }
                case nil: throw EngineError.invalidArgument("gain value is required", target: w.targetID)
                }
                try await entry.engine.setGain(element: element, value: value)
                if case .db(let db) = value { captures[id]?.manualGainDB[element] = db }
                touchActivity(id, by: by)
                await emitCapture(id, by: by)
            case .offsetHz?, .bandwidthHz?, .mode?, .squelchDb?:
                guard let chanID = ChannelID(string: w.targetID), let entry = channels[chanID] else {
                    throw EngineError.channelNotFound(w.targetID)
                }
                var config = await entry.engine.config
                let before = config
                let rate = await captures[entry.captureID]?.engine.snapshot.sampleRate ?? 0
                // A channel the capture has moved away from is already outside: non-offset writes
                // are stored for the rebuild on re-entry, so they skip the offset-vs-bandwidth check.
                let outOfCapture = await entry.engine.state == .outOfCapture
                switch w.param {
                case .offsetHz(let off)?:
                    guard Self.fits(offsetHz: off, bandwidthHz: config.bandwidthHz, sampleRate: rate) else {
                        throw EngineError.offsetOutOfCapture(off, target: w.targetID)
                    }
                    config.offsetHz = off
                case .bandwidthHz(let bw)?:
                    guard bw > 0, UInt64(bw) <= rate else {
                        throw EngineError.invalidArgument("bandwidth \(bw) Hz must be in 1...\(rate)", target: w.targetID)
                    }
                    guard outOfCapture || Self.fits(offsetHz: config.offsetHz, bandwidthHz: bw, sampleRate: rate) else {
                        throw EngineError(code: EngineError.Code.offsetOutOfCapture, message: "bandwidth \(bw) Hz does not fit the capture", target: w.targetID)
                    }
                    config.bandwidthHz = bw
                case .mode(let m)?:
                    guard let mode = ProtoMapping.demodMode(m) else {
                        throw EngineError.modeUnsupported(String(describing: m), target: w.targetID)
                    }
                    config.mode = mode
                    // The tone detector is decided by the mode: on for NFM, the only mode CTCSS is
                    // sent under, and off otherwise. It was decided at creation only, so a channel
                    // that started as WFM or AM and was written to NFM never looked for a tone
                    // (the Mac app keeps one channel across bands and writes the mode).
                    config.subAudibleDetect = mode == .nfm
                case .squelchDb(let db)?:
                    guard db.isNaN || (db <= 0 && db >= -200) else {
                        throw EngineError.invalidArgument("squelch must be a dBFS value <= 0 or NaN", target: w.targetID)
                    }
                    config.squelchDB = db
                default: break
                }
                let audioRateBefore = entry.engine.audioRate
                try await entry.engine.update(config)
                // A channel write re-plans the chain, and a channel the capture had moved away from
                // is re-planned at the capture's current rate -- which can move its audio rate. Every
                // stream negotiated at the old one is then stale, so reconcile
                // exactly as a capture-rate change does: system-audio sinks are rebuilt and bulk
                // streams -- both taps -- end for a fresh subscription.
                if entry.engine.audioRate != audioRateBefore {
                    await audioRateChanged(chanID, by: by)
                } else if Self.audioDescriptorMoved(from: before, to: config) {
                    // The rate held, but the descriptor did not: a bandwidth write rescales an NFM
                    // detector to the channel it now has, and a mode write changes what the taps
                    // carry and what full scale means. A stream negotiated before it would convert
                    // to hertz with a full-scale value the daemon has already replaced, so it ends
                    // the same way, and only the bulk streams: system-audio sinks play at the rate
                    // they have.
                    await teardownHook?(.channelAudioRate(chanID))
                }
                touchActivity(entry.captureID, by: by)
                await emitCapture(entry.captureID, by: by)
                await emitChannel(chanID, by: by)
            case .sinkVolume(let v)?:
                guard let sinkID = SinkID(string: w.targetID), var entry = sinks[sinkID], entry.isSystemAudio else {
                    throw EngineError(code: EngineError.Code.sinkNotFound, message: "no such system-audio sink", target: w.targetID)
                }
                guard v >= 0, v <= 1 else { throw EngineError.invalidArgument("volume must be within 0..1", target: w.targetID) }
                #if canImport(AVFoundation)
                (entry.sink as? CoreAudioSink)?.volume = v
                #endif
                entry.proto.systemAudio.volume = v
                sinks[sinkID] = entry
                emit(.sink(entry.proto), captureID: channels[entry.channelID]?.captureID, by: by)
            case nil:
                throw EngineError.invalidArgument("param is required", target: w.targetID)
            }
            return nil
        } catch let e as EngineError {
            return e
        } catch {
            return EngineError.internalError(String(describing: error), target: w.targetID)
        }
    }

    private func captureTarget(_ id: String) throws -> (CaptureID, CaptureEntry) {
        guard let capID = CaptureID(string: id), let entry = captures[capID] else { throw EngineError.captureNotFound(id) }
        return (capID, entry)
    }

    /// A rejected write becomes a `WriteRejected` event tagged for the client.
    func emitWriteRejected(tag: UInt64, error: EngineError, by: ClientContext) {
        var wr = Leyline_V1_WriteRejected()
        wr.tag = tag
        wr.error = ProtoMapping.errorDetail(error)
        emit(.writeRejected(wr), captureID: nil, by: by)
    }
}
