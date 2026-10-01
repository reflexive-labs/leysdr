# Plan: Decoders

Implements `docs/design/decoders.md` (Milestone D.17). Work items in build order; DEC-2, DEC-4 and
DEC-6 run as three lanes off the contract in DEC-1 and meet in DEC-7. `[ ]` pending, `[x]` done,
`[-]` dropped with the reason, `[d]` waiting on a decision. An item is ticked only when its tests
pass and `make check` is green.

## DEC-1 `[x]` The contract

`proto/leyline/v1/decode.proto`: `DecoderManifest` (recipe, input mode, output shapes, field
hints, capability flags, executable), `DecodeRecord` (the envelope of §4), `DecodeConfig`, and
the `Decoders` service (`ListDecoders`, `SubscribeRecords`, `QueryRecords`). `jobs.proto` gains
`Job.config.decode = 11`, `StartJobRequest.decode = 4` and `ResourceKind.RECORDS = 5`. `AudioTap`
moved from `bulk.proto` to `common.proto`: the manifest specifies a tap, and `bulk.proto` imports
`control.proto`, which imports `jobs.proto`, which now imports `decode.proto`. Same package, same
values, so nothing on the wire or in a generated symbol name changes. `OutputShape` values carry a
`SHAPE_` prefix because enum values are package-scoped and `RECORDS` is a `ResourceKind`.

Plugin wire, in prose here and in the proto's header: stdin carries one varint-delimited
`StreamDescriptor` then varint-delimited `Frame`s (`AUDIO`, `F32`, mono, the channel's rate,
`GAP_MARKED`, the tap the manifest asked for); stdout carries varint-delimited `DecodeRecord`s;
stderr is prose the daemon logs under the plugin's name. A plugin fills `protocol`, `time`,
`device_id`, `position`, `validity`, `fields`, `raw` and `kind`; the daemon overwrites
`record_id`, `rssi_dbfs`, `snr_db`, `job_id`, `seq` and `channel_id`. `time` is the `SampleTime`
of the frame the packet ended in plus the sample offset within it, scaled to the capture rate
(`frame.time.sample_index + offset * capture_rate / audio_rate`; the descriptor carries
`center_hz` and `span_hz`, and `span_hz` is the capture rate).

## DEC-2 `[x]` The APRS decoder and the plugin SDK (Go lane)

Packages, all Apache-2.0:

- `go/pkg/plugin`: the SDK a Go decoder is written against. `plugin.Run(ctx, decoder)` reads the
  descriptor and frames from stdin (`protodelim`), hands each frame's samples (`[]float32`,
  converted from `S16` if the daemon ever sends that) and its `SampleTime` to
  `Decoder.Feed(samples, time, gap *Gap)`, and writes the records the decoder returns through an
  `Emit(*DecodeRecord)` callback to stdout, buffered and flushed per frame. Also
  `plugin.Serve(manifest)` boilerplate: `--manifest` prints the manifest JSON (for `ley decoders
  --check`), anything else runs. A `Recorder` helper converts an audio-sample offset within a
  frame into a `SampleTime` on the capture timeline (the formula in DEC-1).
- `go/pkg/decoders/afsk`: Bell 202 AFSK 1200 baud. `Demodulator` (any rate 8 kHz to 48 kHz):
  band-pass, mark/space correlators (1200/2200 Hz, one-bit window), a PLL bit clock with the
  usual 3/4 gain-at-transition, NRZI decode. `Modulator` for tests and fixtures: bits to
  continuous-phase AFSK at a rate. Measured in the tests: the round trip decodes 100/100
  synthetic frames at 48 kHz and at 12 kHz, and at least 95/100 with −10 dB SNR white noise
  added; the numbers land in the package doc comment.
- `go/pkg/decoders/ax25`: HDLC deframer (flag detection, bit unstuffing, CRC-16-CCITT/X.25 FCS),
  frame encoder, and the address-field parser (source, destination, digipeater path with
  H-bits, control, PID). `String()` renders the TNC2 monitor form
  (`SRC>DST,PATH*:info`).
