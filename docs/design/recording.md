# Design: Recording

Status: implemented. Companion to `data-planes.md` for lossless daemon-side output,
`semantic-tier.md` for persistence and `decoders.md` for the kept-records store pattern.

## The story

> As an operator, I can `ley record --iq` and `--audio` to files with sensible metadata (freq,
> rate, mode, timestamp), and play IQ files back through the same demod path. (V0)

> As an operator, I can start/stop audio and IQ recording from the UI and find recordings in
> Finder. (V1a)

> As an agent user, an agent can retrieve a recording as a resource and hand it to another
> tool. (V1b)

Three consumers, one feature. The playback half exists (`ley play`); this doc is the recording
half, the `Resources` service that makes `ley://recordings/<id>` real, and the two features users
are most likely to want next: recording only while something is on the air, and long recordings in
parts.

## What a recording is

**A recording is a job's output.** `Jobs.StartJob(RecordConfig)` is the one way to make one.
`Control.AttachSink(file)` stays refused with `UNIMPLEMENTED`, and its proto comment says why: a
sink attached to someone's channel dies with that channel's owner and leaves a file nothing
indexes, while a job goes through the allocator (invariant 9), outlives the client that started
it, and produces a resource (invariant 8). The job's id is the recording's id, exactly as a kept
decode job's id names `ley://records/<job_id>`: one job, one recording, `Job.result_uris` holds
`ley://recordings/<job_id>`.

**A recording is a sequence of parts, each a file with its own sidecar.** A part is the unit
`ley play` already understands: samples plus a JSON sidecar giving format, rate, centre and the
anchor. A continuous recording is one part. A gated recording has one part per exchange: the squelch stays open through the pauses between overs, and every squelch opening
inside the part is listed, so the overs are countable and an exchange plays back whole. A long
recording is cut into parts on a timer. The rules compose: a transmission longer than the
part length is two parts, contiguous on the sample timebase.

**A gated recording is a transcript with audio attached.** Each part of a gated recording is an
`ActivitySegment` (`jobs.proto`): start and end on the sample timebase, peak and mean level, and a
`clip_uri` naming the part. The manifest lists them in order with the coverage gaps between them.
This is the shape the semantic-tier doc gives a watch job's transcript, so when the durable job store builds the
watch job its `record_clips` is this sink and this manifest, not a second format.

**Time is never edited.** Silence is not removed from a file; the file is not written while the
squelch is closed, and each part records where on the capture's timeline it starts. A recording
that is played back therefore keeps the original timing, with the gaps between parts stated in the
manifest rather than hidden inside one file (invariant 5).

## Files

The store is a plain directory Finder can open and Spotlight can index, beside the kept-records
store: `~/Library/Application Support/Leyline/recordings` on macOS, `$XDG_DATA_HOME/leyline/
recordings` elsewhere, `leylined --recordings PATH` to move it. One directory per recording, named
by the job id; the files inside carry the description a person searches for.

```
recordings/
└── job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB/
    ├── recording.json                                  the manifest (below)
    ├── 2026-09-17_14-03-22_146.520MHz_NFM_001.wav      part 1
    ├── 2026-09-17_14-03-22_146.520MHz_NFM_001.json     part 1 sidecar
    ├── 2026-09-17_14-03-41_146.520MHz_NFM_002.wav
    └── 2026-09-17_14-03-41_146.520MHz_NFM_002.json
```

The time in a part's name is the wall clock of its first sample, derived from the anchor, in the
local zone; the frequency and mode are the channel's. An IQ part is `<same>_IQ_001.cf32`.

### Formats

- **Audio is WAV, PCM S16 mono, at the channel's audio rate** (48 kHz on a 2.4 MSPS capture).
  WAV because Finder previews it, QuickTime plays it and every audio tool reads it, and S16
  because that is what `ley listen --format bin` already hands a script. 96 KB/s, 5.8 MB a
  minute, 346 MB an hour at 48 kHz (computed from the format, not measured).
- **IQ is `.cf32` with the sidecar `docs/reference/iq-files.md` defines**, at the capture's rate.
  It is the one format every reader in the repository already handles, and `FilePlaybackDevice`
  plays it back without converting. It is also large: 19.2 MB/s at 2.4 MSPS, 1.15 GB a minute,
  69 GB an hour (computed). A smaller IQ format is deliberately not in v1 (below); the size is why
  IQ recordings are cut into parts by default and why the store has a cap.

### The part sidecar

The `iqfile` sidecar with one added block. `ley play` reads the keys it needs and ignores the
rest, so a part plays with no change to the reader.

