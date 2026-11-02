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

- [ ] **DA-9** A "decoding" line in the radio window, and decoded callsigns marked at their
  frequency on the waterfall (user stories, the line on decoded traffic).
- [ ] **DA-10** Watches from the app: "notify me when" on a decoder's page, a predicate and the
  macOS notifier the daemon already has; SAME by county first.
- [ ] **DA-11** Decode a recording from the Library with any decoder whose input matches it, on
  the path transcription uses.
- [ ] **DA-12** A recipe gain in dB. At gain 30 the owner's 1090 MHz air decoded nothing and at
  40 it decoded 19 frames; `GainPolicy` can only leave or ask for AGC.

## After this

DTMF and selective calling (provable with the owner's HT), an `rtl_433` adapter on DEC-19's
shared captures, digital-voice metadata (DMR, C4FM, D-STAR headers, no vocoder:
`../design/decoders.md` section 10) and FT8 on DEC-12, in that order. Each is then a decoder and a
manifest, with no app work.