- `go/pkg/decoders/aprs`: the info-field parser. Position, uncompressed and compressed, with
  symbol table and code; Mic-E; objects and items; weather (the positionless `_` form and
  weather in a position comment); telemetry (`T#`); messages, acks and rejects; status; a
  catch-all `kind = "other"` that keeps the raw text. Output is a `DecodeRecord`: `device_id`
  is the source callsign-SSID (`N0CALL-9`), `position` is set when present, `kind` names the
  form, `fields` carry `symbol`, `comment`, `path`, `destination`, `speed_kmh`, `course_deg`,
  `altitude_m`, weather (`temp_c`, `wind_kmh`, `wind_dir_deg`, `gust_kmh`, `rain_mm_1h`,
  `humidity_pct`, `pressure_hpa`), telemetry (`seq`, `a1`..`a5`, `digital`), message
  (`addressee`, `text`, `msg_id`), object name and alive flag. Table tests from the APRS 1.01
  spec examples for every form.
- `go/cmd/leydec-aprs`: the plugin. Its manifest is `decoders/aprs/manifest.json` (frequencies
  144.39 MHz then 144.8 MHz, NFM, bandwidth 15 kHz, `GAIN_LEAVE`, `TAP_AUDIO`, records and
  entities, `entity_silence_s` 1800, the field hints above, executable `leydec-aprs`).
  `--manifest` prints it. `make go` builds it beside `ley`.

Real-audio check, not in the gate: `go test ./pkg/decoders/... -run Real` decodes
`rf-captures/aprs_144390_auto.s16` (48 kHz S16 mono, 180 s off the owner's dongle on 2026-09-12,
gitignored) when the file exists, and its log line says how many frames passed CRC. The count is
recorded in the closing section of this plan.

## DEC-3 `[x]` The fixture (Go lane, after DEC-2)

