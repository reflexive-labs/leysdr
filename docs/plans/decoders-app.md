# Plan: decoders in the app, and ADS-B

Status: active, written 2026-11-02. Brings the decoder tier (`../design/decoders.md`,
`decoders.md`) into the Mac app as one generic surface, and adds ADS-B (DEC-13) as the decoder
that proves it. Legend as in `app.md`: `[ ]` pending, `[x]` done, `[-]` dropped with the reason.

## Why

The daemon has six decoders, kept jobs, predicates, notifiers and a record store. The app shows
none of it except speech in the Library: a person cannot start APRS, SAME or AIS from the window,
see a record, a station table or a map. `ley decode`, `ley track` and `ley watch` are the only
way in. Every decoder added after this should appear in the app with no app change, so the
surface is driven by the decoder's manifest, not written per decoder.

## What the owner's air carries (2026-11-02)

Measured over rtl_tcp on the owner's Mac, the R820T dongle, gain 40, a private daemon:

- **1090 MHz:** on the second antenna, 19 DF17 messages passing CRC-24 in 9 s, all from one
  aircraft (`ACEB61`), checked by a scratch PPM demodulator with a 0.2-sample phase search. Gain
  30 decoded none; the first antenna decoded none. The capture is
  `rf-captures/adsb-1090-g40-antenna2.cf32` (gitignored, 10 s, 2.4 MSPS cf32; the first 0.5 s
  is the tuner settling). Placement, not the antenna, is the stated limit.
- **433.92 MHz:** no bursts in 30 s. **929--932 MHz** pagers and **400--406 MHz** radiosondes:
  nothing over the floor in a sweep.
- **162.400 MHz:** NOAA wx2 at 9 dB over the floor, 6/6 looks. **144.39 MHz:** weak (one packet
  in three minutes, 2026-09-12).

So ADS-B can be proven on the owner's air, thinly; APRS, AIS and SAME are proven on fixtures and
the stored captures.

## Decisions

- **A third place, Decoders (⌘3), beside Radio and Library.** Same three columns as the Library:
  a sidebar of installed decoders with their running jobs, a page for the selected decoder, an
  inspector for the selected record or transmitter. The radio window gets a one-line "decoding"
  indicator later (DA-9), not a panel.