```json
{
  "format": "wav-s16",
  "sample_rate": 48000,
  "center_hz": 146520000,
  "samples": 912000,
  "created_at_ns": 1789653802000000000,
  "anchor": { "capture_id": "cap_01J…", "host_time_ns": 1789653700000000000, "sample_rate": 2400000, "drift_ppm": 0 },
  "metadata": { "mode": "NFM", "frequency_hz": "146520000", "kind": "audio" },
  "recording": {
    "job_id": "job_01J…", "part": 1, "kind": "audio",
    "start_sample": 244800000, "end_sample": 290400000,
    "bandwidth_hz": 12500, "squelch_dbfs": -80,
    "peak_dbfs": -6.2, "mean_dbfs": -18.4, "clipped_ms": 400,
    "squelch_opens": [ { "open_sample": 246000000, "close_sample": 262800000 },
                       { "open_sample": 268800000, "close_sample": 278400000 } ]
  }
}
```

`format` is `wav-s16` for audio and `cf32` for IQ. `sample_rate` is the file's own rate, the
audio rate for a WAV part and the capture rate for IQ. `anchor` is the capture's anchor as
`RecordStore` already stores one, with the capture it dates; `start_sample` and `end_sample`
are on that capture's timeline at the capture rate, so a client places any part on the same
timeline as the telemetry and the decode records from that capture. `center_hz` on an audio part
is the channel's frequency, on an IQ part the capture's centre. `squelch_opens` is every
open-and-close of the squelch inside the part, on the same timeline; a continuous recording
with no gate has none.