`leyfix` gains `aprs_afsk`: an NFM carrier at 2.4 MSPS, −20 dBFS, 3.5 kHz deviation, carrying
three AX.25 UI frames (a position, a weather report, a status) as AFSK 1200 with 200 ms of
silence between them, using the `afsk` modulator and the `ax25` encoder; 1 s long at the default
duration. The sidecar's `expect` block gains `decode: {protocol: "aprs", records: 3,
device_ids: [...]}`. `FixtureTests` in the engine reads it like every other expectation once
DEC-5 can run a decoder in-process (a `FilePlaybackDevice` capture, the channel, the plugin).

## DEC-4 `[x]` Registry, plugin process and record store (Swift lane, first half)

All in `engine/Sources/LeylineDaemon/Decoders/`, GPL-3.0-or-later, proto types allowed (the
daemon target already holds proto messages as its record type).

- `DecoderRegistry` (struct, `Sendable`): `init(searchPath: [String])`; `scan() -> [Installed]`
  where `Installed` is the manifest plus the directory it came from and the resolved executable
  path (relative to the directory, else `PATH`); a manifest that does not parse or names no
  executable is logged with its path and skipped, never fatal; names are unique, first directory
  wins. `Daemon.Config.decoderSearchPath` and `--decoders` / `LEYLINE_DECODERS` feed it, with the
  platform default appended (`DaemonCommand.defaultDecodersPath()`).
- `PluginProcess` (final class): spawns `Foundation.Process` with the manifest's executable and
  args, cwd the plugin directory, stdin/stdout/stderr pipes. `start(descriptor:)` writes the
  descriptor; `write(_ frame:)` writes one frame (called from the runner's drain task, never the
  DSP thread); `records: AsyncStream<Leyline_V1_DecodeRecord>` is what stdout yields, parsed with
  `BinaryDelimited`; stderr lines go to `Logger(label: "leyline.decoder.<name>")` at info; `exit:
  AsyncStream<Int32>` reports termination; `stop()` closes stdin, waits up to 2 s, then SIGTERM,
  then SIGKILL. A write to a dead pipe is an error, never SIGPIPE (the daemon already ignores it).
- `RecordStore` (actor): `init(directory:capBytes:ageDays:)`. `open(job:config:manifest:capture:
  anchor:) -> RecordWriter`; `RecordWriter.append(_:)` writes a varint-delimited record and
  flushes every 32 records or 1 s; `noteAnchor(_:fromSample:)`; `close()`. The sidecar
  `<job_id>.json` holds `job_id`, `decoder`, `version`, `config` (proto JSON), `created_at_ns`,
  `capture_id`, `anchors: [{host_time_ns, sample_rate, drift_ppm, from_sample}]`, `count`.
  `query(_: Leyline_V1_RecordQuery) -> Leyline_V1_RecordPage`: scans sidecars, skips files whose
  protocol or wall-clock span cannot match, reads the rest, filters, sorts newest first, cuts at
  `limit` (default 1000) and reports the cut. Spatial filter is a haversine on `position`. `retain()`
  applies age then cap; `stats` answers path, cap, age.
- Tests (`LeylineDaemonTests/DecoderRegistryTests`, `PluginProcessTests`, `RecordStoreTests`): a
  temp directory with a good manifest, a broken one and one with a missing executable; the fake
  plugin is `leyline-fake-decoder`, a new executable target under `Tests/` built by SwiftPM, which
  echoes one record per frame it reads (device_id = the frame's seq) and exits on a frame whose
  payload is empty, so the restart path is testable; a store round trip with two anchors and every
  query filter.

## DEC-5 `[x]` The decode job and the service (Swift lane, second half)

- `AllocationRequest.channel` grows to `channel(frequencyHz:bandwidthHz:mode:deviceID:takeOver:)`
  and `AllocationResult.channel` carries a `ChannelLease` (`channelID`, `captureID`, `engine`,
  `release()`), in `CoreProtocols.swift`. `SessionCaptureAllocator` implements it per the design
  doc's order: a capture that already covers the frequency (channel fits: `|offset| + bw/2 ≤
  Fs/2`, and not swept) on any device, else a device with no capture (create one centred
  `frequency − Fs/8`, so the channel sits clear of the DC spike and inside the flat part of the
  passband), else a capture the don't-disturb test calls free (retune it), else declined with
  the same reasons a sweep gives, unless `takeOver`. The channel is persistent, `required_hz`
  set, owner kind `job`. Release destroys the channel, and the capture too if the lease created
  it.
- `JobStore.startDecode(config:by:)`: looks the decoder up (`DECODER_NOT_FOUND`), refuses
  `SLOT_ALIGNED` with `UNIMPLEMENTED`, allocates, opens the store writer when `keep`, attaches an
  `AudioFrameSource` (`F32`, the manifest's tap) as the channel sink, spawns the plugin with a
  descriptor naming the channel's rate and the capture's rate (`center_hz`, `span_hz`), and runs
  two tasks: the drain (frames from the source to the plugin, with `Gap` under `GAP_MARKED`) and
  the reader (records from the plugin: stamp `record_id`, `job_id`, `seq`, `channel_id`,
  `rssi_dbfs`/`snr_db` from the channel's latest meter, publish to the hub, append to the
  writer). A plugin exit restarts it after 1 s, doubling to 30 s, with `status_detail` reporting it
  and a coverage gap noted on the job (`Job.status_detail`; the transcript's `Gap` list arrives
  with D.15). A channel event `OUT_OF_CAPTURE` puts the job in `DEGRADED`; `CHANNEL_ACTIVE` back
  to `RUNNING`. `keep` jobs are not cancelled by `clientGone`. `cancel` stops the plugin, closes
  the writer, releases the lease.
- `RecordHub` (actor, in `JobStore` or beside it): `publish(record)` fans out to subscribers
  (drop-oldest, 256 deep) filtered by scope, and keeps the last 256 records per job for
  `since_seq` replay, on the actor so replay and live cannot interleave.
- `DecodersService`: `ListDecoders` (manifests plus search path and store stats),
  `SubscribeRecords` (presence like any stream; ends on cancel or shutdown), `QueryRecords`.
  Registered in `Server.swift`; `--store`, `--store-cap`, `--store-age`, `--decoders` on
  `DaemonCommand`.
- Error codes: `DECODER_NOT_FOUND` (`NOT_FOUND`, no manifest by that name) and `DECODER_FAILED`
  (`FAILED_PRECONDITION`, the plugin could not be started: executable missing or not runnable).
  Added to `EngineError.Code.all`, `ProtoMapping.statusCode`, `leyline.DaemonCodes` and the
  table in `docs/dev/engine-internals.md`, whose tests hold the four together.
- `docs/dev/engine-internals.md` gains a "Decoders" section (registry, plugin lifecycle, the
  hub, the store, the allocator's channel path) and the two rows.
- Tests: `DecodeJobTests` runs a decode job against a `FilePlaybackDevice` and the fake decoder
  from DEC-4 (records arrive with the daemon's stamps; `keep` writes the store; cancel releases
  the channel and the capture; a plugin that exits is restarted and the job reports it; a channel
  moved out of capture degrades the job and recovers), `DecodersServiceTests` over the socket.

## DEC-6 `[x]` `ley` and the fake (Go lane)

- Fake daemon: `ListDecoders` serves one manifest (`aprs`, the real one's shape), `StartJob
  (decode)` runs a fake job that emits a position, a weather and a status record every 200 ms
  from three fake stations, `SubscribeRecords` with `since_seq` replay, `QueryRecords` over a
  fake kept-job log; every rule the Swift daemon keeps (a kept job outlives its client, a
  decoder name that does not exist is `DECODER_NOT_FOUND`).
- `go/pkg/leyline`: `ListDecoders`, `StartDecode`, `SubscribeRecords`, `QueryRecords` wrappers;
  `RecordWallTime(rec, anchors)`; `DaemonCodes` gains the two codes.
- `go/pkg/records`: the entity fold of the design doc's "Decisions" (`Table.Apply(rec)`,
  `Table.Expire(now, silence)`, rows sorted by last seen), plus `Summary(rec)` rendering a record
  as one line the way `ley decode` prints it.
- Verbs: `ley decoders` (table: NAME, FREQUENCY, MODE, OUTPUTS, VERSION; `--json` the response);
  `ley decode <name> [--freq F] [--device SEL] [--take-over] [--job]` (starts the job, subscribes
  from seq 0, prints one line per record: wall time, device id, kind, summary; `--json` NDJSON
  `DecodeRecord`s; Ctrl-C cancels an ephemeral job and leaves a `--job` one running, printing
  `ley jobs cancel`); `ley records [--protocol P] [--since 1h] [--device-id ID] [--kind K]
  [--near LAT,LON --radius 10km] [--in-effect] [--limit N]` (a table newest first; `--json` the
  `RecordPage`); `ley track <protocol>` (the live entity table redrawn in place, seeded from
  `QueryRecords --since` when the store has any, then `SubscribeRecords(protocol)`; `--json` one
  table snapshot per redraw as NDJSON). `jobs` learns the `decode` kind and its range column
  shows the frequency.
- Help goldens for all four, `docs/reference/cli.md` tree and `--json` shapes,
  `docs/dev/cli-style.md` if a new glyph or ink appears (it should not).
- Tests against the fake for every verb and every flag; `TestDecodeStopsAnEphemeralJob`,
  `TestDecodeJobOutlivesTheClient`, `TestTrackAgesOutASilentStation`, `TestRecordsSinceUsesAnchors`.

## DEC-7 `[x]` End to end

`TestDecodeAgainstRealDaemon` in `go/internal/e2e`: `ley play fixtures/aprs_afsk.cf32 --loop`,
then `ley decode aprs --json --count 3` with `LEYLINE_DECODERS` pointing at the repository's
`decoders/` and the built `leydec-aprs` on `PATH`; the three records carry the fixture's device
ids, positions within 1e-4 degrees, `rssi_dbfs` near −20 and a `time` inside the file. Then a
`--job` run whose records `ley records --protocol aprs` returns after the client has gone. And the
real-radio run: `ley decode aprs` against the owner's dongle over rtl_tcp on 144.39 MHz, the
transcript recorded in `docs/guide/using-ley.md`.

## DEC-8 `[x]` Documentation

`docs/guide/using-ley.md` gains "Decode what is being said" (APRS, with the recorded transcript);
`docs/reference/cli.md` the verbs and shapes; `docs/README.md` the design doc; `README.md` "Where
things stand" and `docs/plans/build-order.md` gain D.17; `CHANGELOG.md`; `ley help roadmap`; the
`records` and `decode` words in the writing guide's table.

## Later

- DEC-9a `[x]` Predicates and the notification sink, on the record plane: `DecodeConfig.predicate`
  (stateless clauses -- field test and geo test) and `DecodeConfig.notify` (webhook, shell hook,
  macOS notification). The daemon evaluates the predicate on every stamped record before it reaches
  the hub, the store and the notifier; an unset predicate matches everything. `ley watch <decoder>
  [--where field=value ...] [--county FIPS] [--near LAT,LON --radius R] [--notify TARGET] [--job]`
  is a decode job with a predicate and a notifier. This repurposes the `watch` stub, which was
  reserved for the D.15 audio-transcript watch: the owner's decoder requirements
  (`docs/design/decoders.md`, "Surfaces") spell `ley watch same --county 06009 --notify` and are the
  newer spec, so the record-watch verb takes the name; the audio-transcript watch, still unbuilt, is
  D.15's to place. Built and tested against the existing decoders (a `--where device_id=...` watch on
  aprs, a shell notifier that writes a file), so the machinery is proven before the SAME DSP lands.
- DEC-9b `[x]` The SAME/EAS decoder (driver C): a decoder plugin that demodulates the AFSK header
  burst on NOAA weather radio (162.400--162.550 MHz NFM), parses ORG/EEE/FIPS/duration, emits a
  record whose `validity` is the alert window and whose `fields` carry the event code and the FIPS
  county list, with a fixture. Then `ley watch same --county <FIPS> --notify` is driver C end to end.
- DEC-10 `[x]` The registry fold, `ley label`, `ley devices-seen`, built client-side over records
  that already exist and tested against the existing decoders. A `records.Registry` folds the kept
  record log into one row per transmitter (first and last seen by wall time through the page's
  anchors, an observation count); `ley devices-seen` renders it with `--protocol`, `--since` and
  `--quiet-since` (the absence question -- which sensors went quiet); `ley label` keeps the
  user-given names in a client-side JSON store (`go/pkg/labels`, `$LEYLINE_LABELS`), which
  `devices-seen` joins in. The state boundary keeps the fold deterministic and the labels in the
  client (`docs/design/decoders.md`, "The state boundary" and section 5). Driver B's own traffic
  waits on an `rtl_433` adapter, a plugin like DEC-13's `dump1090` one; the surfaces above already
  work over any decoder that carries a `device_id`.
- DEC-11 `[x]` Kept decode jobs come back after a daemon restart (2026-09-17). The job store writes
  `kept-jobs.json` beside the record store whenever a kept job starts or ends by a cancel or a
  failure, and not when the daemon's own shutdown ends it; the next daemon reads it after the
  device mirror is up, waits up to 20 s for a radio, and starts each job again as the job it was:
  the same id, so `ley://records/<job_id>` and `ley jobs cancel` still name it, and the time it was
  first started, with "resuming after a daemon restart" as its first detail. Its records append to
  the same files with the sequence continuing from the store's count, and the sidecar's anchors
  now name the capture each dates (`capture_id`, absent in older sidecars, which had one capture),
  because a new daemon makes a new capture whose sample index starts over and the old records must
  keep the old capture's clock; `QueryRecords` answers with an anchor per capture. A decoder no
  longer installed at boot is logged and dropped from the file. The rest of D.15 (recurring scans,
  watch jobs, transcripts) is still open; this is the one job that had declared an intent to keep.