- **The manifest says how a decoder is shown.** A new `DecoderManifest.display` (additive) carries
  a title, an SF Symbol name, per-kind one-line summary templates, an entity-name template and the
  entity table's columns. Both clients render the same line from the same template, so `ley
  decode` and the app agree, and a new decoder needs only its manifest.
- **Views follow the declared output shapes.** Every decoder gets the record log. A decoder that
  declares `SHAPE_ENTITIES` gets a table of transmitters. Anything whose records carry a position
  gets a map. Records with a `validity` window (SAME) show as alerts in effect. Nothing is
  special-cased by decoder name.
- **The entity fold is ported to Swift, and both folds are pinned by shared vectors.** The state
  boundary keeps interpretation in the client (`../design/decoders.md` section 3), and the app
  does not link Go. `testdata/decoders/` holds a record log and the rows it folds to; Go and Swift
  tests both read it.
- **One dongle: the app predicts where a decoder lands before it starts.** There is no dry run in
  the contract, and the allocator's rules are readable from `GetState` (captures and spans, channel
  owners, `activity.liveAudioSinks`, `activity.lastInteractiveWriteNs`, the 60 s don't-disturb). A
  pure `DecoderPlacement` in `LeylineClient` mirrors `SessionCaptureAllocator` and says one of:
  runs alongside what you are listening to, takes the idle radio, needs the radio from you (Start
  asks, then sends `take_over`), or no radio can hear it. The prediction is advice; the job's
  state and detail are the truth and the page shows them. This copy of the allocator is temporary: `claims.md` (CL-2) replaces it with the daemon's own `Control.Plan`. For a multi-frequency recipe the app
  picks the first recipe frequency inside the current span, else the first.
- **A decoder started from the app is a kept job.** `keep: true`: it runs until Stop, survives the
  app quitting and a daemon restart (DEC-11), and its records are a resource the page, `ley
  records` and the MCP tools all read. The page shows history from `QueryRecords` (the last 24 h)
  and then follows `SubscribeRecords` for the protocol.
- **The map is MapKit, with no location permission.** It frames the transmitters, never the
  user. Tiles come from Apple; the app already contacts the network for Sparkle and AI. In staged
  runs (`LEYLINE_APP_STAGE`) tiles would make pictures nondeterministic, so the staged map draws
  the same annotations on a plain projection; the real map is checked by hand.
- **ADS-B is native Go, written from the published Mode S and ADS-B formats**, not wrapped and not
  derived from dump1090 (GPL, and not on the Mac). Decode state (CPR even/odd pairing, the
  address list that validates DF4/5/20/21 replies) lives in the plugin, per the state boundary.
- **An IQ decoder that needs a centred capture says so.** `needs_dedicated_capture` (already in
  the manifest, unused) makes the allocator reuse a capture only when it is centred on the
  frequency at the recipe's rate, and otherwise create or retune under the existing don't-disturb
  and `take_over` rules. ADS-B sets it: a Mode S frame is 2 MHz wide and an off-centre capture
  clips it.

## Work

### Batch 1: contract, engine, ADS-B (three lanes, no app UI)

- [ ] **DA-1 Display hints in the manifest (Go lane, owns the proto).**
  `proto/leyline/v1/decode.proto`: `DecoderManifest.display = 19` of a new
  ```
  message DecoderDisplay {
    string title = 1;                  // "APRS", "Aircraft", "Vessels", "Weather alerts"
    string symbol = 2;                 // SF Symbol name: "airplane", "ferry", "exclamationmark.triangle"
    map<string, string> summaries = 3; // record kind -> template; "" is the default
    string entity_name = 4;            // template for a transmitter's name; empty -> device_id
    repeated string columns = 5;       // fields shown as entity-table columns, in order
  }
  ```
  The template language, implemented in Go (`go/pkg/records`) and later Swift (DA-7) against the
  same vectors: `{name}` is a field or a promoted name (`device_id`, `kind`, `position`,
  `altitude_m`, `rssi_dbfs`, `snr_db`, `label`); `[ ... ]` is an optional group, rendered only if
  every name inside it resolved (no nesting); `{{` and `}}` are literal braces. TEXT prints as is;
  INTEGER in decimal; NUMBER with at most the decimals the value needs, up to two; FLAG prints the
  field's name when true and is unresolved when false; `position` prints as
  `records.FormatPosition` does. A field's unit is not appended: the template writes it. If no
  template matches the kind, the existing `records.Summary` runs, so nothing regresses.
  Manifests gain `display` for aprs, ais, same, iqstat and speech. `ley decode`/`ley track`
  render with the template when one exists, and `ley track` uses `columns` when set; `ley
  decoders` shows the title. Vectors: `testdata/decoders/summary-cases.json` (manifest display,
  record, expected line) and `testdata/decoders/fold-*.json` (a record log and the entity rows it
  folds to through `records.Table`, including expiry by `entity_silence_s`). `make proto-check`,
  the help goldens and `docs/reference/writing-a-decoder.md` updated.
- [x] **DA-4 IQ decoders follow their capture, and claim a centred one (Swift engine lane).**
  `IQDecodeRunner` gains what `DecodeRunner.followChannel` does: when the capture no longer covers
  the frequency (someone retuned it), the job goes DEGRADED with "the capture moved away from
  1090.000 MHz; waiting for it to come back", stops feeding the plugin and marks the gap, and
  returns to RUNNING when the span covers it again. A recentre that still covers it sends the
  plugin a new `StreamDescriptor` centre (or, if the wire cannot say that mid-stream, treats it as
  moved away). `needs_dedicated_capture` in `allocateCaptureIQ` as the decisions say. Tests in
  `DecodeJobTests`/allocator tests with the file device.
  Done 2026-11-02: the wire cannot change a descriptor mid-stream, so a recentre that still
  covers the frequency is treated as moved away ("the capture moved from … to …"), and so are a
  rate change and a detach. Tests in `IQDecodeJobTests` on a retunable virtual radio.
- [x] **DA-6 IQ decoders on stored IQ recordings (Swift engine lane, after DA-4).**
  `startSourceDecode` refuses an IQ decoder today (`EngineError.unimplemented`). Read the
  recording's cf32 parts, frame them as the live IQ path does, mark the gaps between parts, and
  block rather than drop as a stored SEGMENTED source does (R1 of `recordings-0.2.1.md`). This is
  "decode a recording" for ADS-B, and lets e2e drive `leydec-adsb` through the daemon with no
  radio. An IQ decoder on an audio recording, and the reverse, are refused with the reason.
  Done 2026-11-02: `RecordingSource` reads cf32 parts and `DecodeRunner` runs them on the stored
  path. An audio recording for an IQ decoder is `INVALID_ARGUMENT`; an IQ one for an audio decoder
  stays `UNIMPLEMENTED` (no offline demodulator). `ley decode <decoder> --recording <id>` is the
  `ley` side (kept, like `ley transcribe`), and `TestIQDecoderOnAStoredIQRecording` drives iqstat
  through it in e2e.
- [x] **DA-5 The ADS-B decoder (Go lane, DEC-13).** `go/pkg/decoders/modes` and
  `go/cmd/leydec-adsb` on the SDK's `RunIQ`, `decoders/adsb/manifest.json`:
  name `adsb`, alias `aircraft`, recipe 1090 MHz at 2.4 MSPS, `SIGNAL_IQ`, `CONTINUOUS`,
  `needs_dedicated_capture`, `SHAPE_RECORDS` + `SHAPE_ENTITIES`, `entity_silence_s` 60, field
  hints, Apache-2.0.
  - Demodulation: magnitude, preamble detection, a fractional phase search at 2.4 MSPS, PPM bit
    decisions, CRC-24 (generator 0xFFF409). Single-bit error correction for DF17/18 only.
  - Messages: DF17/18 identification (TC 1--4: callsign, category), airborne position (TC 9--18
    and 20--22: altitude, CPR), airborne velocity (TC 19), surface position kept as a record
    without a position until it is decoded; DF11 all-call; DF4/5/20/21 altitude and squawk only
    when the address recovered from the parity is an aircraft heard in DF11/17/18 in the last
    60 s.
  - CPR: a global decode from an even/odd pair under 10 s apart, then a local decode against the
    aircraft's last position. A position is never emitted from one frame alone.
  - Records: `device_id` the ICAO address as six upper-case hex digits; kinds `identification`,
    `position`, `velocity`, `surveillance`; position promoted with `altitude_m` from feet; fields
    `icao`, `callsign`, `category`, `altitude_ft`, `ground_speed_kn`, `track_deg`,
    `vertical_rate_fpm`, `squawk`, `df`, `tc`; `raw` the 7 or 14 bytes.
  - Tests: the published worked examples (the identification frame `8D4840D6202CC371C32CE0576098`
    reads KLM1023; the pair `8D40621D58C382D690C8AC2863A7` / `8D40621D58C386435CC412692AD6` reads
    52.2572, 3.91937 at 38000 ft; the velocity frame `8D485020994409940838175B284F`), each CRC
    checked; a synthetic IQ generator (a `scene_adsb` in `go/cmd/leyfix`, several aircraft on
    tracks, PPM at 2.4 MSPS with noise) decoded back to its tracks; 60 s of synthetic noise
    yielding no record; and, when `rf-captures/adsb-1090-g40-antenna2.cf32` exists, at least 15
    records from `ACEB61` (skipped when it does not). No `display` block: DA-1 owns that field and
    the manifest gains it at merge.
  - `make go`, `make install-decoders` and the e2e decoder list include it.
  - Done 2026-11-02. The antenna capture gives 27 records from `ACEB61`, 9 with a position near
    37.69N 122.38W; the demodulator runs at 40 MSPS (`BenchmarkDemod`, three aircraft over noise)
    to 64 MSPS (the capture) on one core of an M4 Max. Bits are decided by the half-bit integrals
    and, when the parity fails, by a two-state Viterbi search, because at 2.4 MSPS a sample
    straddles two half-bits; synthetic replies decode 42 of 42 at 15 dB, 34 at 12 dB, 13 at 10 dB.
    One addition to the item: a corrected bit and a DF11 with a non-zero interrogator code are
    taken only from an aircraft already heard in the clear, so noise cannot add an address. The
    e2e plays a new default fixture, `adsb_burst` (1 s, two aircraft).

### Batch 2: the Decoders place (one Opus lane, then one full check)

- [x] **DA-7 Client logic in `LeylineClient` (pure, tested on Linux).** The template renderer
  and the entity fold in Swift, both passing `testdata/decoders/`; `DecoderPlacement` with tests
  per allocator rule; `DaemonConnection.records(scope:sinceSeq:)` over `SubscribeRecords` with
  the `pump` pattern; a `LabelStore` over `labels.json` (`LEYLINE_LABELS`, the path
  `go/pkg/labels` uses) on the `BookmarkStore` pattern; per-transmitter position trails (the last
  50 positions, client-side). Done 2026-11-02: `DisplayTemplate.swift` (with `RecordSummary`,
  the port of `records.Summary`, so a fallback reads as `ley`'s does), `EntityTable.swift`,
  `DecoderPlacement.swift`, `DecoderPages.swift` (tabs, jobs, the record log, alerts, the
  inspector's words) and `Labels.swift`; every vector passes.
- [x] **DA-8 The Decoders place.** `WindowPlace.decoders` (⌘3), its sidebar (installed decoders
  with symbol, title and state; running jobs under each with the liveness detail), the page
  (Start/Stop with the placement line and the take-over confirmation; Log, Table and Map tabs
  shown by output shape and by whether any record has a position; alerts in effect above the log
  for `validity` records), the inspector (fields with units and descriptions from the hints, raw
  bytes, time, signal, and naming the transmitter through `LabelStore`). Stage keys and two
  check scenes: `decoders-aprs` (scene_aprs) and `decoders-adsb` (scene_adsb), with the staged
  map. The ADS-B manifest gains its `display` here if batch 1 merged without it.
  Done 2026-11-02, unverified until the Mac (`../dev/app.md`, "The Decoders place"). Three calls
  the plan left open: a transmitter ages out only while a job of the decoder runs, so a stopped
  decoder's page keeps what it last heard; a decoder with no frequency of its own (speech) starts
  on the tuned frequency and says so when nothing is tuned; and the window's followed channel
  counts as "you" in the placement's words, as its own does. Stage keys `decoder`,
  `decoder_tab` and `select_transmitter`, the `decoders` region and state, and `leyshots` gives
  a scene its own `LEYLINE_LABELS`.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1051 checked, all ok) with three new
  scenes (`decoders-aprs`, `decoders-adsb`, `decoders-take-over` on a new `scene_adsb_off`) and
  31 scenes re-recorded for the toolbar's third place only. Table rows and map markers sort by
  name, so a live table does not reorder every second.

### Batch 2 follow-ups (found on the Mac pictures and in the check run)

- [x] **DA-13 An IQ decoder on a capture it cannot decode is DEGRADED, not RUNNING.** In
  `decoders-take-over` the file radio cannot retune, so after the take-over `leydec-adsb` logs
  that the capture is too far from 1090 MHz while the job reads "Running · no records yet". The
  allocator should decline a dedicated job it cannot centre, and a plugin needs a way to report
  "cannot decode this input" that the job shows.
  Done 2026-11-02, the scene unverified until the Mac. No retune was involved: `iqCentre` clamps
  to the nearest point a device tunes, a file radio's only point is its recording's centre, and
  `isCentred` compared the capture with that clamped point, so step 1 took the 1090.6 MHz capture
  as centred. A dedicated claim now needs the capture within 1 kHz of the frequency itself at
  exactly its rate; a device that cannot get there is no candidate (the decline is "NESDR SMArt
  v5 cannot tune to 1090.000 MHz (a file radio plays what it recorded)", `NO_DEVICE`), and a
  created or retuned capture is read back and put back when it did not land. The second line: a
  plugin that exits 3 (`plugin.RefuseInput`) ends its job `FAILED_PRECONDITION` with its last
  stderr line, unrestarted; `leydec-adsb` refuses an off-centre or slow capture with it. So the
  job is FAILED, not DEGRADED: nothing will change under it. The fake decoder's crash status moved
  from 3 to 70.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1054 checked, all ok); the app's placement now
  mirrors the rule (b0db399), so `decoders-take-over` shows the decline before Start, with Start
  off and no question, and a terminal's `--take-over` is declined with the same words.
- [x] **DA-14 The table's numbers use the template's precision.** `columns` gains an optional
  `:N` (`ground_speed_kn:0`), so the table reads 190 where the summary says 190 kn, not 189.7.
  The LAST column becomes LATEST, which no longer reads as a twin of LAST HEARD.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1054 checked, all ok); `decoders-adsb`'s
  table reads whole numbers under LATEST.
- [x] **DA-15 Units agree.** The inspector shows altitude in the decoder's unit (`altitude_ft`)
  beside the promoted metres, not metres alone; frequencies in one sentence use one unit (the
  take-over question mixes 1.090 GHz and 1090.600 MHz).
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1054 checked, all ok); LEY303 reads 36000 ft
  in the inspector and the decline's sentence writes 1090.000 MHz.
- [x] **DA-16 Test decoders stay out of a person's list.** `speech-scripted` shows as a second
  "Speech": a manifest flag (`test_only`) hides it unless the daemon runs with `--no-hardware`.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1054 checked, all ok); the check scenes'
  `--no-hardware` daemons still list `speech-scripted` and `iqstat`.
- [x] **DA-17 Small layout:** the job header repeats the detail line; the log's kind column is
  wider than its longest kind; long field names crowd their value in the inspector.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1054 checked, all ok); `decoders-aprs`
  checks the kind column at `weather` and a field name's tooltip.

### Batch 3: the rest

The calls for this batch, taken 2026-11-02:

- [x] **DA-9 Decoding, seen from the radio.** A compact row per running decoder at the top of the
  Radio sidebar (symbol, title, the liveness count) that opens its page in Decoders. On the
  waterfall, a record from an audio decoder whose channel is inside the visible capture draws a
  small tag at the job's frequency on the row it arrived in: the transmitter's name from the
  display's `entity_name`, else `device_id`. Tags scroll away with the rows, at most one per
  transmitter per ten seconds, and View has "Show Decoded Names" (on by default). IQ decoders
  draw no tags: their records have no frequency of their own inside the capture.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1102 checked, all ok) with the new
  `radio-decoding`: the APRS row tops the sidebar, N0CALL tags sit on the signal at 144.390 MHz,
  and View ▸ Show Decoded Names unticks as it hides them.
- [x] **DA-10 Watches from the app.** "Notify Me…" on a decoder's page opens a sheet that builds a
  `DecodeConfig.predicate` from the manifest's field hints (a field and a value for TEXT and
  INTEGER fields; a place and a radius when the decoder's records carry positions) and a macOS
  notification as `notify`, then starts it as a kept job. Nothing is special-cased by decoder:
  SAME's county is its `fips` field. A watch is listed under its decoder in the sidebar with its
  condition in words, and Stop ends it. The daemon notifies with the app closed.
  Done 2026-11-02, unverified until the Mac (`decoders-watch`). `Watches.predicate` ports `ley
  watch`'s `buildPredicate` and `testdata/decoders/watch-cases.json` pins both; the sheet writes
  its choice as a `--where` token (`is` is `=`, `contains` is `~`, `is over` and `is under` are
  `>` and `<`, the last two for INTEGER only), so SAME's county is `fips contains 06009`, as
  `--county` builds it. Calls the plan left open: `device_id` is offered before the hints, as
  every decoder that names transmitters fills it; NUMBER fields are not offered (a value suits
  them less than a threshold); the place shows once a record on the page has a position, as the
  Map tab does; a watch whose radio is somebody's is not started (no `take_over`), and the sheet
  says so; the sidebar's words are read back from any watch's predicate, `ley watch`'s too; and
  the Radio sidebar's decoding rows (DA-9) count plain runs only, since `DecoderPages.running`
  now leaves watches out.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1102 checked, all ok) with the new
  `decoders-watch`: `pick` and typing reach the sheet's fields, and `state.alert` now reads a
  SwiftUI sheet's words (4b01a5f). Notify Me… is off where Start is (2b56846). By hand, a `ley
  watch aprs --where device_id=N0CALL-3 --notify --detach` on scene_aprs had usernoted deliver an
  osascript notification on each pass of N0CALL-3, about every 21 s.
- [x] **DA-11 Decode a recording.** The Library's context menu gains "Decode With" listing the
  installed decoders whose input matches the recording (audio decoders on an audio recording, IQ
  decoders on an IQ one; speech stays under Transcribe). It starts a kept job with `source_uri`,
  as transcription does; the records appear on that decoder's page, and the recording's
  inspector says how many records each decoder found, with a link to the page.
  Done 2026-11-02, unverified until the Mac (`library-decode-with`). Decode With is in the row's
  context menu and beside Transcribe in the part inspector, its items off while the recording is
  still being made (the daemon refuses one then). The inspector's line is each decoder's newest
  job over the recording, counted by `QueryRecords` on its `job_id` whenever the job changes
  (1000 at most, `1000+ records` past it). A transcription is now the speech decoder's job over a
  recording only, so another decoder's job there is not read as one. The stage key `decode_with`
  runs an item's code path, since a check cannot open a context menu.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1102 checked, all ok) with the new
  `library-decode-with`: APRS finds 7 records in the recorded audio, the inspector reads
  "APRS: 7 records", and its link opens the APRS page.
- [x] **DA-12 A recipe gain in dB.** `GainPolicy` gains `GAIN_FIXED` and `DecoderRecipe.gain_db`
  (additive), applied when the job creates or retunes the capture, never on a capture it borrows
  (that gain is its owner's). `DecodeConfig` gains the `GainWrite` that `ScanConfig` has, so `ley
  decode --gain` overrides the recipe. ADS-B's recipe is 40 dB: at gain 30 the owner's 1090 MHz
  air decoded nothing and at 40 it decoded 19 frames (2026-11-02).
  Done 2026-11-02, unverified on the owner's radio. Calls the plan left open: `DecodeConfig` has
  `gains` beside `gain`, as `RecordConfig` and `ScanConfig` do, so `--gain LNA=0,VGA=20` works;
  a retuned capture's gain comes back when the job ends (an IQ one only when no other IQ job still
  reads it); a gain the config sent that the radio refuses fails the job, as a recording's does,
  while a recipe's is skipped on a radio with no gain stage (a file radio, so no check scene's
  detail moves). `GAIN_AUTO` still sets nothing, and `list_entities` and `ley track` take no gain.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1102 checked, all ok), no detail
  moved; the 40 dB on the owner's 1090 MHz air is still to be seen on the real radio.

### Batch 3 follow-ups (from the verify run's pictures, 2026-11-02)

- [x] **DA-18 Fields have labels.** `FieldHint.label` (additive): a short name a person reads
  ("Transmitter", "Callsign", "County", "Ground speed"). Manifests fill it; the watch sheet's
  field pop-up, the condition in words, the inspector's field rows and `ley track`'s column heads
  use it, falling back to the field name. The promoted `device_id` reads "Transmitter".
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1114 checked, all ok); the sheet, the sidebar's
  watch line and the table heads read Transmitter, and `TestColumnHeadVectors` and
  `TestWatchBannerUsesFieldLabels` pin `ley track` and `ley watch`.
- [x] **DA-19 The watch sheet's default button.** Start Watching is the default action (Return,
  the accent style), Cancel is not.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1114 checked, all ok). The filled button kept the
  action of the render that enabled it, so Return watched for `N`, not `N0CALL-3` (6bd1def).
- [x] **DA-20 "Decoded" is a labelled row** in the recording's inspector, one line per decoder
  ("APRS · 7 records", a link), not a coloured footnote between Files and Decode With.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1114 checked, all ok); `library-decode-with`
  shows Decoded under Files in the grid.
- [x] **DA-21 The waterfall fills in what it missed.** When tags start (the Radio shows, a job
  runs), the last minute of records is read with `QueryRecords` and tagged on their rows, so a
  packet decoded before the window subscribed still has its name. The Radio sidebar's count comes
  from the records the window holds when it holds them, not the 2 s job detail.
  Verified 2026-11-02 by a full `make app-check JOBS=3` (1114 checked, all ok) with `radio-decoding`;
  `WaterfallTagsTests` covers the read-back.
- [x] **DA-22 Declines are reported everywhere.** The MCP `watch` and `start_decode_job` tools
  wait briefly for the daemon to take the job, as `ley watch --detach` now does, and return the
  reason when it declines.
  Verified 2026-11-02 by `TestMCPDecodeToolsReportADecline` (Go only).
- [x] **DA-23 `ley --socket` takes a relative path.** A relative socket path is resolved against
  the working directory before it is dialled; today a live daemon's socket named relatively is
  reported stale.
  Verified 2026-11-02 by `TestDialResolvesARelativeSocket` and `TestRelativeSocketReachesTheDaemon`
  (Go only).

- [x] **DA-24 Leftovers from the last verify run.** The decoder inspector's FIELDS values start at
  another x than the grid above them; the watch sheet's operator pop-up is wider than its words;
  `pointer-and-menus` once retuned to the view's edge (147.84 MHz, OFFSET_OUT_OF_CAPTURE) right
  after its click, and did not again in three runs: cause not found.
  Done 2026-11-03: one 124 pt label column for the inspector's grids; the operator pop-up was
  already sized to `contains` (99 pt for `is` and `contains`, as its golden), so it is unchanged;
  the edge retune did not recur in 10 runs, but a click mapping to the edge of a file radio's
  capture reproduces it, so such a click now stops inside the edge and charts map a click
  against their width at the event (cause of the stray edge mapping unconfirmed).

## After this

DTMF and selective calling (provable with the owner's HT), an `rtl_433` adapter on DEC-19's
shared captures, digital-voice metadata (DMR, C4FM, D-STAR headers, no vocoder:
`../design/decoders.md` section 10) and FT8 on DEC-12, in that order. Each is then a decoder and a
manifest, with no app work.

## Future work (flagged 2026-11-03, not scheduled)

- **Who a transmitter is.** `../design/decoders.md` reserves `lookup_identity` ("external identity
  adapters"); this is the shape agreed for it. A client-side identity source keyed by protocol and
  `device_id`, shown beside the address in the inspector, the table's name column, `ley track` and
  the MCP tools, with a person's own label still first. In three steps:
  1. Offline, no data: the country of registration from the ICAO 24-bit address block, the US
     N-number from an address in A00001--ADF7C7 by the published algorithm, and an MMSI's flag
     state from its first digits.
  2. A registry file published by leysdr.com: a scheduled build reduces the FAA Releasable Aircraft
     Database (public domain; other registries only where their licence allows) to `icao ->
     registration, type, model`, and the app downloads the whole signed file as it does the
     appcast, so no lookup ever tells a server which aircraft this Mac hears. Make, model and type
     only: the FAA file names owners, and a private aircraft's owner is a person.
  3. Callsign to route needs a live service that learns what is heard; opt-in, or not at all.
- **Map tiles in the app.** The Decoders map is MapKit, but no check has ever seen its tiles (staged
  runs draw a plain projection), and the owner wants a real basemap under the markers. Find out
  what the signed, hardened app shows today, then decide between MapKit as it is, an offline
  tile set, or another source, minding tile licences and what a tile request reveals about the
  Mac's location.
