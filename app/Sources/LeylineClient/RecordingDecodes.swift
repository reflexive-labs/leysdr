// SPDX-License-Identifier: Apache-2.0

// Decode With (docs/plans/decoders-app.md, DA-11): a decoder run over a stored recording, as
// `ley decode --recording` runs one. The Library offers the installed decoders whose input is the
// recording's kind (an audio decoder on an audio recording, an IQ decoder on an IQ one), leaving
// out the decoder Transcribe already offers, and starts a kept job with `source_uri`, as a
// transcription is; the recording's inspector says how many records each decoder found on it. The
// rules are drawn from the manifest and the jobs, never from a decoder's name.

import Foundation
import LeylineProto

public enum RecordingDecodes {
    /// The decoders Decode With lists for a recording of `kind` (`audio` or `iq`, as its
    /// manifest says), in the sidebar's order: installed, listed once, not `test_only`, reading
    /// the recording's kind of signal, and not `transcriber`, the decoder Transcribe uses.
    public static func offered(
        _ manifests: [Leyline_V1_DecoderManifest], recordingKind kind: String,
        transcriber: String?
    ) -> [Leyline_V1_DecoderManifest] {
        let iq = kind == "iq"
        return DecoderPages.listed(manifests).filter { m in
            !m.testOnly && m.name != transcriber && (m.input.signal == .signalIq) == iq
        }
    }

    /// The kept job that decodes a recording: the decoder over its stored parts, so its records
    /// are `ley://records/<job_id>` and appear on the decoder's page.
    public static func config(decoder: String, recordingURI: String) -> Leyline_V1_DecodeConfig {
        .with {
            $0.decoder = decoder
            $0.sourceUri = recordingURI
            $0.keep = true
        }
    }

    /// The decode jobs over `recordingURI` other than `transcriber`'s, the newest of each
    /// decoder first, in the order of their newest jobs.
    public static func jobs(
        of recordingURI: String, in jobs: [Leyline_V1_Job], transcriber: String?
    ) -> [Leyline_V1_Job] {
        var seen: Set<String> = []
        return jobs.filter { j in
            guard case .decode(let d)? = j.config else { return false }
            return d.sourceUri == recordingURI && d.decoder != transcriber
        }
        .sorted { $0.jobID > $1.jobID }
        .filter { j in
            guard case .decode(let d)? = j.config else { return false }
            return seen.insert(d.decoder).inserted
        }
    }

    /// Every decode job over a stored recording other than `transcriber`'s.
    public static func all(in jobs: [Leyline_V1_Job], transcriber: String?) -> [Leyline_V1_Job] {
        jobs.filter { j in
            guard case .decode(let d)? = j.config else { return false }
            return !d.sourceUri.isEmpty && d.decoder != transcriber
        }
    }

    /// How many records a job's `QueryRecords` found, and whether the daemon cut the page.
    public struct Count: Sendable, Equatable {
        public var records: Int
        public var truncated: Bool
        public init(records: Int, truncated: Bool) {
            self.records = records
            self.truncated = truncated
        }
    }

    /// The inspector's line for a decoder's newest job over the recording: `APRS: 3 records`
    /// once it has ended, `APRS: decoding · 3 records so far` while it runs, `APRS: could not
    /// decode: …` once it failed. A count not read yet is left out.
    public static func line(title: String, job: Leyline_V1_Job, count: Count?) -> String {
        let n = count.map(recordsWords)
        switch job.state {
        case .running, .degraded:
            return "\(title): decoding" + (n.map { " · \($0) so far" } ?? "")
        case .failed:
            let why = job.error.message.isEmpty ? job.statusDetail : job.error.message
            return "\(title): could not decode: \(why.isEmpty ? job.error.code : why)"
        case .cancelled:
            return "\(title): stopped" + (n.map { " · \($0)" } ?? "")
        default:
            return "\(title): " + (n ?? "counting the records…")
        }
    }

    /// `1 record`, `3 records`, `1000+ records` when the page was cut.
    public static func recordsWords(_ c: Count) -> String {
        if c.truncated { return "\(c.records)+ records" }
        return c.records == 1 ? "1 record" : "\(c.records) records"
    }
}