- DEC-12 `[ ]` Slot-aligned input (driver E, FT8).
- DEC-18 `[x]` IQ input to decoders: `DecoderInput.signal` (AUDIO default, or IQ) and the daemon
  path for it. A decoder that declares IQ gets the capture's raw cf32 baseband over the bulk IQ
  frame contract instead of a channel's audio, via `allocateCaptureIQ` (a capture, not a channel)
  and `IQDecodeRunner`; the Go SDK grew `RunIQ`/`MainIQ`/`IQDecoder`, and `leydec-iqstat` proves it
  end to end (it read -20 dBFS off the -20 dBFS `nfm_tone` fixture). This is the enabler the
  wideband drivers need. Correct for one decoder per capture; sharing a daemon-created capture
  across IQ decoders needs capture refcounting -- DEC-19.
- DEC-19 `[ ]` Capture refcounting so several IQ decoders share one daemon-created wide capture
  (the multiplexing story: twenty rtl_433 decoders on one 433 MHz capture). Today the IQ lease's
  creator destroys the capture on release, which is wrong if another decoder still taps it.
- DEC-20 `[x]` AIS, a marine vessel decoder (`leydec-ais`): 9600-baud GMSK on 161.975/162.025 MHz
  decoded from the NFM discriminator (no IQ input needed), parsing the Class A/B position and static
  messages into records keyed by MMSI, checked against the gpsd reference vectors. It is not one of
  the five reference drivers but a real third decoder, and it gives `ley track ais` a vessel table.
