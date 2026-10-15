// SPDX-License-Identifier: Apache-2.0

// Speech in the Library as data: the speech decoder's records (protocol `speech`, one per over;
// docs/design/ai.md, "Speech to text") folded onto a recording's parts and overs by `clip_uri`
// and `over`, the newest transcription shown and the earlier ones kept beside it (records are
// immutable, so transcribing again adds records), the stretch of a part one over plays, the
// search that finds a recording by what was said, the plain-text and SRT exports, and the job
// that transcribes a recording. A wall-clock time comes only from the manifest's anchors
// (invariant 5). No Observation here, so the Linux tests cover every rule.

import Foundation
import LeylineProto

/// One over's words as one speech record gave them.
public struct SpeechLine: Sendable, Equatable, Identifiable {
    /// The transcription job that made the record, and the record's own id.
    public var jobID: String
    public var recordID: String
    /// The recording the over is in (its job id), the part, `ley://recordings/<id>/<part>`, and
    /// the over: the index in the part's `squelch_opens` of the first opening the segment holds,
    /// counted from 1; 0 when the input was not cut into overs.
    public var recordingID: String
    public var part: Int
    public var partURI: String
    public var over: Int
    /// What the model heard, as it wrote it.
    public var text: String
    /// The model that produced the text; empty when the record does not say.
    public var model: String
    /// The engine's own confidence, 0 to 1, when it reports one.
    public var confidence: Double?
    /// Callsigns a pattern found in the text, not decoded identities.
    public var callsigns: [String]
    /// The over's first sample on its capture's timeline.
    public var time: Leyline_V1_SampleTime
    /// `time` as wall clock through the manifest's anchors; nil until a manifest dates it.
    public var wallTime: Date?
    /// The record's place in its job's stream, which breaks a tie between two records of one over.
    public var seq: UInt64

    public var id: String { recordID }

    public init(
        jobID: String, recordID: String, recordingID: String, part: Int, over: Int, text: String,
        model: String = "", confidence: Double? = nil, callsigns: [String] = [],
        time: Leyline_V1_SampleTime = .init(), wallTime: Date? = nil, seq: UInt64 = 0
    ) {
        self.jobID = jobID
        self.recordID = recordID
        self.recordingID = recordingID
        self.part = part
        partURI = "ley://recordings/\(recordingID)/\(part)"
        self.over = over
        self.text = text
        self.model = model
        self.confidence = confidence
        self.callsigns = callsigns
        self.time = time
        self.wallTime = wallTime
        self.seq = seq
    }

    /// The record as a line, or nil when it is not speech or names no recording part.
    public init?(_ r: Leyline_V1_DecodeRecord) {
        guard r.protocol == SpeechRecords.protocolName, let ref = RecordingPartRef(uri: r.clipUri)
        else { return nil }
        self.init(
            jobID: r.jobID, recordID: r.recordID, recordingID: ref.jobID, part: ref.part,
            over: Int(r.over), text: SpeechRecords.text(r.fields["text"]),
            model: SpeechRecords.text(r.fields["model"]),
            confidence: SpeechRecords.number(r.fields["confidence"]),
            callsigns: SpeechRecords.callsigns(SpeechRecords.text(r.fields["callsigns"])),
            time: r.time, seq: r.seq)
    }

    /// `whisper-1 · 92%`: the model and the confidence, as the line's muted words; the model
    /// alone without a confidence, and empty when neither is known.
    public var sourceWords: String {
        var words: [String] = []
        if !model.isEmpty { words.append(model) }
        if let c = confidence, c.isFinite {
            words.append("\(Int((min(1, max(0, c)) * 100).rounded()))%")
        }
        return words.joined(separator: " · ")
    }
}

/// One recording's speech: every line its transcriptions made, and the lines the Library shows.
public struct RecordingSpeech: Sendable, Equatable {
    /// Every line of every transcription of the recording, dated through the manifest.
    public var all: [SpeechLine]
    /// The transcription jobs, newest first (a job id is a ULID, so its order is its age).
    public var jobs: [String]
    /// `shown()`, worked out once: the page and the search read it on every render.
    public private(set) var newest: [SpeechLine]

