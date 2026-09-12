# Design: Decoders

Status: draft, being implemented (Milestone D.17, `docs/plans/decoders.md`). Companion to
`control-plane.md`, `data-planes.md` and `semantic-tier.md`; this doc assumes their vocabulary
(capture, channel, sink, job, resource, telemetry plane) and their invariants. The requirements are
the first half; the second half, "Decisions", records what the first build chose where the
requirements left a choice, and what it left for later.

Scope: turning demodulated signal into typed records, and exposing those records to `ley`, the
dashboard and agents. Covers the plugin contract, the record model, the state boundary,
predicates and the surfaces. Does not cover TX, encrypted traffic, or any one protocol's DSP.

## 1. Why this exists

Audio is opaque to an agent; a stream of typed records is not. The decoder tier is what makes
Leyline queryable: "which aircraft passed overnight", "has the greenhouse sensor reported since
Tuesday", "did a weather alert fire for my county". Detections answered *something is
transmitting*. Records answer *here is what it said*.

## 2. Design drivers

Five reference use cases, chosen for maximum spread. Every interface decision below traces to at
least one; implementations must satisfy all five. A to C were the original pressure-test set; D and
E were added later, and D is the first build.

**A. ADS-B (1090 MHz).** High rate (hundreds of messages a second), fragmentary. A position message
carries no callsign; a callsign message carries no altitude; CPR position decoding pairs even and
odd frames. Useful output is a live table of aircraft entities, not a message firehose. Spatial and
temporal queries ("within 10 nm", "below 5000 ft"). Runs continuously on a dedicated capture.

