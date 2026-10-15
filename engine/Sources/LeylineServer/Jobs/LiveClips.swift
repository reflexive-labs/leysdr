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

final class LiveClips: Sendable {
    /// How long a record waits for the recorder to have noted its segment's opening. The record
    /// arrives after the segment's END, half a second after the squelch closed, and the recorder
    /// notes the opening as soon as its drain reaches it, so this is a bound, not a pace.
    static let locateWaitMs = 2000
    static let locatePollMs = 50

    let recordingID: String
    let recorder: RecordRunner
    private let writer: PartWriter
    private let recordings: RecordingStore
    /// `keep`: whether the recording outlives the job (invariant 8).
    private let keep: Bool
    private let log = Logger(label: "leyline.jobs.decode")

    init(recordingID: String, recorder: RecordRunner, writer: PartWriter, recordings: RecordingStore, keep: Bool) {
        self.recordingID = recordingID
        self.recorder = recorder
        self.writer = writer
        self.recordings = recordings
        self.keep = keep
    }

    var uri: String { "ley://recordings/\(recordingID)" }

    func start() async { await recorder.start() }

    /// Ends the recording. An unkept job's clips go with it: persistence follows intent, and a
    /// job nobody kept leaves nothing behind but what its client printed.
    func stop(endedBy: String) async {
        await recorder.stop(endedBy: endedBy)
        guard !keep else { return }
        do {
            _ = try await recordings.delete(jobID: recordingID, by: "the decode job, which was not kept")
        } catch {
            log.warning("\(uri): an unkept job's clips could not be removed (\(error))")
        }
    }

    /// The part and over of the segment that starts at capture sample `start`, waiting a little
    /// for a recorder that has not reached it yet. Nil when it never does.
    func locate(segmentStart start: UInt64) async -> (uri: String, over: UInt32)? {
        var waited = 0
        while true {
            if let found = await writer.clip(forSegmentAt: start) {
                return ("\(uri)/\(found.part)", found.over)
            }
            guard waited < Self.locateWaitMs else { return nil }
            try? await Task.sleep(nanoseconds: UInt64(Self.locatePollMs) * 1_000_000)
            waited += Self.locatePollMs
        }
    }
}