    public init(lines: [SpeechLine], manifest: RecordingManifest?) {
        all = lines.map { line in
            var l = line
            if let m = manifest, l.wallTime == nil {
                l.wallTime = SpeechRecords.wallTime(of: l, in: m)
            }
            return l
        }
        jobs = Array(Set(all.map(\.jobID))).sorted(by: >)
        newest = []
        newest = pick(job: nil)
    }

    /// The lines shown: for each over, the newest transcription's line, so transcribing again
    /// replaces what is shown and keeps what was there; with `job`, that transcription's lines
    /// only. In part order, then over order. Two records of one over from one job (a segment the
    /// daemon sent again after a restart) show the later one.
    public func shown(job: String? = nil) -> [SpeechLine] {
        job == nil ? newest : pick(job: job)
    }

    private func pick(job: String?) -> [SpeechLine] {
        var best: [String: SpeechLine] = [:]
        for l in all where job == nil || l.jobID == job {
            let key = "\(l.part)/\(l.over)"
            if let held = best[key], (held.jobID, held.seq) >= (l.jobID, l.seq) { continue }
            best[key] = l
        }
        return best.values.sorted(by: SpeechRecords.inOrder)
    }

    /// The shown lines of one part.
    public func shown(part: Int, job: String? = nil) -> [SpeechLine] {
        shown(job: job).filter { $0.part == part }
    }

    /// Every transcription of one over, newest first: what "earlier transcriptions" lists.
    public func versions(part: Int, over: Int) -> [SpeechLine] {
        all.filter { $0.part == part && $0.over == over }
            .sorted { ($0.jobID, $0.seq) > ($1.jobID, $1.seq) }
    }
}

/// The search field's speech hit: the line whose words hold the query, for the Library to select
/// its part and scroll to its over.
public struct SpeechHit: Sendable, Equatable {
    public var line: SpeechLine
    public var partURI: String { line.partURI }
    public var over: Int { line.over }
}

/// The export formats of a recording's speech.
public enum SpeechExportFormat: String, Sendable, CaseIterable {
    case text
    case srt

    /// The file name's extension.
    public var fileExtension: String { self == .text ? "txt" : "srt" }
}

public enum SpeechRecords {
    /// The speech decoder's name, which is its records' `protocol`.
    public static let protocolName = "speech"
    /// The feature whose provider and model the speech decoder calls (`ley ai use speech`).
    public static let feature = "speech"
    /// The speech decoder's pre-roll and hang when its manifest sets none (`decode.proto`,
    /// SEGMENTED; the daemon's `Segmenter.defaultPreRollMs` and `defaultHangMs`).
    public static let defaultPreRollMs: UInt64 = 500
    public static let defaultHangMs: UInt64 = 500

    // MARK: The fold

    /// The speech lines of `records` by the recording each names in `clip_uri`, so one query
    /// serves every recording on the page and the search. Records that are not speech, or name no
    /// recording part, are left out.
    public static func byRecording(_ records: [Leyline_V1_DecodeRecord]) -> [String: [SpeechLine]] {
        var out: [String: [SpeechLine]] = [:]
        for r in records {
            guard let line = SpeechLine(r) else { continue }
            out[line.recordingID, default: []].append(line)
        }
        return out
    }

    /// The query that finds some recordings' speech in one call: protocol `speech` between a
    /// minute before the first began and a minute after the last ended (now while one runs),
    /// because `RecordQuery` has no filter on `clip_uri`; `byRecording` then sorts the records
    /// to their recordings. A transcription of a stored recording is dated by the recording's
    /// anchors, so its records fall inside the recording's span. A recording nothing dates
    /// leaves the start unbounded.
    public static func query(for summaries: [RecordingSummary], now: Date)
        -> Leyline_V1_RecordQuery
    {
        .with {
            $0.protocol = protocolName
            $0.limit = queryLimit
            let starts = summaries.map(\.startedAt)
            if !starts.contains(nil), let from = starts.compactMap({ $0 }).min() {
                $0.sinceNs = Int64((from.timeIntervalSince1970 - 60) * 1e9)
            }
            let to = summaries.map { $0.endedAt ?? now }.max() ?? now
            $0.untilNs = Int64((to.timeIntervalSince1970 + 60) * 1e9)
        }
    }