- DEC-21 `[x]` Friendly decoder aliases: `DecoderManifest.aliases` (repeated string), a client-side
  resolver `leyline.ResolveDecoder` that maps a typed name to the decoder that claims it, and
  `ley decode`/`ley track`/`ley watch` resolving an alias to the canonical name before they start
  or subscribe (records carry the canonical `protocol`, so the subscription must too). AIS carries
  `vessels`; an ADS-B decoder would carry `aircraft`. The daemon does not resolve aliases -- they
  are a client convenience, and the resolver reads them from `ListDecoders`; completion offers them
  and `ley decoders` shows them beside the name. `ley track vessels` now works.
- DEC-22 `[x]` Cancelling a decode job could kill the daemon. `PluginProcess.write` asked the
  pipe's `NSFileHandle` for its descriptor on every frame, and `stop` closes that handle; a frame
  the drain handed over a moment after cancel asked a closed handle, which raises an Objective-C
  exception Swift cannot catch, so launchd restarted `leylined` (seen twice in the log on
  2026-09-13, found through `ley mcp`, whose `list_entities` cancels the decoder it started). The
  descriptor is now cached at spawn under a lock a write holds for its duration; `stop` empties it
  before closing, so a late frame is dropped, as it is for a plugin that stopped reading, and
  a second `stop` closes nothing. `PluginProcessTests` writes after a stop and races writes against
  one. A kept job still does not survive the restart this caused (DEC-11).
