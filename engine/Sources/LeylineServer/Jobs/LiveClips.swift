// SPDX-License-Identifier: GPL-3.0-or-later

// A live segmented decode job's clips: the gated recording of its channel that every record's
// `clip_uri` and `over` point into (docs/dev/engine-internals.md, "Decoders"; docs/design/ai.md,
// "A live speech job also records its audio as a gated recording").
//
// The recording is a `RecordRunner` driven as a component on the job's own channel, borrowed
// through a `BorrowedChannelLease` over the decode job's lease: one allocation, one channel, two
// sinks on it (invariant 9). The recorder keeps its own gate, its own pre-roll and its own 5 s
// hang, so its parts are exchanges while the segmenter's overs are cut at 500 ms; `over` indexes
// squelch openings, which the two see identically, so the two cuts agree on it.

import EngineCore
import Foundation
import Logging
import Synchronization

final class LiveClips: Sendable {
    /// How long a record waits for the recorder to have noted its segment's opening. The record
    /// arrives after the segment's END, half a second after the squelch closed, and the recorder
    /// notes the opening as soon as its drain reaches it, so this is a bound, not a pace.
    static let locateWaitMs = 2000
    static let locatePollMs = 50

    /// Set once the recorder has stopped, on its own (a full disk, the channel closing) or by
    /// `stop`: no record waits for a clip after that.
    final class Gone: Sendable {
        private let flag = Atomic<Bool>(false)
        var isSet: Bool { flag.load(ordering: .acquiring) }
        func set() { flag.store(true, ordering: .releasing) }
    }

    let recordingID: String
    let recorder: any RecordRunning
    private let writer: PartWriter
    private let recordings: RecordingStore
    /// `keep`: whether the recording outlives the job (invariant 8).
    private let keep: Bool
    private let gone: Gone
    private let log = Logger(label: "leyline.jobs.decode")

    init(recordingID: String, recorder: any RecordRunning, writer: PartWriter, recordings: RecordingStore, keep: Bool,
         gone: Gone = Gone())
    {
        self.recordingID = recordingID
        self.recorder = recorder
        self.writer = writer
        self.recordings = recordings
        self.keep = keep
        self.gone = gone
    }

    var uri: String { "ley://recordings/\(recordingID)" }

    func start() async { await recorder.start() }

    /// Ends the recording. `RecordRunner.stop` returns once the files are final, a teardown the
    /// recorder began on its own included, so an unkept job's clips are removed after the last
    /// write rather than under it: persistence follows intent, and a job nobody kept leaves
    /// nothing behind but what its client printed.
    func stop(endedBy: String) async {
        gone.set()
        await recorder.stop(endedBy: endedBy)
        guard !keep else { return }
        do {
            _ = try await recordings.delete(jobID: recordingID, by: "the decode job, which was not kept")
        } catch {
            log.warning("\(uri): an unkept job's clips could not be removed (\(error))")
        }
    }

    /// The part and over of the segment that starts at capture sample `start`, waiting a little
    /// for a recorder that has not reached it yet. Nil at once when the recorder has stopped or
    /// has moved past the segment without it (`PartWriter.clip(forSegmentAt:preRoll:)`), and nil
    /// after `locateWaitMs` otherwise. `preRoll` is the segment's, in capture samples.
    func locate(segmentStart start: UInt64, preRoll: UInt64) async -> (uri: String, over: UInt32)? {
        var waited = 0
        while true {
            switch await writer.clip(forSegmentAt: start, preRoll: preRoll) {
            case .found(let part, let over):
                return ("\(uri)/\(part)", over)
            case .never:
                return nil
            case .notYet:
                break
            }
            guard !gone.isSet, waited < Self.locateWaitMs else { return nil }
            try? await Task.sleep(nanoseconds: UInt64(Self.locatePollMs) * 1_000_000)
            waited += Self.locatePollMs
        }
    }
}