    /// More records than any one recording's overs: the daemon's default of 1000 would cut a day
    /// on a busy repeater short.
    public static let queryLimit: UInt32 = 20_000

    static func inOrder(_ a: SpeechLine, _ b: SpeechLine) -> Bool {
        (a.part, a.over, a.time.sampleIndex) < (b.part, b.over, b.time.sampleIndex)
    }

    /// The wall clock of a line's first sample through the manifest's anchors: its own capture,
    /// else the part's.
    static func wallTime(of line: SpeechLine, in m: RecordingManifest) -> Date? {
        let part = m.parts.first { $0.part == line.part }
        let capture = line.time.captureID.isEmpty ? (part?.captureID ?? "") : line.time.captureID
        guard !capture.isEmpty else { return nil }
        return m.wallTime(ofSample: line.time.sampleIndex, capture: capture)
    }

    static func text(_ v: Leyline_V1_FieldValue?) -> String {
        switch v?.value {
        case .text(let s)?: s
        case .number(let n)?: n.isFinite ? String(n) : ""
        case .integer(let i)?: String(i)
        default: ""
        }
    }

    static func number(_ v: Leyline_V1_FieldValue?) -> Double? {
        switch v?.value {
        case .number(let n)?: n.isFinite ? n : nil
        case .integer(let i)?: Double(i)
        case .text(let s)?: Double(s)
        default: nil
        }
    }