**B. 433 MHz sensor soup.** Sparse, heterogeneous, unknown cardinality. Dozens of protocols in one
wide capture; transmitters appear on their own schedule (a TPMS sensor when the car moves, a soil
probe every five minutes, a doorbell once a week). Payload fields differ per protocol, so no fixed
schema is possible. Value comes from a person labelling a discovered device id ("that's the
greenhouse") and from noticing absence ("which sensors went quiet").

**C. SAME/EAS (NOAA weather radio).** Rare, critical, geography-gated. Silent 99.9% of the time; a
burst of AFSK header tones carries an event code, FIPS county codes and a duration. Nothing to
aggregate or discover, but it must fire reliably with no client connected, and it only matters if
the FIPS codes include the user's county. The alert is valid for a bounded window, not merely
stamped with a time.

**D. APRS (144.39 MHz).** AX.25 packet over 1200 baud AFSK. No timing subtleties, no aggregation
state machine: NFM audio in, position, weather and telemetry records out. Callsign-SSID is the
`device_id`, positions fill the promoted `position` field, and the entity and registry shapes
defined for A and B apply unchanged. Mature GPL decoders exist (Direwolf, multimon-ng). Included
because it exercises the contract end to end with no new concepts, which is why it is built first.

**E. FT8 (HF; the WSPR/FT4/JS8 family).** Slot-synchronised weak-signal digital. Breaks an
assumption the other drivers share: FT8 is aligned to 15-second UTC slots, and the decoder needs a
complete slot of audio aligned to wall clock before it can produce anything. This is the only
driver that makes `CaptureAnchor` accuracy load-bearing: sample-indexed time is still the record
timebase, but the anchor must be good enough to cut slots correctly. One 2.5 kHz channel yields
dozens of records per slot, each with callsign, grid locator and SNR, so records are inherently
geographic and `validity` windows apply. The implementation is a slot-buffering wrapper around an
existing decoder (`ft8_lib`, MIT, is the cleanest target; WSJT-X and `ft8mon` are GPL
alternatives).

Contract consequence of E: the plugin manifest gains an input mode, continuous (the default) or
slot-aligned with slot length and epoch alignment. The daemon buffers and delivers aligned windows
rather than a continuous stream. The field exists from the first build; the buffering arrives with
FT8, and FT4, WSPR and JS8 share it.

Together these force: multiple output shapes, open payloads, daemon-side predicates, notification
as a delivery path, and two plugin input modes. A single use case would have revealed none of that.

## 3. The state boundary

**Decode state lives in the decoder. Interpretation state lives in the client library. The daemon
is a radio, not a database with a radio attached.**

- **Decode state** is whatever is required to emit a correct record at all: CPR even/odd pairing,
  fragment reassembly, CRC checks, dedupe windows. A late-subscribing client can never reconstruct
  it. It belongs inside the decoder plugin, daemon-hosted, which is consistent with the existing
  rule that the engine computes signal truth.
- **Interpretation state** is everything else: aircraft entity tables, trails, sensor registries,
  user labels, first and last seen, "gone quiet" detection. All of it is a deterministic fold over
  the record log. It belongs in the shared Go client library used by `ley`, the dashboard and the
  MCP adapter. Every client derives the same picture from the same stream; consistency comes from
  determinism, not from a central authority.

Durability is already solved in principle: a decode **job** persists its records as a resource, so
the log survives restarts. The fold over that log does not need to be running for the history to
exist.

The one carve-out: predicates that genuinely require track history ("alert when an aircraft
descends below 3000 ft" needs a prior altitude) may use a plugin-declared aggregator hosted in the
daemon, but only when a job explicitly asks for a stateful predicate. Opt-in and per job. The
daemon never keeps entity tables by default. "Just cache the aircraft table in the daemon, it is
simpler" is the wrong answer and is rejected in review; if a feature seems to need it, the fix is
a client-side fold or an explicit stateful-predicate job.

## 4. Record model

One envelope for all protocols. Common fields are promoted; everything else is decoder-defined.

Promoted fields (present or empty, never invented):

- `record_id`, `protocol` (the registry name: `adsb`, `rtl433`, `same`, `aprs`)
- `time`, a `SampleTime`, per the timebase invariant
- `device_id`, the transmitter's identity as the protocol defines it (ICAO hex,
  `Acurite-Tower/2937`, MMSI, `N0CALL-9`). Empty when the protocol has no identity concept.
- `position`: latitude, longitude and altitude when the protocol carries one
- `rssi_dbfs`, `snr_db`, measured by the engine, never by the plugin
- `validity`, start and end when the record's meaning expires (SAME alerts, NOTAMs). Absent for
  instantaneous observations.
- `fields`, an open key-value map, decoder-defined, typed values
- `raw`, the original payload bytes, always retained

Rules:

- Plugins declare their `fields` schema hints in their manifest (name, type, unit) for display and
  query planning. Hints are advisory; unknown fields still pass through.
- Records are immutable. Corrections are new records, never edits.
- `raw` is always kept, because reprocessing with a better decoder later is a requirement.

## 5. Output shapes

Plugins declare which they produce:

1. **Records**: every plugin. The base stream.
2. **Entities**: plugin-supplied aggregation over its own records (ADS-B aircraft). Runs
   client-side by default, daemon-side only under a stateful-predicate job. Entities have a
   lifecycle: created, updated, aged out after a plugin-declared silence timeout.
3. **Registry devices**: discovered transmitters with stable ids (433 sensors). Persistent,
   user-labellable, with first seen, last seen and an observation count. Derived from the record
   log; labels are user data and persist in the client-side store.

SAME produces only records, plus `validity`. That is the common case: most protocols declare
records only.

## 6. Plugin contract

Out of process, one process per running decoder. Crash isolation is one reason; the other is that
mature GPL C tools (`rtl_433`, `dump1090`, `dumpvdl2`, `multimon-ng`, `direwolf`) can then be
wrapped as first-class citizens rather than reimplemented. The engine is GPL, so linkage is not
the constraint; a separate process is.

### Manifest (static, shipped with the plugin)

- identity: `name`, `version`, `description`, upstream attribution and licence
- **recipe**: the tuning the decoder needs, a centre frequency or frequency list, sample rate,
  bandwidth, demod mode, gain policy. This is what makes `ley decode aprs` need no parameters.
- **input mode**: `continuous` (the default) or `slot_aligned` with slot length and epoch
  alignment. Slot-aligned plugins receive complete aligned windows rather than a stream; the
  daemon does the buffering and cutting. Required by FT8, FT4, WSPR and JS8 (driver E).
- declared output shapes (records, entities, registry) and the silence timeout for entities
- `fields` schema hints
- capability flags: `supports_multi_channel`, `needs_dedicated_capture`,
  `stateful_predicates_available`

### Runtime

- The daemon creates the capture and channel the recipe asks for, spawns the plugin process, and
  streams demodulated input to it over the bulk plane's own frame contract.
- The plugin emits framed records back. Framing is length-prefixed protobuf, the same contract
  discipline as everywhere else.
- Plugin crash: the daemon restarts it with backoff, logs a gap in the job's coverage record, and
  never takes the daemon down. Honest gaps, per the transcript precedent.
- Plugins never touch hardware, never retune, and never see the control plane. They receive
  samples and emit records.
- Wrapped third-party binaries run behind a thin adapter that translates their native output into
  the record envelope. The adapter is the plugin; the binary is an implementation detail of it.

### Multiplexing

One wide capture must support many decoders in parallel: twenty `rtl_433` protocol decoders across
433 MHz, or ADS-B beside UAT if bandwidth allows. This falls out of the capture-to-channels model;
there is no second mechanism.

## 7. Predicates and delivery

Predicates are daemon-side filters evaluated on records before delivery. Required because a trigger
must work with no client connected (driver C).

- **Stateless predicates** (the default, and enough for SAME): field matches, set membership,
  numeric comparison, geographic containment on `position`. Evaluated per record.
- **Stateful predicates**: opt-in per job, backed by a plugin-declared aggregator. Only where
  history is genuinely required.

Delivery adds a **notification sink** beside the existing sink kinds (`system-audio`, `stream`,
`file`). Targets: a macOS user notification, a webhook, a shell hook. A triggered alert is a
channel output going somewhere, and "somewhere" is now also a notifier. There is no parallel
delivery path.

## 8. Record store

Records land in the resource store, indexed for query:

- by protocol, time range and `device_id`
- by field values, using the schema hints for typing
- spatially where `position` is present: ADS-B needs "within N nm of a point", so a geographic
  filter is required
- validity-aware: "alerts currently in effect"

A retention policy is required before this ships, because records accumulate faster than
recordings: a size cap plus an age, user-visible, consistent with the store retention question
the semantic-tier doc left open.

## 9. Surfaces

### `ley`

```
ley decoders                                # the registry: installed plugins, recipes, output shapes
ley decode <name> [--json] [--job]          # recipe-driven; --job keeps the records as a resource
ley decode 433 --auto                       # every protocol the plugin recognises
ley identify <freq>                         # characterise an unknown signal (see below)
ley track aircraft | vessels | aprs         # live entity table, a client-side fold
ley devices-seen [--protocol 433] [--quiet-since 48h]
ley label <device-id> <name>
ley records query --protocol adsb --since 1h [--near me --radius 10nm]
ley watch same --county 06009 --notify      # predicate + notification sink, as a job
```

`--json` everywhere, the standard proto3 JSON mapping, as with every other verb.

### MCP

Four families, all reading from the record store rather than streaming packets:

1. **`query_records`**: semantic queries over the store by protocol, time range, field filters,
   spatial bounds and validity. The highest-value tool; agents are good at it.
2. **`identify_signal`**: measured characteristics (bandwidth, burst timing, symbol rate estimate,
   spectral shape, modulation guess with confidence) plus a snapshot image. The agent reasons
   toward a candidate protocol and proposes a decoder. It must not overclaim: the honest-detector
   invariant applies.
3. **Enrichment**: `lookup_identity` mapping ICAO hex to registration and type, MMSI to vessel,
   callsign to licence, `device_id` to user label. External lookups happen adapter-side, never in
   the daemon.
4. **`start_decode_job`**: durable monitoring with a predicate, on the existing job machinery. The
   agent supplies the meaning of "interesting"; the daemon supplies durability.

The composite tool, built deliberately: **`whats_out_there`** sweeps a range, detects,
characterises, tries matching decoders and returns a labelled inventory. It is a new capability
rather than a wrapper, and the demonstration that sells the project.

## 10. Constraints and boundaries

- **Decode only what is in the clear.** No decryption of protected traffic. Plugins that would
  require breaking encryption are out of scope however they are framed.
- **Digital voice audio is deliberately not implemented.** C4FM (Yaesu System Fusion), DMR, D-STAR
  and P25 voice all need the AMBE/AMBE+2 vocoder, which is patented and proprietary; the open
  reimplementations (mbelib and the DSD family) sit in an unresolved rights position. A project
  publishing under a clear licence with a registered mark does not ship a vocoder of uncertain
  provenance. This is a non-goal, not a backlog item.
  - In scope: the unencrypted *metadata* in those same protocols. C4FM, DMR and D-STAR frame
    headers carry source and destination ids, talkgroup and radio id, none of which need a
    vocoder. "Who is transmitting on this repeater" is a clean, useful record stream.
  - Voice decoding may exist as a third-party plugin someone else ships. The out-of-process
    contract exists partly so that choice is theirs.
  - **M17** is welcome: it was designed around Codec2 (LGPL) and has an open specification.
- **Export deliberately.** The record store's export and share paths are where divulgence rules
  bite. The export path is designed once, early; share affordances are not scattered across
  surfaces.
- **TX interlock, written before TX code exists.** Decoding and displaying is observation;
  replaying is access-control bypass. Access-control and rolling-code protocols (garage and gate
  remotes, car fobs, alarm sensors) are never transmittable. This belongs in the emission-lease
  design as a hard rule, not as a warning in a doc.

## 11. Acceptance

The tier is done when all five drivers work end to end:

- **A:** `ley track aircraft` shows a live, correctly merged aircraft table from a continuous
  capture; `ley records query --protocol adsb --near me --radius 10nm --since 1h` returns
  spatially filtered history; the daemon holds no aircraft table.
- **B:** `ley decode 433 --auto` discovers heterogeneous devices across one wide capture;
  `ley label` persists; `ley devices-seen --quiet-since 48h` correctly reports absence.
- **C:** `ley watch same --county 06009 --notify` fires a macOS notification for a matching FIPS
  code with no client attached, ignores non-matching counties, and the record carries a validity
  window.
- **D:** `ley decode aprs` produces position, weather and telemetry records from 144.39 MHz with
  correct callsign-SSID identity; `ley track aprs` shows a live station table from the client-side
  fold.
- **E:** `ley decode ft8` produces several records per 15-second slot with callsign, grid and SNR;
  slots are cut correctly against the capture anchor across a multi-hour run with no
  drift-induced misalignment.

Plus: a decoder plugin crash restarts cleanly, logs a coverage gap, and leaves the daemon and the
other decoders running.

## 12. Open items

- Whether `identify_signal` characteristics should also persist as a resource (leaning yes, under
  persistence-follows-intent: only when job-initiated).
- P25 trunking is the known stress case and is deliberately deferred: its control channel must
  *steer the receiver*, inverting the dataflow this contract assumes. Not designed for now, and
  not foreclosed: a future `SteeringDecoder` concept would need the control-plane access ordinary
  plugins are denied.

## Decisions

What the first build (D.17, driver D) chose. Each is additive on the wire and can be revisited
without a schema change unless it says otherwise.

**Transport: stdio.** The daemon spawns the plugin and writes to its stdin one varint-delimited
`StreamDescriptor` followed by varint-delimited `Frame`s, the bulk plane's own messages, so a
plugin reads exactly what a `Bulk.Stream` client reads. Audio is `F32` mono at the channel's rate,
`GAP_MARKED`, from the tap the manifest names (`TAP_AUDIO` unless it asks for `TAP_DEMOD`). The
plugin writes varint-delimited `DecodeRecord`s to stdout and prose to stderr, which the daemon
logs under the plugin's name. Varint delimiting is protobuf's own "delimited" convention
(`protodelim` in Go, `BinaryDelimited` in swift-protobuf), so no client library has to know a
framing of ours. A socket was the alternative; it buys nothing for a child process the daemon
already owns and costs every plugin author a connect step.

**Manifest: a file, not a flag.** A plugin is a directory holding `manifest.json`, the proto3 JSON
form of `DecoderManifest`, whose `executable` names a binary relative to that directory or on
`PATH`. Discovery reads files and executes nothing, so a broken plugin cannot break `ley decoders`.
The daemon looks in every directory named by `--decoders` (repeatable; `LEYLINE_DECODERS`,
colon-separated) and then its platform default (`~/Library/Application Support/Leyline/decoders`
on macOS, `$XDG_DATA_HOME/leyline/decoders` elsewhere). `decoders/` in the repository holds the
first-party manifests, and `make go` builds their binaries beside `ley`.

**A decode job is a job.** `Jobs.StartJob(DecodeConfig)` runs the recipe: the allocator finds or
makes a capture (a capture that already covers the frequency on any device, else an idle device,
else a capture nobody is using by the don't-disturb test, else it declines naming who has the
radio unless `take_over`), adds a persistent channel the job owns with `required_hz` set, attaches
the plugin as a sink, and spawns the process. This is the first use of
`AllocationRequest.channel`, which watch jobs (D.15) will share. A channel that goes
`OUT_OF_CAPTURE` puts the job in `DEGRADED` with a coverage gap; the daemon rebuilds it when the
capture returns and the job goes back to `RUNNING`. Without `keep`, a decode job is ephemeral in
exactly the way a scan is: it belongs to the client that started it and its records are the live
stream and nothing else. With `keep`, the job outlives its client and its records are the
resource `ley://records/<job_id>`. A kept job does not yet survive a daemon restart, because no
job survives one; its records do.

**Records reach clients on their own service.** `Decoders.SubscribeRecords` is the live stream,
scoped to everything, one job or one protocol, drop-oldest with a `seq` per job and a retained
window of 256 records replayable with `since_seq`, so "start the job, then subscribe" misses
nothing. `Decoders.QueryRecords` reads the store. Neither is telemetry: a meter reading is a
sample of a level and a record is a thing that was said, and a client wanting one rarely wants
the other.

**The daemon measures `rssi_dbfs` and `snr_db`.** When a record arrives the daemon stamps it with
the channel meter's latest power and SNR. A meter reading is 100 ms old at worst and a packet is
longer than that; a plugin claiming a level of its own would be measuring after the limiter.

**The store is files.** A kept job's records go to `<store>/records/<job_id>.records`, varint-
delimited `DecodeRecord`s appended as they arrive, beside `<job_id>.json` with the job's config,
the decoder's name and version, and every `CaptureAnchor` that was in force while it ran. The
store directory is `~/Library/Application Support/Leyline/store` on macOS and
`$XDG_DATA_HOME/leyline/store` elsewhere (`--store` overrides). A query scans the files that
match its protocol and time range and filters in memory; there is no index yet, and there will be
a SQLite one when a query is measured to be slow, not before. Wall-clock filters are answered by
the sidecar's anchors, and a `RecordPage` carries those anchors so a client derives wall time from
sample time exactly as it does everywhere else; no record carries a clock of its own.

**Retention: a size cap and an age.** `--store-cap` (default 2 GiB) and `--store-age` (default 90
days): at daemon start and whenever a kept job starts, record files older than the age go, then
the oldest go until the store fits. `ley decoders` prints both numbers.

**Entities are a fold in `go/pkg/records`.** The generic fold keys on `device_id`, keeps the
newest value of every field, the newest position, first and last seen and a count, and ages an
entity out after the manifest's silence timeout. It is what `ley track aprs` renders, and what
`ley track aircraft` will render once ADS-B's plugin carries its decode state (CPR pairing) on the
daemon side of the boundary.

**APRS is decoded in Go, in this repository.** `leydec-aprs` is an AFSK 1200 demodulator, HDLC
deframer, AX.25 parser and APRS parser written for the plugin contract, rather than an adapter
around Direwolf or multimon-ng. It costs a user no Homebrew formula, it runs in the Linux
container where the contract's tests live, and a synthetic AFSK fixture round-trips through the
whole pipeline in the engine test suite. Direwolf decodes weak packets this one will miss; a
Direwolf adapter is a second plugin, not a replacement, and the contract exists so both can sit
side by side.

**Deferred, and where.** Predicates and the notification sink (driver C), the registry fold and
`ley label` / `ley devices-seen` (driver B), slot-aligned input (driver E), the MCP families,
`ley identify`, and daemon-restart respawn of kept jobs are the later items of
`docs/plans/decoders.md`; the manifest fields that carry them exist now so a plugin written today
declares them.

The reference for writing one is [`docs/reference/writing-a-decoder.md`](../reference/writing-a-decoder.md).