`clipped_ms` is how long inside the part the radio clipped (shown in the app's
Library inspector). It comes from the capture's `CaptureLevel` readings, the same count the window's
clipping marks and `ley tune`'s warning use:
a reading is a quarter second of capture samples, it counts when at least 1e-4 of its samples
were at a converter rail, and the part is charged the stretch of each counting reading that lies
inside `start_sample` … `end_sample`. The key is absent when nothing clipped, and on a part a
restart repaired, because nobody measured it. The runner reads the level off the meter
`TelemetryService` publishes from (`CaptureLevelMeter`, a seqlock of four words, polled at the
telemetry service's 100 ms), so recording adds no second reader on the DSP ring (invariant 4). A
reading still being measured when a part closes is not counted, so a part can come up to a quarter
second short at its end. `RecordingTests` charges a part from a synthetic level feed, and
`RecordingJobTests` records a file whose every sample is at +1 and reads back more than 1000 ms of
a 1500 ms part.

`peak_dbfs` does not report clipping. It is measured on the audio the channel produced, and an NFM
discriminator's output reads near full scale on a clean strong carrier as readily as on an
overloaded one; a part whose IQ hit the rails reports 0.0 dBFS only by coincidence. A client
prints `0.0 dBFS · clipped` from `clipped_ms > 0`, never from the peak.

### The manifest

`recording.json` is the resource: what `GetResource` returns as `Resource.metadata` plus the
parts, and what `ley recordings show` prints.

```json
{
  "job_id": "job_01J…",
  "uri": "ley://recordings/job_01J…",
  "kind": "audio",
  "frequency_hz": 146520000,
  "mode": "NFM",
  "bandwidth_hz": 12500,
  "sample_rate": 48000,
  "format": "wav-s16",
  "device": { "driver": "rtlsdr", "model": "Nooelec NESDR SMArt", "serial": "00000001" },
  "gains": [ { "element": "tuner", "value_db": 29.7 } ],
  "squelch_dbfs": -80,
  "gate": { "kind": "squelch", "pre_roll_ms": 500, "hang_ms": 5000 },
  "part_ms": 0,
  "started_at_ns": 1789653802000000000,
  "ended_at_ns": 1789653862000000000,
  "ended_by": "duration",
  "created_by": { "client_id": "cli_01J…", "kind": "cli", "label": "ley record" },
  "anchors": [ { "capture_id": "cap_01J…", "host_time_ns": 1789653700000000000, "sample_rate": 2400000, "drift_ppm": 0, "from_sample": 0 } ],
  "parts": [
    { "part": 1, "file": "2026-09-17_14-03-22_146.520MHz_NFM_001.wav", "start_sample": 244800000, "end_sample": 290400000, "samples": 912000, "bytes": 1824044, "peak_dbfs": -6.2, "mean_dbfs": -18.4, "squelch_opens": 2, "clipped_ms": 400 }
  ],
  "coverage_gaps": [ { "from_sample": 300000000, "to_sample": 312000000, "reason": "out of capture" } ],
  "bytes": 1824044
}
```

`ended_by` is one of `duration`, `quiet`, `cancelled`, `channel ended`, `restart`, `store full`,
`error`. `anchors` is a list for the same reason the kept-records sidecar's is: a recording that
spans a device detach and reattach spans two captures, and each part's samples are dated by the
anchor of its own capture.

### Nothing heard

A record job that ends with no part written is discarded: a gated recording switched on and off while the squelch never opened, or a
continuous one that ended before any audio reached it. It has nothing to play, and listing it put
`0 parts · 0 s · 0 B` in every client. When the job ends (cancelled, duration, quiet, the channel
closing, a restart) the runner removes the directory through `RecordingStore.delete` before the
job's terminal state goes out, so a client that sees the job end never lists it, and the job ends
`COMPLETED` with `status_detail` `nothing was heard`. A job that failed keeps `FAILED` and its
reason, and its empty directory goes the same way. The job still names
`ley://recordings/<job_id>` in `result_uris`, because clients read the URI from there while the
job runs; after the discard it resolves to `JOB_NOT_FOUND`, like a recording deleted in Finder.
`ley record` prints `Recorded nothing: the squelch never opened.` and exits 0 with nothing on
stdout, and the MCP `record` tool returns the job with the same sentence.

### Retention

`leylined --recordings-cap BYTES` (default 20 GiB) and `--recordings-age DAYS` (default 0, never).
The defaults are a guess to be tuned by use; the cap is set so a full IQ recording at 2.4 MSPS
fits about 18 minutes and audio about 62 hours. Retention runs when a job ends and at daemon
start, age first then oldest-first by manifest time until under the cap, and it never removes a
recording whose job is running. A recording a person deletes in Finder is gone: the index
is a scan of the manifests, as the kept-records index is a scan of its sidecars, so nothing else
needs updating. A job that cannot write because the disk is full ends `FAILED` with what it
managed to keep, and the detail states the free space and the flag.

## The wire

Additive only. Field numbers continue from what `jobs.proto` has.

```proto
message RecordConfig {
  uint64 frequency_hz = 1;
  DemodMode mode = 2;         // RAW_IQ records the capture's IQ; anything else records audio
  int64 start_at_ns = 3;      // 0 = now; a later start is refused UNIMPLEMENTED in v1
  int64 duration_ms = 4;      // 0 = until cancelled or stop_after_quiet_ms

  // Record what an existing channel hears, with its mode, bandwidth and squelch. frequency_hz
  // and mode are ignored. The job borrows the channel and does not own it: when the channel's
  // owner destroys it the job ends COMPLETED, "channel ended". With RAW_IQ the channel's capture
  // is recorded.
  string channel_id = 5;
  string device_id = 6;       // empty = the daemon picks, as a scan or decode does
  bool take_over = 7;         // retune a capture somebody is using; off by default
  uint32 bandwidth_hz = 8;    // 0 = the mode's default, as CreateChannel
  double squelch_dbfs = 9;    // NaN or unset = the channel default (auto), as ley tune
  GainWrite gain = 10;        // absent = leave the radio's gain alone

  RecordGate gate = 11;       // NONE (default) or SQUELCH
  uint32 pre_roll_ms = 12;    // audio kept from before the squelch opened; default 500
  uint32 hang_ms = 13;        // how long after the squelch closes a part stays open; default 5000
  int64 stop_after_quiet_ms = 14; // end the job after this long with the squelch closed; 0 = never
  int64 part_ms = 15;         // cut parts on this timer; 0 = audio: one part, IQ: 60000
  repeated GainWrite gains = 16; // in order; wins over gain when set
}

enum RecordGate { RECORD_GATE_UNSPECIFIED = 0; NONE = 1; SQUELCH = 2; }
```

Rules the daemon enforces, each with its code:

- `gate = SQUELCH` with `mode = RAW_IQ` is `INVALID_ARGUMENT`: a gate needs a channel's squelch,
  and an IQ recording has no channel. Record audio, or record IQ continuously.
- `stop_after_quiet_ms` without a gate is `INVALID_ARGUMENT`, since nothing is watching the
  squelch.
- `channel_id` naming a channel that is not there is `CHANNEL_NOT_FOUND`; a channel whose
  squelch is off (NaN) with `gate = SQUELCH` is `FAILED_PRECONDITION`, "squelch is off on
  chan_…; set one with ley set squelch".
- `start_at_ns != 0` is `UNIMPLEMENTED` (a scheduled recording needs the durable job store).
- Allocation failures are the allocator's: `NO_DEVICE`, `BLIND_SPOT`, and a declined
  don't-disturb with the reason, exactly as a decode job.

No new error code in v1. A full disk ends the job `FAILED` with `FAILED_PRECONDITION` and a
message naming the free space; a code a client can branch on is added when a client needs it.

**`Resources`**, all four RPCs, implemented over the manifests:

- `ListResources(kind, metadata_filter)` returns one `Resource` per manifest, newest first, with
  `kind = RECORDING`, `size_bytes` the sum of the parts, `originating_job_id` the job, and a
  `metadata` map with these keys, frozen because `metadata_filter` matches on them by exact
  string: `kind` (`audio`|`iq`), `frequency_hz`, `mode`, `bandwidth_hz` (the channel's width,
  `0` for IQ; the app's sidebar tunes the width recorded), `sample_rate`,
  `format`, `duration_ms` (the sum of the parts' durations), `parts`, `started_at_ns`,
  `ended_at_ns`, `ended_by`, `device`. `RECORDS` and `SCAN` are answered too, from the stores that exist, so the
  service covers every kind that has a store; `SNAPSHOT` and `TRANSCRIPT` return nothing until
  their milestones.
- `GetResource(uri)` returns the same `Resource`; `RESOURCE_NOT_FOUND` is not added, the
  existing `JOB_NOT_FOUND` reports the missing recording, since the id is the job's.
- `ResolveLocalPath(uri)` returns the recording's directory for `ley://recordings/<id>` and the
  part's samples file for `ley://recordings/<id>/<part>`. Clients on the same machine open the
  file; nothing is streamed.
- `DeleteResource(uri)` removes a recording's directory, every part, sidecar and the manifest,
  and returns `DeletedResource` with `freed_bytes`, what the directory held. It refuses while the recording's job is
  `RUNNING` or `DEGRADED`, `FAILED_PRECONDITION` with "cancel the job first", because the runner
  has a part open there and cancelling finalises it. A part's URI is `INVALID_ARGUMENT`, since a
  recording is deleted whole, and a missing one is `JOB_NOT_FOUND`. A playback of one of its parts
  is stopped first, through the path `StopPlayback` takes, so its tombstone (caused by the
  deleting client) goes out before the files go. Otherwise nothing goes out on the
  event plane: a recording is a resource, the job's entry is left as it was, and a client re-reads
  `ListResources`. Deleting the directory in Finder does the same, except that a playback
  already reading a part keeps its open file and plays to the end.

**Job events** already exist (`Event.job`), so a client renders a recording's progress by
subscription. While `RUNNING`, `status_detail` carries liveness the way a decode job's does, on
the same two-second cadence: "recording audio: 1 m 12 s, 3 parts, 6.9 MB", or for a gated
recording that is waiting, "recording audio: 4 m 02 s, 3 parts, squelch closed 38 s". The
recording's capture retuned away is `DEGRADED` with "out of capture since 14:05:10, will resume
when 146.520 MHz is back"; `CancelJob` finalises the files and ends `CANCELLED`, and that is the
normal way an open-ended recording stops, so a cancelled recording is complete, not damaged.

## The daemon

Nothing here runs on the DSP thread except the sink the bulk audio path already uses.

**A `RecordRunner` actor per job**, beside `DecodeRunner` and built the same way. The channel
form is the primitive: the runner borrows a channel, registers the job as a dependant so the
channel's teardown ends the job rather than orphaning a sink, and records the channel's output. The
frequency form is that with a different owner: the allocator makes a persistent, job-owned
channel (a `ChannelLease`, as a decode job gets), the runner records it exactly as a borrowed
one, and the lease is released when the job ends. There is one runner, one drain and one gate
machine, never two paths. IQ is the one asymmetry, because its primitive is a capture: the
channel form records the named channel's capture, and the frequency form takes a
`CaptureIQLease` the way an IQ decoder does. Audio arrives through an
`AudioFrameSource` (the `CallbackSink` into a `FloatRing` that bulk audio streams use, hot path
unchanged); IQ arrives through a `CaptureTap` writing into a slot ring the same way
`IQDecodeRunner`'s does. A drain task off the DSP thread pops the ring and hands blocks to a
`PartWriter`.

**`PartWriter` owns one open file at a time.** It writes the WAV header with placeholder lengths
and patches them on close, or appends cf32; it writes the part sidecar on close; it appends the
part to the manifest and rewrites the manifest atomically. It closes a part when the part timer
elapses, when the gate closes (below), when the capture's centre or rate changes under an IQ
recording (the next part carries the new centre, and a gap is recorded), and when the job ends.
Peak and mean dBFS are accumulated per part from the samples as they pass, off the hot path.

**The gate reads the squelch's own transitions, not the audio.** The `.audio` tap is zeros while
the squelch is closed, but that is an implementation fact, not a contract, and the squelch
transition record carries the exact sample the state changed at. The runner subscribes to the
channel's squelch transitions through the same in-process path `TelemetryService` uses (never a
second reader on the channel's DSP-side ring), and drives a small state machine:

- **seeded**: a squelch that is already open when the recording starts sends no transition,
  since a broadcast carrier holds it open for as long as it is on the air. The first meter the
  runner sees (`Meter.squelch_open`, every 100 ms) seeds the machine: open, and a part opens at
  once with `start_sample` at the recording's first frame and no pre-roll, because there is no
  audio from before the recording began. The same happens after a coverage gap, when the channel
  comes back into a squelch that is already open. After that, a meter that disagrees with the
  machine is applied as the transition it missed (one sent before the runner subscribed, or lost
  to the fan-out buffer), at the meter's sample. Cancel closes the seeded part with what it
  holds; without that, gated recordings of an FM station were 0 s and 0 B.
  `RecordingJobTests` holds a gated recording of `nfm_tone` cancelled after 2 s to one part of
  about 2 s, in both the frequency form and the channel form.
- **closed**: audio goes into a pre-roll ring of `pre_roll_ms` at the audio rate (24000 floats,
  96 KB, at 48 kHz and 500 ms; allocated when the runner starts, never on the hot path). No file
  is open.
- **open**: on a squelch-open transition, a part opens, the pre-roll ring is written first, then
  live audio. The part's `start_sample` is the transition's sample minus the pre-roll, on the
  capture timebase.
- **hanging**: on a squelch-close transition the part stays open for `hang_ms`. A re-open inside
  the hang continues the same part (one exchange, several overs), and each open-and-close pair
  is appended to the part's `squelch_opens`. When the hang elapses the part closes with
  `end_sample` at the close transition plus the hang, and the state is closed again.
- **quiet**: when `stop_after_quiet_ms` is set and the squelch has been closed that long, the
  job ends `COMPLETED`, `ended_by = quiet`.

Audio frames are dated by their block's capture time plus the ring backlog, so a cut lands
within one capture block of the transition: 16384 samples, 6.8 ms at 2.4 MSPS (computed). That
is the accuracy claim, and the fixture test below holds the daemon to it.

**Retune, detach and restart.** A record job's channel carries `required_hz` and is the first
consumer of it. If the human retunes the capture away, the channel goes `OUT_OF_CAPTURE`, the
runner closes the open part, records a coverage gap, marks the job `DEGRADED`, and resumes with
a new part when the capture comes back to cover it. It does not hunt for another device; that
rebinding belongs to the durable job store, and the control-plane doc's "the human is never blocked by a job" is
honoured by degrading, not refusing. A device detach is the same story through the capture's
`detached` state. A daemon restart does not resume a recording: the next daemon finds the job in
`kept-jobs.json`, repairs the last part's WAV header from the file length, closes the manifest
with `ended_by = restart`, and marks the job `COMPLETED` with "ended by a daemon restart". A
recording is a bounded artefact; whoever wanted a longer one starts another. The reserved
`WatchConfig` contract covers open-ended capture, but no watch runner is implemented.

**Don't-disturb.** A record job that created its capture holds it as a scan does, so the
allocator's `inUse` refuses another job the radio without `take_over`. An interactive client is
never refused by the daemon, keeping the control-plane rule that a job never
blocks a person: the retune-away path above is what happens instead, and the check is in the
client that retunes. `ley set` and `ley tune` warn when the capture they would move has a running
recording and need `--retune` to proceed, the same flag that already guards a capture other
channels ride on; the app confirms before retuning such a capture, since it renders job state
anyway. The MCP adapter's `tune` already lists the listening channels it would disturb; it
lists running recordings the same way.

**Signposts.** The sink and ring writes are already covered (`audioWrite`, `frameRingWrite`).
The drain adds none: it is not on the sample path.

## The CLI

```
ley record <frequency|preset|channel> [--iq] [--for 5m] [--gate squelch] [--pre 500ms]
           [--hang 5s] [--stop-after-quiet 10m] [--part 60s] [--detach]
           [--mode M] [--bw N] [--squelch L|auto|off] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--take-over]
ley recordings [--kind audio|iq] [--freq F] [--since 24h] [--limit N]
ley recordings show <id>
ley recordings path <id> [--part N]
ley recordings delete <id> [--yes]
ley play ley://recordings/<id> [--part N]
ley jobs cancel <id>
```

- **The app's record button is the channel form**: it records the channel
  being listened to and ends when that channel closes. The frequency form is for scripts and
  agents, and `ley` has both.
- **`ley record` runs in the foreground by default.** It prints a banner stating the decisions
  the daemon made (`recording NFM 146.520 MHz, audio 48 kHz WAV, gate squelch (pre 500 ms, hang
  5 s), until cancelled`, then the directory), then one live line on stderr (elapsed, parts,
  bytes, and for a gated recording whether the squelch is open) until `--for` elapses or Ctrl-C,
  which cancels the job and prints the resource URI. `--detach` starts the job and exits with the
  job id and URI, for a script; `ley jobs cancel` stops it.
- **The channel form records the channel you are listening to.** `ley record chan_01J…` names a
  channel `ley state` lists (the selector `ley scope` takes), so the recording has the mode,
  bandwidth and squelch you are listening with, and ends when your `ley tune` does. With `--iq` it
  records that channel's capture.
- **`--gate squelch` is the only gate**, and `--pre`, `--hang` and `--stop-after-quiet` need it;
  without it they are a usage error naming the flag. `--iq --gate` is refused with the daemon's
  error message.
- **`--json`** prints the `Job` as each state change arrives, one object per line, as
  `ley decode --json` does; `ley recordings --json` prints `ListResourcesResponse`;
  `ley recordings show --json` prints the manifest; `ley recordings path` prints the path alone
  on stdout with or without `--json`, so `open -R "$(ley recordings path job_…)"` reveals the
  recording in Finder.
- **A retune over a recording is warned, not refused.** `ley set freq` and `ley tune` on a
  capture with a running recording print the recording's id and `ley jobs cancel`, and go ahead
  only with `--retune`. The daemon itself degrades the job and records the gap ("The daemon").
- **`ley play` takes a URI.** `ley play ley://recordings/<id>` plays part 1 and, when there are
  more, prints a note pointing to `--part`. Playing a part is playing a file; the reader is
  unchanged. The sidecar's `metadata.mode` seeds the channel as it does for a fixture.

## MCP

Four tools and one resource, each with the `ley` mirror above and the same proto3 JSON.

| Tool | Maps to | Notes |
|---|---|---|
| `record` | `Jobs.StartJob(RecordConfig)` | `duration_s` is required (1 to 3600): what an agent starts must end without it. `gate`, `pre_roll_ms`, `hang_ms`, `take_over` as the config. Returns the `Job` and the URI, and refuses an active capture the way `tune` does |
| `find_recordings` | `Resources.ListResources(RECORDING)` | the filters are the frozen metadata keys; the summary is the `ley recordings` table |
| `get_recording` | `Resources.GetResource` + `ResolveLocalPath` | the manifest with each part's local path, so an agent hands a file to another tool by path |
| `delete_recording` | `Resources.DeleteResource` | returns the `DeletedResource`; refused while the job runs, with `cancel_job` named |

The resource `ley://recordings/<id>` returns the manifest as JSON. MCP returns local paths rather
than sample data. The `record-squelch-opens` eval scenario verifies a recording task.

## Testing without hardware

**One new fixture, `nfm_keyed`**, generated by `leyfix`: three NFM transmissions of a 1 kHz tone
at −20 dBFS over the −60 dBFS floor, keyed for 1.0 s, 0.5 s and 2.0 s with 3.0 s of floor between
and 1.0 s before the first, 10.5 s long. Its sidecar gains `expect.record`:

```json
"record": { "gate": "squelch", "squelch_dbfs": -40, "segments": [
  { "start_s": 1.0, "end_s": 2.0 }, { "start_s": 5.0, "end_s": 5.5 }, { "start_s": 8.5, "end_s": 10.5 } ] }
```

`leyfix check` verifies the keying by energy in the reference chain, as it does the other
expectations.

**Engine tests** (`RecordingTests`, in the fixture-gated suite where they read a fixture):

- `PartWriter` writes a WAV whose header agrees with its length and a cf32 whose byte count is
  the sample count, and repairs a header left with placeholders.
- The gate state machine, driven with synthetic transitions and no DSP: pre-roll included,
  re-open inside the hang continues the part, hang elapsed closes it, quiet ends the job.
- A continuous recording of `nfm_tone` for 1 s yields one WAV of 48000 frames within one block,
  and that WAV carries the fixture's own audio expectation: measured 2026-09-18 at 1001.95 Hz and
  77 dB, against the sidecar's 1 kHz and 30 dB. A recorder that wrote well-formed silence would
  pass every structural test and fail this one.
- A gated recording of `nfm_keyed` at −40 dBFS with a 1 s hang yields three parts whose
  `start_sample` and `end_sample`, less the pre-roll and hang, land within one capture block of
  the sidecar's segments. The same recording at the default hang yields one part, since the
  fixture's 3 s gaps are inside 5 s, with three `squelch_opens` at the same samples. Both are
  asserted: the first pins the cut accuracy, the second pins that an exchange keeps its overs.
- A continuous IQ recording yields parts whose `start_sample`s are contiguous and no coverage
  gaps, and a spectrum of `scan_band`'s recorded part 1 still holds its four carriers in the order
  the fixture declares them: measured 2026-09-18 at 70.6, 63.8, 60.1 and 27.4 dB over a -96.7 dB
  floor for the -20, -28, -36 and -44 dBFS signals (the last is the WFM one, whose energy is
  spread over 75 kHz of deviation rather than concentrated in a bin).
- Retention: a store over its cap drops the oldest finished recording and never the running one.
- Restart: a manifest left open is closed with `ended_by = restart` at the next boot.

**The fake** (`go/internal/fakedaemon`) runs record jobs for real, writing a synthetic tone into
the temp directory the test gives it, so `ley record`, `ley recordings`, `ley recordings path`
and `ley play` on a URI are tested end to end against the fake before the real daemon, and the
fake's gate opens and closes on a schedule a test sets. `Resources` is mirrored over the same
manifests.

**End to end** (`go/internal/e2e/record_test.go`): the real daemon plays `nfm_keyed` on a file
device; `ley record --gate squelch --hang 1s --for 12s` on it; `ley recordings show --json` has three
parts; `ley play ley://recordings/<id> --part 3` and `ley levels` shows the tone. And one MCP
scenario in `evals/scenarios/`: "record ten seconds of radio-a and tell me how many times the
squelch opened", graded on the answer's count being 3 (from `squelch_opens`, at the default
hang, where the parts count is 1), `used_tool: record`, and `no_shell`.

## Playing a recording back

`ley play <file.cf32>` attaches raw samples as a file-backed radio and tunes them, which works for
IQ but not for audio: a WAV holds what a demodulator already produced, and there is no signal left
in it for a channel to decode. Attaching one as a radio would put a fake capture and mode into
`ley state`, and every other view would then show a signal that does not exist.

**The daemon plays it.** Handing the file to the client's own
player (`open`, `$LEYLINE_PLAYER`) works on one machine and is wrong in three ways: audio
comes out of the client rather than the radio's host, where `ley tune`'s does; the path is the
daemon's, so a remote client is pointed at a file that is not there; and `open` returns the moment
the player launches, so `ley play` cannot hold the terminal or stop what it started. Playback in
the daemon, which owns the audio output, fixes all three.

**A playback is daemon state, not a job and not a sink.** Not a job: a job is a persistent intent
whose output is a resource (invariant 8), and playing something back produces nothing and is over
when the person stops listening. Not a sink: a sink is where *a channel's* audio goes, and a
playback has no channel. It is its own small object, so a second client sees it, `ley state` lists
it, and the app can render a position and a stop button (invariant 7).

```proto
message Playback {
  string playback_id = 1;       // pb_<ulid>
  string resource_uri = 2;      // ley://recordings/<id>/<part>
  string path = 3;              // the file the daemon opened, for a client on the same machine
  uint32 sample_rate = 4;
  uint64 samples = 5;           // frames in the file, 0 when it could not be counted
  uint64 position = 6;          // frames played, published four times a second while playing
  double volume = 7;
  ClientInfo created_by = 8;
  PlaybackState state = 9;      // PLAYBACK_PLAYING; unset on the final event is the tombstone
  bool paused = 10;             // position held (SetPlaybackPaused)
}
```

`Control.StartPlayback`, `Control.StopPlayback` and `Control.SetPlaybackPaused`,
`Event.playback` and `GetStateResponse.playbacks` on the pattern every other object already
follows: full state, never a delta, and a tombstone with `state` unset when it ends, so a client watching its own playback can
tell "it finished" from "somebody stopped it". While it plays the daemon publishes the whole
playback four times a second with `position` current (`SessionStore.playbackInterval`), so `ley play` and the app render elapsed time from the event plane and neither polls
`GetState`. A playback counts against the 256 events the daemon retains for `since_seq` replay
like any other event: at four a second it fills them in about a minute, and a client resuming
from an older seq re-reads `GetState` by the seq-gap rule.

**A playback can be paused.**
`Control.SetPlaybackPaused(playback_id, paused)` holds the position: the reader stops pushing
blocks, the sink's ring runs dry and the device plays silence, and `position` stays where it was;
resuming continues from it, with the pacing clock moved so the time spent paused is not owed as a
burst. `Playback.paused` carries the state. The change is published at once, caused by the client
that asked, and the four-a-second event is not sent while paused, since the position has not
moved and repeating it would only push real events out of the replay window. Any client may pause
a playback, as any client may stop one; the event names who did. `ley play` pauses and resumes on
space when stdin is a terminal, and its progress line reads `0:02 / 0:05, paused; space resumes`.
`RecordingJobTests` holds the position across half a second paused and sees it move after resume.

**A playback belongs to the client that started it**, like a non-persistent channel: it stops when
that client goes, which is what makes Ctrl-C in `ley play` stop the sound. There is no `persistent`
form, because nobody has asked to keep a recording playing after the client exits.

**Playback audio path.** The reader is `WAVReader` (PCM S16
mono, the only shape `PartWriter` writes), paced against the file's own rate into the same
`CoreAudioSink` a channel's audio goes to; the sink's ring absorbs the jitter, exactly as it does
for a channel. Nothing new runs on the DSP thread -- there is no DSP thread in this path at all.
An IQ part is refused with `INVALID_ARGUMENT`: `ley play` tunes those, and the daemon playing raw
baseband as sound would be noise.

**A host with no audio returns `PLATFORM_UNSUPPORTED`**, as `AttachSink(system_audio)` does. `ley`
then passes the local file to the configured player.

## Not implemented

- **A smaller IQ format.** Deferred, but measurement has since removed the reason for deferring
  it (2026-09-18): both readers already take cu8 (`IQFile.swift`, `go/pkg/iqfile`, and
  `FilePlaybackDevice` plays it), so only the write side is missing. And the re-quantising is not
  a loss on the radio this targets: the capture converts cu8 to cf32 as `(u-127.5)/127.5`, a pure
  affine map with nothing applied in between, and inverting it recovers every one of the 256
  levels exactly -- 0 mismatches over all 256 levels and over 8,000,000 real samples of a
  real-radio capture (not in the repository). Storing cf32 from an 8-bit dongle is 8 bytes carrying 2 bytes of
  information: 69 GB an hour where 17 GB would do, and a 20 GiB cap that holds 18 minutes instead
  of 70. The additive change is `iq_format`, and the accurate value is *the device's native
  format* (`DeviceDescriptor.nativeFormat` already carries it), which is exact for a cs8 or cs16
  radio too rather than a special case for the RTL-SDR. Reconsider this before compressed audio if
  the recording store reaches its size cap in normal use.
- **Gating IQ.** It needs either a named channel's squelch or the detector. A channel gate would be
  one additive field (`gate_channel_id`).
- **Resuming a recording after a restart.** A recording ends. The reserved `WatchConfig` contract
  has restart semantics, but no watch runner is implemented.
- **Scheduled starts.** `start_at_ns` is refused; a schedule is a feature of the durable job store.
- **Streaming a recording's samples** over MCP or gRPC. `ResolveLocalPath` and `ley play` are
  the two ways in, and the data-planes doc's "no lossless network stream" holds. A playback moves
  no samples over the socket either: the daemon opens the file itself and the client sees a
  position.
- **Seeking and looping a playback.** `position` is reported and not writable; a person who wants
  to hear a passage again plays the part again. A seek is one additive request field when somebody
  asks. Pausing exists ("Playing a recording back").
- **Opus or any compressed audio.** Tied to the remote-access milestone, as the data-planes doc
  says, and measurement (2026-09-18) shows disk space is not a reason for it. On real
  captures, lossless compression buys 25% on NFM transmissions (75% of PCM) and 39% on
  broadcast audio (61%) -- estimated with FLAC's fixed predictors and Rice coding, so real FLAC
  would do a few points better and not more. A radio recording is largely noise, and noise does
  not compress. That is a modest saving for an encoder dependency and for giving up the property
  WAV was chosen for: every tool reads it and Finder previews it. Opus would save about fifty
  times, but makes the recording a lossy copy of what was on the air, which suits the network and
  not a stored recording.

  **The gate is the compression.** 85.1% of that 100 s repeater recording is exactly-zero samples
  -- the `.audio` tap while the squelch is closed -- so `--gate squelch` does not compress the
  silence, it never writes it: 6.7x on real traffic, measured, with the per-exchange files and the
  transmission count as well. The first answer to a full disk is the gate, then the IQ format
  above; the audio format is third and small.
- **A lower audio rate.** NFM voice sits below 3 kHz and the recording runs to 24 kHz, so 16 kHz
  would be three times smaller. It is not free, though: the flat tail up there is real
  discriminator noise, so a lower rate is a lossy choice like Opus rather than a saving, and it is
  where the sub-audible work reads. An `--audio-rate` flag is the additive change; the default
  stays the channel's own rate, which is the rate the daemon actually produced.
- **A speech transcript.** Not the engine's job (`semantic-tier.md`, "Transcript").

## Open questions

- **Pre-roll and hang defaults.** 500 ms and 5 s are chosen, not measured, and ship as such. 500 ms covers the squelch's own attack and a syllable. The hang has to
  outlast the pause between overs, because a part is an exchange; on a repeater the repeater's
  own tail holds the carrier up through part of that pause, on simplex nothing does, and 5 s is
  the guess for both. `--hang` overrides it. Measure against a real-radio capture
  (not in the repository) for the pre-roll and a day of real use for the hang, and write the numbers here.
- **The store cap's number.** A fixed cap in one flag: predictable, and
  the same shape as the kept-records store. 20 GiB is the guess; a fraction of free space and
  separate IQ and audio caps were considered and set aside until a machine shows the fixed
  number wrong.