    /// The `callsigns` field, comma-separated as the decoder writes it.
    static func callsigns(_ field: String) -> [String] {
        field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: One over's audio

    /// The segments of a part, by the daemon's rule (`Segmenter.cut`, and `leyline.Segments` in
    /// Go): each reaches `preRoll` back from its first opening and `hang` on from its last close,
    /// an opening less than `hang` after the previous close continues the segment, and a segment
    /// never reaches before the part's start or the previous segment's end, nor past the part's
    /// end. `first` and `last` are the openings it holds, counted from 1.
    public static func segments(
        _ opens: [SquelchInterval], partStart: UInt64, partEnd: UInt64, preRoll: UInt64,
        hang: UInt64
    ) -> [(start: UInt64, end: UInt64, first: Int, last: Int)] {
        var out: [(start: UInt64, end: UInt64, first: Int, last: Int)] = []
        var current: (start: UInt64, end: UInt64, first: Int, last: Int)?
        for (i, o) in opens.enumerated() {
            let close = max(o.closeSample, o.openSample)
            if var open = current, o.openSample < open.end {
                open.end = max(open.end, close + hang)
                open.last = i + 1
                current = open
                continue
            }
            if let done = current { out.append(done) }
            let floor = max(partStart, out.last?.end ?? partStart)
            let wanted = o.openSample > preRoll ? o.openSample - preRoll : 0
            current = (max(wanted, floor), close + hang, i + 1, i + 1)
        }
        if let done = current { out.append(done) }
        return out.compactMap { s in
            var c = s
            c.end = min(c.end, partEnd)
            return c.end > c.start ? c : nil
        }
    }

    /// The pre-roll and hang `decoder` cuts overs with, in ms: its manifest's, 0 read as the
    /// defaults, which is what the speech manifest leaves them.
    public static func timings(_ decoder: Leyline_V1_DecoderManifest?) -> (
        preRollMs: UInt64, hangMs: UInt64
    ) {
        let input = decoder?.input
        let preRoll = UInt64(input?.preRollMs ?? 0)
        let hang = UInt64(input?.hangMs ?? 0)
        return (preRoll == 0 ? defaultPreRollMs : preRoll, hang == 0 ? defaultHangMs : hang)
    }

    /// The capture samples that play over `over` of `part`: the segment that holds that opening,
    /// cut with the speech decoder's pre-roll and hang (`timings`), never the recording's own gate
    /// pre-roll, so what plays is exactly what was transcribed. Nil when the part's openings were
    /// not read, it has no such over, or nothing gives its capture rate; the caller then plays
    /// the whole part.
    public static func range(
        over: Int, of part: RecordingPart, in m: RecordingManifest,
        preRollMs: UInt64 = defaultPreRollMs, hangMs: UInt64 = defaultHangMs
    ) -> (start: UInt64, end: UInt64)? {
        guard let opens = part.squelchIntervals, over >= 1, over <= opens.count else { return nil }
        let rate = captureRate(of: part, in: m)
        guard rate > 0 else { return nil }
        let perMs = rate / 1000
        let spans = segments(
            opens, partStart: part.startSample, partEnd: part.endSample,
            preRoll: UInt64(Double(preRollMs) * perMs), hang: UInt64(Double(hangMs) * perMs))
        return spans.first { $0.first <= over && over <= $0.last }.map { ($0.start, $0.end) }
    }

    /// The rate `part`'s samples count in: its sidecar's anchor, else the manifest's anchor of its
    /// capture, else its span over its frames at the audio rate; 0 when nothing says.
    static func captureRate(of part: RecordingPart, in m: RecordingManifest) -> Double {
        if let r = part.captureRate, r > 0 { return Double(r) }
        let capture = part.captureID ?? ""
        if let a = m.anchors.last(where: {
            ($0.captureID == capture || capture.isEmpty) && $0.fromSample <= part.startSample
                && $0.sampleRate > 0
        }) {
            return Double(a.sampleRate)
        }
        guard part.samples > 0, part.endSample > part.startSample, m.sampleRate > 0 else {
            return 0
        }
        return Double(part.endSample - part.startSample) / Double(part.samples)
            * Double(m.sampleRate)
    }

    // MARK: Search

    /// The first line in `lines` whose words hold `query`, case-blind, or nil; an empty query
    /// finds nothing, because it would select a part for no reason. Lines are tried in the order
    /// given, which `hit(_:in:speech:)` makes newest recording first.
    public static func search(_ query: String, in lines: [SpeechLine]) -> SpeechLine? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return lines.first { $0.text.lowercased().contains(q) }
    }

    /// The speech line in `channel`'s recordings that `query` finds: its recordings newest first
    /// (as the channel lists them), each recording's shown lines in part and over order. nil when
    /// none holds it, or no speech of the channel has been loaded.
    public static func hit(
        _ query: String, in channel: RecordingChannel, speech: [String: RecordingSpeech]
    ) -> SpeechHit? {
        for r in channel.recordings {
            guard let s = speech[r.jobID], let line = search(query, in: s.newest) else { continue }
            return SpeechHit(line: line)
        }
        return nil
    }

    // MARK: Export

    /// The shown lines as a file: plain text, one line per over, `[14:03:20] text (W6ABC)`, the
    /// time of day through the anchors in `timeZone` (`[--:--:--]` when nothing dates it) and the
    /// callsigns only when there are some; or SRT, whose times run from the recording's first
    /// sample, through the anchors, so the gaps between parts are kept, each cue lasting as long
    /// as its over plays (cut with `preRollMs` and `hangMs`, the decoder's). A line nothing dates
    /// has no place on SRT's clock and is left out of it, counted in `skipped`. Lines end in `\n`,
    /// and an SRT cue is followed by a blank line.
    public static func export(
        _ speech: RecordingSpeech, manifest: RecordingManifest, format: SpeechExportFormat,
        timeZone: TimeZone = .current, preRollMs: UInt64 = defaultPreRollMs,
        hangMs: UInt64 = defaultHangMs
    ) -> (text: String, skipped: Int) {
        let lines = speech.newest
        switch format {
        case .text:
            return (lines.map { textLine($0, timeZone: timeZone) + "\n" }.joined(), 0)
        case .srt:
            let origin = manifest.parts.sorted { $0.part < $1.part }.first.flatMap {
                manifest.startTime(of: $0)
            }
            var out = ""
            var cue = 0
            var skipped = 0
            for l in lines {
                guard
                    let span = cueSeconds(
                        l, manifest: manifest, origin: origin, preRollMs: preRollMs, hangMs: hangMs)
                else {
                    skipped += 1
                    continue
                }
                cue += 1
                out += "\(cue)\n\(srtTime(span.0)) --> \(srtTime(span.1))\n\(l.text)\n\n"
            }
            return (out, skipped)
        }
    }