- DEC-23 `[x]` Liveness in the job. A decode job said "decoding with aprs" and nothing more for as
  long as it ran, so a client could not tell a decoder that had produced records from one that had
  not without subscribing to them; an agent testing `ley mcp` fell back to `ps` to check the plugin
  was alive, which the job could have reported. `Job.status_detail` now reads "decoding with aprs:
  12 records, last 3 s ago" (or "no records yet"), from `DecodeLiveness` in both runners: the first
  record is published at once and a moving count every two seconds after that, never a Job event
  per record. Silence stays RUNNING (DEC-16), and the detail now shows it. The fake mirrors it
  ("decoding aprs on 144.390 MHz: 12 records, last just now"), `ley jobs` shows it in DETAIL and
  the MCP `get_job` in its text.
- DEC-13 `[ ]` An ADS-B plugin (driver A, a `dump1090` adapter with CPR pairing plugin-side), on
  the IQ input DEC-18 built.
- DEC-14 `[ ]` The MCP families and `ley identify`.
- DEC-15 `[ ]` A SQLite index under `QueryRecords`, when a query is measured slow.
- DEC-16 `[x]` A plugin that stops reading no longer stalls the drain: the daemon's write end is
  non-blocking, so a full pipe drops the frame and holds the gap open for the next one that lands
  (`PluginProcess.writeDelimited` returns `droppedFull`), and a frame that stalls half-written
  replaces the plugin (`PluginStalled`). The plan's second half -- a no-records health check that
  respawns -- was **dropped**: a decoder that emits nothing is indistinguishable from a
  quiet band, and driver C (SAME) is silent by design, so killing a plugin for silence would kill
  ones that are working. A plugin that has stopped reading is the only hang, and the
  non-blocking write detects it.
  Tests: `DecodeJobTests.testAPluginThatStopsReadingDoesNotWedgeTheDrain` (a `--deaf-after=3` fake
  reads three frames then stops; the job stays RUNNING and cancel returns promptly), the existing
  `PluginProcessTests`.