    /// `[14:03:20] text (W6ABC, K6XYZ)`.
    static func textLine(_ l: SpeechLine, timeZone: TimeZone) -> String {
        let when = l.wallTime.map { Recordings.clock($0, "HH:mm:ss", timeZone) } ?? "--:--:--"
        var line = "[\(when)] \(l.text)"
        if !l.callsigns.isEmpty { line += " (\(l.callsigns.joined(separator: ", ")))" }
        return line
    }

    /// A cue's start and end in seconds from `origin`: the line's wall time, and the end of its
    /// over's segment, else three seconds on. Nil when nothing dates the line or the recording.
    static func cueSeconds(
        _ l: SpeechLine, manifest m: RecordingManifest, origin: Date?, preRollMs: UInt64,
        hangMs: UInt64
    ) -> (Double, Double)? {
        guard let origin, let at = l.wallTime else { return nil }
        let from = max(0, at.timeIntervalSince(origin))
        var to = from + cueFallbackSeconds
        if let part = m.parts.first(where: { $0.part == l.part }),
            let r = range(over: l.over, of: part, in: m, preRollMs: preRollMs, hangMs: hangMs),
            let end = part.captureID.flatMap({ m.wallTime(ofSample: r.end, capture: $0) })
        {
            to = max(from, end.timeIntervalSince(origin))
        }
        return (from, to)
    }

    static let cueFallbackSeconds = 3.0

    /// `01:02:03,450`: SRT's hours, minutes, seconds and milliseconds.
    static func srtTime(_ seconds: Double) -> String {
        let ms = Int64((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        return String(
            format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, ms / 60_000 % 60,
            ms / 1000 % 60, ms % 1000)
    }

    // MARK: Transcribing

    /// The job that transcribes a recording: the speech decoder over its stored parts, kept, so
    /// its records are `ley://records/<job_id>` and stay beside any earlier transcription's. The
    /// model is the speech feature's (`AppSession` sets it first when one is chosen), because the
    /// model reaches the plugin when it starts.
    public static func transcribeConfig(recordingURI: String, decoder: String = protocolName)
        -> Leyline_V1_DecodeConfig
    {
        .with {
            $0.decoder = decoder
            $0.sourceUri = recordingURI
            $0.keep = true
        }
    }

    /// Whether Transcribe is offered: a speech decoder is installed and either needs no key or a
    /// key is set (`AISettings.hasAnyAI`). With no key the Library shows no speech control at all.
    public static func canTranscribe(decoder: Leyline_V1_DecoderManifest?, ai: Leyline_V1_AIState)
        -> Bool
    {
        guard let d = decoder, d.input.mode == .segmented else { return false }
        return d.credentialProvider.isEmpty || AISettings.hasAnyAI(ai)
    }

    /// The speech feature's model now (empty when none is chosen), and the models "Transcribe
    /// again" offers: that one first, then each model the providers serving speech list, once.
    public static func models(
        _ ai: Leyline_V1_AIState, providers: [AIProvider] = ProviderCatalog.all
    ) -> (current: String, offered: [String]) {
        let current = ai.features.first { $0.feature == feature }?.model ?? ""
        var offered: [String] = current.isEmpty ? [] : [current]
        for p in providers where p.features.contains(feature) {
            for m in p.models where !offered.contains(m) { offered.append(m) }
        }
        return (current, offered)
    }

    /// The question asked before transcribing, as `ley transcribe` states it: `Transcribe 2
    /// parts, 0.1 min of squelch-open audio from 146.520 MHz NFM, with speech (sends the audio to
    /// api.example.com)?`. The minutes are the parts' `squelch_open_ms`, else their openings
    /// summed at the capture rate; `model`, when one is chosen, is named and said to stay.
    public static func question(
        manifest m: RecordingManifest, decoder: Leyline_V1_DecoderManifest, model: String = ""
    ) -> String {
        var with = decoder.name
        if !model.isEmpty { with += ", model \(model)" }
        let hosts = decoder.contactsHosts
        let destination =
            hosts.isEmpty
            ? "on this Mac; no audio leaves it"
            : "sends the audio to " + hosts.joined(separator: ", ")
        let minutes = Double(squelchOpenMs(m)) / 60_000
        var words =
            "Transcribe \(RecordingSummary.partsWords(m.parts.count)), "
            + String(format: "%.1f", minutes)
            + " min of squelch-open audio from \(frequencyWords(m.frequencyHz)) \(m.mode), with \(with) (\(destination))"
        if !model.isEmpty {
            words += "; the speech model is set to \(model) for this and later jobs"
        }
        return words + "?"
    }

    /// How long the squelch was open across the recording, in ms: each part's
    /// `squelch_open_ms`, else its openings summed at its capture rate.
    public static func squelchOpenMs(_ m: RecordingManifest) -> Int64 {
        m.parts.reduce(Int64(0)) { sum, p in
            if let ms = p.squelchOpenMs { return sum + max(0, ms) }
            let rate = captureRate(of: p, in: m)
            guard rate > 0, let opens = p.squelchIntervals else { return sum }
            let samples = opens.reduce(UInt64(0)) {
                $0 + ($1.closeSample > $1.openSample ? $1.closeSample - $1.openSample : 0)
            }
            return sum + Int64((Double(samples) / rate * 1000).rounded())
        }
    }

    /// `146.520 MHz`, `462.5625 MHz`: `ley`'s `units.FormatFrequency` for the frequencies a
    /// recording is made on.
    static func frequencyWords(_ hz: UInt64) -> String {
        let f = Double(hz)
        if f >= 999_999_500 { return String(format: "%.3f GHz", f / 1e9) }
        if f >= 999_999.5 {
            return String(format: hz % 1000 == 500 ? "%.4f MHz" : "%.3f MHz", f / 1e6)
        }
        if f >= 999.9995 { return String(format: "%.3f kHz", f / 1e3) }
        return "\(hz) Hz"
    }

    /// The newest transcription job of `recordingURI` in `jobs`, running or not, or nil.
    public static func transcription(of recordingURI: String, in jobs: [Leyline_V1_Job])
        -> Leyline_V1_Job?
    {
        jobs.filter { j in
            if case .decode(let d)? = j.config { return d.sourceUri == recordingURI }
            return false
        }.max { $0.jobID < $1.jobID }
    }

    /// The line beside a recording's speech while a transcription runs or after it failed, as a
    /// record job's line is: `Transcribing · 3 overs so far`; the daemon's `status_detail` while
    /// it is degraded (a provider's rate limit, drawn in `caution`); `Could not transcribe: …`
    /// once it failed. nil once it completed or was cancelled, when the words speak for
    /// themselves.
    public static func statusLine(job: Leyline_V1_Job, speech: RecordingSpeech?) -> String? {
        switch job.state {
        case .running:
            let n = speech?.all.filter { $0.jobID == job.jobID }.count ?? 0
            return n == 0
                ? "Transcribing" : "Transcribing · \(n == 1 ? "1 over" : "\(n) overs") so far"
        case .degraded:
            return job.statusDetail.isEmpty ? "Transcribing, held up" : job.statusDetail
        case .failed:
            let why = job.error.message.isEmpty ? job.statusDetail : job.error.message
            return "Could not transcribe: \(why.isEmpty ? job.error.code : why)"
        default:
            return nil
        }
    }
}