- DEC-17 `[x]` `docs/reference/writing-a-decoder.md`: the daemon/decoder division, the manifest, the
  stdio wire, the Go SDK, wrapping an existing tool, and the boundaries. Linked from `docs/README.md`
  and the design doc.

## Closing

What the second look found, 2026-09-12.

- **The lanes met on the first try.** `TestDecodeAgainstRealDaemon` (the real daemon, the real
  `leydec-aprs`, the fixture through `ley play`) passed on its first run: three records with the
  daemon's stamps, `rssi_dbfs` within 0.02 dB of the fixture's −20 dBFS, a kept job that outlived
  its client and a store with one record file. The whole e2e suite runs in 14 s here.
- **The real radio exposed one bug the fixture did not.** On the owner's dongle over rtl_tcp the
  allocator opened the decode capture at 3.2 MSPS, the fastest rate the device lists (the sweep's
  rule), and the channel's audio rate followed it to 49.2 kHz, which the AFSK demodulator refused
  and the daemon spent the run respawning. A channel's capture now opens at the default rate and
  the demodulator accepts up to 96 kHz (commit bc0e62f).
- **144.39 MHz is quiet at the owner's location.** Two three-minute captures (auto gain and 40 dB;
  `rf-captures/`, gitignored) held one decodable packet between them, one station's position beacon at 27.6 s of the
  first, and `leydec-aprs` recovered it; a tone-energy scan of the same file found the same
  burst and no other of packet length. A live `ley decode aprs` on the dongle ran for the
  duration of the work without a packet. The guide's transcripts are therefore recorded against
  the fixture, and state that.
- **Measured.** The AFSK demodulator decodes 100/100 synthetic frames clean at 48 kHz and 12 kHz,
  99/100 at 0 dB SNR over the 24 kHz audio band and 12/100 at −4 dB (the curve is in
  `go/pkg/decoders/afsk`'s doc comment). The −10 dB gate the plan asked for is 3 dB of Eb/N0
  and no non-coherent FSK demodulator holds a 500-bit frame there; the gate is 0 dB.
- **Two deviations from the plan's text.** `BinaryDelimited` takes Foundation streams, not file
  descriptors, so both the daemon and the fake decoder frame the delimited protobuf by hand
  (same bytes on the wire). `ley records` filters a job with `--job-id`, because `--job` on
  `decode` is the boolean that keeps one.
- **One flake fixed.** The restart test raced the respawned fake decoder's second exit through a
  170 ms `RUNNING` window; the fake now dies once, by a marker file in its directory.
- **One pre-existing race fixed.** `ley levels` read the channel's full scale after the event
  drain owned the mirror; `-race` had not been run since that verb landed.
