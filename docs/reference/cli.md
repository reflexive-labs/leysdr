# `ley` reference

The command tree, input conventions, every `--json` shape and the exit status of `ley`, the
reference client of the `leyline.v1` contract. It is organised for lookup; the task-by-task walk is
[Using `ley`](../guide/using-ley.md), and `ley help <verb|topic>` carries the same facts at the
prompt. `--json` output is the standard proto3 JSON mapping of the protos; the exceptions are
listed here and nowhere else. A program that speaks the contract without going through `ley`
starts at [Writing a client](clients.md); an agent drives the daemon through `ley mcp`, whose tools are
the [MCP adapter reference](mcp.md).

## CLI tree

```
ley                                  # bare: orientation screen on a TTY (see below); the verb list when piped
├── tune <freq|preset> [--mode M] [--bw N] [--squelch L|auto|off] [--volume V] [--gain dB|auto|STAGE=dB,...] [--rate N] [--device SEL] [--persistent] [--no-audio] [--retune]
│                                    # capture+channel+system-audio sink in one verb; prints every decision it made;
│                                    # refuses to retune a capture other active channels ride on unless --retune
├── set [param value] [--channel SEL] [--capture SEL] [--element E]
│                                    # live adjust: freq (frequency), mode, bw (filter), squelch, gain, volume (streams WriteParams); no args = show
├── stop [channel|all] [--all] [--device SEL]
│                                    # DestroyChannel for one channel (set's target rule); all/--all destroys every channel and the capture, freeing the radio
├── spectrum [freq] [--span N] [--bins N] [--watch] [--rate N] [--count N] [--device SEL] [--width N] [--retune]
│                                    # one FFT row drawn as a bar chart + the loudest bins (>= floor + 15 dB, else "nothing above the floor"); the human view of fft
├── waterfall [frequency] [--span N] [--band NAME] [--bins N] [--rate N] [--count N] [--device SEL] [--retune] [--width N]
│                                    # scrolling history of FFT rows as a terminal heatmap; a band plan covers the whole band, not one frequency
├── phosphor [frequency] [--span N] [--band NAME] [--bins N] [--levels N] [--half-life S] [--rate N] [--count N] [--device SEL] [--retune] [--width N]
│                                    # per-bin amplitude histogram decayed over time, the "which bins are ever busy" view
├── scope <freq|preset|chan_ID> [--tap audio|demod] [--window MS] [--trigger auto|free] [--scale auto|full|N] [--rate N] [--count N] [--mode M] [--bw N] [--squelch L] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--retune] [--width N]
│                                    # the demodulated waveform, one window a frame, as a braille trace (three ASCII
│                                    # levels with --ascii); --tap demod draws the detector's own output, where an
│                                    # NFM channel still carries its CTCSS tone and its tuning error; --scale auto,
│                                    # the default, fits the trace to the signal; --scale full is the tap's whole range
├── levels <freq|preset|chan_ID> [--tap audio|demod] [--bands octave|third] [--watch] [--rate N] [--count N] [--mode M] [--bw N] [--squelch L] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--retune] [--width N] [--height N]
│                                    # the rack unit's band meter over the daemon's audio spectrum: one LED ladder
│                                    # per octave band, and the meter's rms/peak pair at the right; one still by
│                                    # default and the live meter (caps, ballistics, --rate, --count) under --watch,
│                                    # as spectrum does; the ladders draw unlit while the squelch is shut;
│                                    # --tap demod is where a CTCSS tone still stands in the 125 Hz band
├── waveform <freq|preset|chan_ID> [--tap audio|demod] [--seconds S] [--scale auto|full|N] [--rate N] [--count N] [--mode M] [--bw N] [--squelch L] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--retune] [--width N]
│                                    # the clip view: seconds of audio as a peak envelope about the centre, newest
│                                    # at the right, blank where the squelch was shut
├── fft [--freq F] [--bins N] [--rate N] [--count N] [--format json|bin] [--u8] [--device SEL]
├── listen <freq|preset|chan_ID> [--format json|bin] [--count N] [--mode M] [--bw N] [--squelch L] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--rate N] [--retune]
│                                    # the channel's decoded audio on stdout (SubscribeAudio), no system-audio sink; a channel id taps one already running
├── scan <lo>..<hi | band> [--band NAME] [--dwell MS] [--min-snr DB] [--sort freq|snr] [--gain dB|auto] [--take-over] [--device SEL]
│                                    # a band name works in place of a range: `ley scan gmrs`, `ley scan 2m`
│                                    # daemon-side sweep: Jobs.StartJob(ScanConfig{once}); detections stream on
│                                    # telemetry, the aggregate comes from Jobs.GetScan
├── monitor <band|range> [--for D] [--min-snr DB] [--min-hold D] [--skirt-db DB] [--take-over] [--device SEL]
│                                    # scan's stationary sibling: parks one capture on a band for --for and prints a
│                                    # time-ordered transmission log; Jobs.StartJob(MonitorConfig), detections on telemetry
├── decoders                         # the installed decoder plugins: name, recipe, output shapes, version
├── decode <decoder> [--freq F] [--device SEL] [--take-over] [--job] [--count N]
│                                    # Jobs.StartJob(DecodeConfig): the daemon finds or makes the capture,
│                                    # adds the channel the job owns and spawns the plugin; records arrive
│                                    # on Decoders.SubscribeRecords, one line each; --job keeps them as
│                                    # the resource ley://records/<job_id>
├── records [--protocol P] [--job-id ID] [--device-id ID] [--kind K] [--since 1h] [--near LAT,LON --radius 10km] [--in-effect] [--limit N]
│                                    # Decoders.QueryRecords over what kept jobs wrote, newest first
├── watch <decoder> [--where field=value] [--county FIPS] [--near LAT,LON --radius R] [--notify[=TARGET]] [--freq F] [--device SEL] [--take-over] [--detach|--job] [--count N]
│                                    # a decode job with a daemon-side predicate and a notifier:
│                                    # attached it streams only the matching records; --detach leaves
│                                    # the job running so the notifier (bare=macOS, webhook:URL,
│                                    # shell:CMD) fires with no client attached
├── track <protocol> [--attach] [--device SEL] [--take-over] [--since D] [--rate N] [--count N]
│                                    # starts (or attaches to) a decoder and folds its records into a live per-station table; --attach only folds one already running
│                                    # the live entity table: ley's own fold over SubscribeRecords,
│                                    # redrawn in place, rows aged out after the decoder's entity_silence_s
├── devices-seen [--protocol P] [--since D] [--quiet-since D]
│                                    # the registry: one row per transmitter the kept records heard,
│                                    # a client-side fold over QueryRecords joined with the labels
│                                    # store; --quiet-since D shows only those silent longer than D
├── label <device-id> [name] [--clear]
│                                    # name a transmitter (or read/clear its name); labels are user
│                                    # data in a client-side JSON store ($LEYLINE_LABELS), not daemon state
├── presets | bands                  # the client-local tables (no RPC); `ley help presets` is the same data in prose
├── bookmarks [add <freq|preset> --name NAME [--mode M] [--bw N] | move <id|name> <freq|preset> | remove <id|name>]
│                                    # the third client-local table and the only one you write: the
│                                    # frequencies you kept, in a JSON file ($LEYLINE_BOOKMARKS) the
│                                    # Mac app reads too, so one kept from a terminal is in its sidebar
├── mcp                              # the MCP server for an agent, on stdin and stdout: every tool a verb seen from
│                                    # an agent, returning the verb's --json shape (docs/reference/mcp.md); refuses --json
├── record <freq|preset|chan_ID> [--iq] [--for D] [--gate squelch] [--pre D] [--hang D] [--stop-after-quiet D] [--part D] [--listen] [--detach] [--mode M] [--bw N] [--squelch L|auto|off] [--gain dB|auto|STAGE=dB,...] [--device SEL] [--take-over]
│                                    # Jobs.StartJob(RecordConfig): the daemon finds or makes the capture and
│                                    # writes WAV (or .cf32 with --iq) into its store; the job's id is the
│                                    # recording's, and ley://recordings/<job_id> is on stdout when it ends
├── recordings [--kind audio|iq] [--freq F] [--since D] [--limit N]
│   ├── show <id>                    # the manifest: the radio, the parts, the coverage gaps, how it ended
│   └── path <id> [--part N]         # where it is on this machine, for Finder or another tool
│                                    # Resources.ListResources / GetResource / ResolveLocalPath
├── play <file.cf32 | job_ID | ley://recordings/ID[/PART]> [--part N] [--freq F] [--mode M] [--bw N] [--squelch L] [--volume V] [--gain dB|auto|STAGE=dB,...] [--loop] [--persistent] [--no-audio]
│                                    # FilePlaybackDevice through the same pipeline; a recording's id or URI
│                                    # is resolved to its part file first. An audio part holds what a
│                                    # demodulator already produced, so there is nothing left to tune: play
│                                    # hands it to the machine's own player ($LEYLINE_PLAYER, else open)
├── devices [--watch] | devices attach rtltcp <host:port> | devices detach <SEL>
│                                    # attach adds a radio another machine serves with rtl_tcp and the daemon
│                                    # remembers it across restarts; detach removes any device a client attached
├── state                            # GetState snapshot, the debugging entry point
├── daemon [install|uninstall|start|stop|status|logs]
├── version
├── help [command|topic]             # topics: squelch, frequencies, modes, gain, presets, glossary, scripting, roadmap
└── (planned) transcript             # arrives with the durable job store (Milestone D.15)
```

Global flags: `--json` on every verb (answered, or refused with exit 2 where there is no machine form); `--socket PATH` (default the user daemon's UDS, `$LEYLINE_SOCKET`); `--color never|always|auto` and `--ascii`, which override the colour and glyph detection described in `docs/dev/cli-style.md`. Styling never reaches `--json`, the bulk row streams or `--format bin`.

**Input conventions** (`go/pkg/leyline`, shared by every verb): a bare frequency number is MHz
(`146.52`, `1010`); units `k`, `M`, `G`, `Hz`, `e6` are exact; commas are refused with a hint.
Squelch levels are dBFS (`-40`, `-40dB`, `off`, `auto`); a positive number is an error that
explains the scale. Bandwidth: a bare number is kHz. Volume: `0..1` or `50%`. Modes by alias
(`fm` → WFM on 87.5–108 MHz else NFM; `ssb` → USB at and above 10 MHz else LSB). **Selectors**:
`--channel`, `--capture`, `--device` and `devices detach` accept a full id, an id prefix, the
1-based row number from the printed list, or a frequency. **Presets** (`noaa`, `noaa1..7`,
`calling`, `marine16`, `guard`, and the 22 GMRS channels by number `ch1..ch22` -- the repeater
outputs `ch15..ch22` also answer to their repeater-slot names `rpt1..rpt8`, the
channel-numbered `15rp..22rp`, and Baofeng's `ch23..ch30` -- every label a radio might print for
the same channel) and **bands**
(name, default mode, default bandwidth; GMRS is two bands 5 MHz apart, `gmrs-462` for channels 1 to
7 and 15 to 22 with the repeater outputs and `gmrs-467` for channels 8 to 14 with the repeater
inputs, plus the group `gmrs` spanning both, which `scan` sweeps whole and a picture or a watch
refuses with the halves named unless the radio captures 5.2 MHz at once) are pure client-side tables, rendered as tables by `ley presets` and `ley bands` and in
prose by `ley help presets`; resolution is number/unit form first, then preset name, never probing. These are presentation over the same RPCs: the CLI
adds no capability the protocol lacks.

**`--json`** is the canonical proto3 JSON mapping (lowerCamelCase keys, e.g. `captureId`,
`centerHz`; 64-bit integers as strings; NDJSON for streams). Everything meant for a person goes
to stderr, so stdout is parseable. Every verb either answers the flag or refuses it: a verb whose
output is a shell script, a file or a launchd action — `ley help`, `ley completion` (and its shells),
`ley daemon install|uninstall|logs`, and `ley mcp`, whose stdout is the MCP conversation — exits 2 with `<verb> has no --json output; drop the flag
(<what to run instead>)`. None ignores it, because a flag that silently does nothing hands a
pipeline unparseable text and exit 0. **Eight documented exceptions.** The first sits beside the
shm-ring bypass in the design docs: bulk rows have no proto message, so `ley fft --format json`
and `ley spectrum --json` emit `{seq, sample_index, center_hz, span_hz, bins, floor_db}` (snake_case,
numbers as numbers), spectrum adding `peaks: [{center_hz, db}]` — the N loudest local maxima of the row,
presentation only, never called signals. `ley waterfall --json` is the same row plus `looks`, the
number of looks the daemon folded into it, since the view negotiates ROW_MAX accumulation and a row
cannot be interpreted without it; the map is drawn only when the flag is absent. `ley phosphor
--json` is the
histogram member: one object per frame, `{seq, sample_index, center_hz, span_hz, bins, levels,
floor_db, range_db, counts}`, where `counts` is the daemon's `bins × levels` grid of little-endian
uint16 counts, bin-major, base64-encoded (an array of tens of thousands of small integers costs more
to write and to read than the bytes) and level `l` covers `floor_db + l*range_db/levels` upwards.
`ley listen --format json` is the audio member of the same
exception: `{seq, sample_index, sample_rate, format, pcm}`, `pcm` being the frame's PCM bytes
base64-encoded and `format` the `AudioSampleFormat` the daemon settled on (`S16` in v0); every row
repeats the rate and format so a consumer needs no header. `--format bin` writes those same frames
raw, back to back and nothing else. `ley scope --json` is the statistics member: one object per
frame, `{seq, sample_index, sample_rate, tap, window_ms, peak_dbfs, rms_dbfs, dc, scale,
tone_hz}`, where `seq` and `sample_index` name the daemon frame the drawn window closed on,
`peak_dbfs`, `rms_dbfs` and `dc` are measured over that window (presentation over the stream, as
spectrum's peaks are), `scale` is the vertical scale the frame was drawn at (1 at full scale, the
fitted step under `--scale auto`), and `tone_hz` is the sub-audible tone the daemon reported,
absent until it has reported one. It
carries no samples: those are `ley listen --format json`. `ley levels --json` and `ley waveform --json` are the
audio-meter members. Both read the daemon's audio spectrum, which is an FFT subscription on a
channel source and so arrives as FFT rows like any other -- dB per bin from 0 Hz to half the audio
rate, `center_hz` and `span_hz` of `rate/4` and `rate/2` -- but what the views print is what they
measured off those rows. `ley levels --json` is one object per row, raw and before the ballistics
that shape the bars: `{seq, sample_index, tap, bands: [{center_hz, db}], rms_dbfs, peak_dbfs,
squelch_open}`, where `bands` are the ISO octave centres with their bins summed in power and
divided by the window's equivalent noise bandwidth (1.5 for the daemon's Hann window), so a tone
reads its own level rather than the 1.76 dB the window spread it over. `rms_dbfs`, `peak_dbfs` and
`squelch_open` come from the daemon's `METER` telemetry and are `null` until it has measured a
block -- any number there, even -0 dBFS, would read as a real measured level. The bare
verb prints one such row and exits; `--watch` prints them as they arrive. `ley waveform --json`
is one object per column as it completes: `{sample_index, seconds, peak_dbfs, rms_dbfs,
squelch_open}`, a column being a fixed slice of audio rather than a slice of wall clock, `seconds`
how much audio the picture holds by the end of it, and `squelch_open` whether the daemon's squelch
let anything through during that slice. `ley fft` and `ley waterfall` subscribe GAP_MARKED (audio and
IQ stay LATEST_WINS), so a drop shows up as a `{"gap":{"from_sample":A,"to_sample":B}}` line before
the next row — never silently; gap lines do not count toward `--count`. The second is `ley version --json`: a client-local value
with no proto message, emitted through encoding/json as exactly `{"version","go","os","arch"}` in
that order (pinned by a golden test). The third is the client-local tables: `ley presets --json`
prints one array of `{name, aliases, hz, mode, description}` and `ley bands --json` one array of
`{name, aliases, min_hz, max_hz, mode, bandwidth_hz, step_hz, note}` (`mode` is `usb/lsb` where the
sideband follows the frequency; `aliases` are what `--band` accepts; `step_hz` is the band's channel
spacing, what one arrow key moves the dial by in the Mac app, which is not the bandwidth: airband is
10 kHz wide and spaced 25 kHz; a group such as `gmrs` comes after the
bands with `parts`, the aliases of the bands it spans). `ley bands <frequency|preset|band>
--json` is the one place a client-local table answers with a **single object** instead:
`{hz, band, mode, bandwidth_hz, reason}`, where `band` is one of those entries or `null` and `mode`
is resolved for that frequency, so it is `lsb` or `usb` rather than `usb/lsb`. `band` being `null`
does not null the answer -- `mode`, `bandwidth_hz` and `reason` are what a script needs to predict
what `tune` would do, and they are always present. Neither verb dials the daemon; `ley help
presets` is the same data in prose, and `ley presets` (the verb) owns the bare name. `ley
bookmarks --json` is the third such table and the only one a client writes: an array of
`{id, name, hz, mode, bandwidth_hz, updated_ns}` ordered by frequency and then name, which are the
fields of `bookmarks.json` itself (`$LEYLINE_BOOKMARKS`, else beside `labels.json` in
`~/Library/Application Support/Leyline`), so `mode` is the contract's own spelling (`NFM`) rather
than the CLI's and `bandwidth_hz` 0 means the mode's usual width; `ley bookmarks add`, `ley
bookmarks move` and `ley bookmarks remove` print the single record they touched. The Mac app reads that file, and reads the
band table from `app/Sources/LeylineClient/Resources/bands.json`, the checked-in bytes of `ley bands
--json` that `make bands-json` regenerates and a Go test holds to the table. The fourth is
`ley track --json`, the entity table: a client-side fold with no proto message, described under
"Decoders" below.

**Decoders.** `ley decoders --json` prints a `ListDecodersResponse`: the manifests the daemon
found, the directories it looked in, and the store's path, cap and age. `ley decode <name> --json`
prints one `DecodeRecord` per line (NDJSON) and nothing else on stdout; the banner naming the
decoder, the frequency and the channel it got is stderr prose, as is the line a `--job` run ends
with. `ley watch <decoder> --json` prints the same NDJSON `DecodeRecord`s as `decode`, but only
the ones its predicate matched: `--where field=value` (with `!=`, `~` for contains, and `>`, `>=`,
`<`, `<=` numeric), `--county FIPS` (a `PRED_CONTAINS` on the `fips` field, repeatable), and
`--near LAT,LON --radius R` (a `GeoTest`) become a `DecodeConfig.predicate`; `--notify` (bare for a
macOS notification, `--notify=webhook:URL` or `--notify=shell:CMD`) becomes a
`DecodeConfig.notify` the daemon fires on each match. Attached it streams and cancels on exit;
`--detach` (alias `--job`) keeps the job so the notifier fires unattended, printing the id and
`ley jobs cancel` on stderr. `ley records --json` prints a `RecordPage`: the records newest first plus the
`RecordAnchor`s that date them, because no record carries a clock of its own and wall time is
derived from the anchor whose `from_sample` is not past the record's (`docs/design/decoders.md`,
"Decisions"). `ley track --json` is the fourth documented exception to the proto3 rule, beside the
bulk rows: the entity table is a client-side fold with no proto message, so it prints one
`{"entities": [...]}` object per redraw as NDJSON, each entity
`{device_id, protocol, kind, summary, seen, age_s, last_sample_index, position, heard_slices}`
(snake_case, `position` an object of `{latitude, longitude}` or `null`, `age_s` seconds since that
row was last heard, `heard_slices` eight integers counting the station's records in each eighth of
the table's window oldest first -- the window is the decoder's silence timeout, or ten minutes when
it declares none -- which is the HEARD column as numbers). A decode job that names a decoder nobody installed is refused with `DECODER_NOT_FOUND`; a
decoder whose program could not be started is `DECODER_FAILED`.

`ley devices-seen --json` is the fifth documented exception, the registry beside the entity table:
a client-side fold over `QueryRecords` joined with the labels store, so it has no proto message
and prints one `{"devices": [...]}` object, each device `{device_id, label, protocol, kind, seen,
first_ns, last_ns, quiet_s, summary}` (snake_case). `first_ns` and `last_ns` are wall clock in
nanoseconds derived through the page's anchors, `0` when no anchor dates the record; `quiet_s` is
the seconds since the device was last heard; `label` is the user-given name or `""`. `--quiet-since
D` keeps only devices silent longer than `D` (a device with no datable last-seen is dropped,
because no anchor dates its record); by default the whole store is
scanned so a long silence can be found, and `--since` bounds the scan. `ley label --json` is the
sixth:
a label is user data in a client-side JSON store, not daemon state (`docs/design/decoders.md`, "The
state boundary"), so it prints one `{device_id, name, protocol, updated_ns}` object -- the record
set, read or (with `--clear` or an empty name) cleared, `name` empty when the device has none. The
store is `~/Library/Application Support/Leyline/labels.json` on macOS and
`$XDG_DATA_HOME/leyline/labels.json` (or `~/.local/share/...`) elsewhere; `$LEYLINE_LABELS`
overrides it. `ley monitor --json` is the seventh, the transmission log beside the entity table: a
client-side fold over the detections on the telemetry plane, so it has no proto message and prints
one object per carrier as NDJSON when the watch ends, in first-appearance order, each `{detection_id,
center_hz, channel, first_s, held_s, on_air_s, looks, looks_possible, peak_snr_db, bandwidth_hz,
on_air_slices}` (snake_case; `channel` the GMRS or preset channel on the frequency or `""` when none; `first_s` and
`held_s` seconds on the client's own clock, since telemetry latency is sub-second and a radio-check
log needs no anchor arithmetic; `held_s` is first-to-last span while `on_air_s` is the time actually
transmitting, `looks`/`looks_possible` being the rows the carrier was detected in over the rows
that covered it, so a
flickering intermod reads a wide `held_s` and a tiny `on_air_s`; `peak_snr_db` the strongest the
carrier was seen; `on_air_slices` eight shares in `[0, 1]`, the carrier's on-air fraction of each
eighth of the watch oldest first, from the arrival times of the daemon's per-row re-publishes
against its row rate -- the ACTIVITY column as numbers). The same three filters that clean the table
clean the NDJSON: `--min-snr`, `--min-hold` and `--skirt-db` (below) all drop their carriers from
both, so a tool wanting everything passes `--min-snr 0 --skirt-db 0`.

**`ley monitor <band|range> [--for D] [--min-snr DB] [--min-hold D] [--skirt-db DB] [--device SEL] [--take-over] [--json]`** parks
one capture on a band and watches it, then prints a time-ordered log of the carriers that came and
went. A range positional (`462.5M..462.75M`) or a band name (`gmrs-462`, `2m`) resolves exactly as
`scan`'s does: range first, then the band; the `gmrs` group is wider than one capture and is
refused with its halves named. `--for` sets how long to watch (`30s`, `2m`; `0` watches
until Ctrl-C); it becomes `MonitorConfig.duration_ms`. The watch is `Jobs.StartJob(MonitorConfig)`
and its detections stream on the telemetry plane (type `DETECTION`, daemon-wide) the same as a
scan's; the client folds them into the log. It runs daemon-side and owns the radio for the duration,
declining a radio somebody is using with the same don't-disturb rule as a scan (`--take-over`
overrides). A band wider than one capture can watch is refused with `INVALID_ARGUMENT`; `scan` sweeps
a span that wide. There is no `--gain`: a watch runs at the gain the radio is on, and `scan --gain` is
the sweep's. The log
table (TIME, FREQUENCY, CHANNEL, HELD (s), ON AIR (s), ACTIVITY, PEAK SNR (dB) -- TIME a dimmed
gutter of first sightings stamped when it changes, CHANNEL present only on a band with named
channels, HELD the first-to-last span, ON AIR the time actually transmitting from the detector's
look
counts, ACTIVITY an eight-cell sparkline of when during the watch it was heard with the span it
covers in the header, the first column dropped on a terminal too narrow for the table, and PEAK SNR
coloured by the level ramp from `--min-snr` upward) is stdout; the live feed announces a carrier the
first time it clears `--min-snr`, and the summary reports once when a carrier's reported frequency,
its strongest reading, differs from the one the feed printed. the live feed of each carrier as it is
first heard, and the summary, are stderr. Three filters keep the log readable, each disabled with a
`0`: `--min-snr` (default 8) drops a carrier whose peak never cleared that many dB over the noise
floor; `--min-hold` (default 0, off) drops one held for less than a set span; and `--skirt-db`
(default 25) folds a carrier at least that many dB below a stronger one within an adjacent channel
(its own width, at least 30 kHz) into that carrier, since a strong transmitter spills into the slots
either side and those are not separate transmissions. What each filter hid is tallied on stderr, so a
hidden carrier never reads as a quiet band. Full design: `docs/design/band-watching.md`, the
occupancy view of which this is the first cut.

**`ley scan --json`** prints exactly one `Scan` object when the sweep finishes, and nothing before
it: the answer is the whole scan, not the steps it took to get there, and progress belongs on
stderr where a person can see it. Each `Detection` in it carries `looks` and `looksPossible` -- the
spectrum rows in which it cleared the threshold, out of the rows that covered that frequency -- and
`floor_dbfs`, the local noise floor its `snr_db` was measured against. Those counts are reported,
never used as a filter: a signal seen once in eight is reported as such rather than dropped,
because an
intermittent transmission is exactly what somebody may be scanning for. `Scan.gains` is the gain the
sweep pinned for its whole duration, because a scan run at a different gain is a different
measurement. `--gain dB|auto` says where to pin it (`ScanConfig.gain`, a `GainWrite` on the first
gain element): a level, or where the radio's AGC settles; without it the sweep pins whatever the
last client left the radio at, and two sweeps of one band can differ by that. A gain the radio
cannot set fails the job with the daemon's code rather than sweeping at another. `Scan.resolution_hz` is the analysis bin width, which every dB in the message is per --
a wider bin holds more noise -- and `Scan.covered` is the range actually looked at, never wider than
`config.range` and narrower whenever the radio could not reach all of it, part of the request fell
in the tuner's own blind spot, or the sweep was stopped early; a client that reported `config.range`
as searched would claim coverage that was never measured. `Scan.config.step_hz` is the advance the
daemon chose; there is no `--step`, because the step geometry is what keeps the sweep free of blind
spots. `ScanConfig.device_id` names the radio when there is more than one. `snr_db` here is *spectral* -- a bin against a spectral floor -- and will not agree
numerically with `Meter.snr_db`, which is a channel's whole power over the band's floor at the
channel's width.
Full design, with the measured numbers: `docs/design/scan.md`.

While a sweep holds a radio it is the only thing tuning it: `CreateCapture`, `CreateChannel` and
centre or rate writes on that capture are refused with the stable code `DEVICE_SWEEPING`, which is
distinct from `DEVICE_BUSY` so a client does not tell the user to look for another
client. Without it a channel created on a capture that is walking a band would be dragged across
megahertz with no explanation.

**Jobs.** `Job` appears on the event stream (`Event.job`) and in `GetState` (`GetStateResponse.jobs`),
so job state is rendered by subscription like every other piece of daemon state rather than polled.
A v0 scan job is **not persistent**: it belongs to the connection that started it and the daemon
cancels it when that connection goes, which is what makes Ctrl-C hand the radio back. Its
`result_uris` carries `ley://scans/<id>`, which names the scan and is resolved by `Jobs.GetScan`; it
is not yet a Resource, because an ad-hoc scan is ephemeral and there is no file. The
daemon keeps the last sixteen finished jobs in memory and loses them on restart. A decode job
started with `--job` (kept) is the exception: it is written to `kept-jobs.json` beside the record
store and comes back after a restart as the same job, its records appending to the same resource
(`docs/plans/decoders.md`, DEC-11); a job cancelled by a client does not. A **record job** is the
other exception and needs no flag: a recording outlives the client that started it, because its
output is a file (`Jobs.StartJob(RecordConfig)`, below). `Jobs.StartJob` with a watch config and
`Jobs.GetTranscript` remain UNIMPLEMENTED until Milestone D.15.
A running decode job's `status_detail` carries its liveness: "decoding with aprs: 12 records, last
3 s ago", the first record published at once and a moving count every two seconds after it, so
`ley jobs` distinguishes a decoder that is receiving packets from one that is not. A decoder that
is silent
stays `RUNNING`, because silence is not failure (DEC-16 in `docs/plans/decoders.md`).
`ley jobs --json` prints a `ListJobsResponse` with the jobs in id order, which for ULIDs is the
order they were started, so the row numbers the table prints are the same from one call to the
next. `ley jobs cancel <job> --json` prints the `Job` the daemon answers with: cancelling a job
that has already finished is not an error, and the state in that `Job` is the one it ended in.

Destructive verbs echo nothing stale: `ley stop`, `ley stop --all` and `ley devices detach` print
the daemon's `Empty` answer (`{}`) under `--json` — one line for the whole action — and the exit
status carries success; when `stop --all` finds nothing running it prints nothing (the sentence is
stderr prose without `--json`) and exits 0. `ley set --json` prints the confirming or rejecting
Event and exits 1 on a `WriteRejected` with nothing on stderr. `ley devices --watch --json` prints
the `ListDevicesResponse` first (the same line `devices --json` prints), then one `Event` per plug
or unplug carrying the full `DeviceDescriptor`. `ley devices attach rtltcp <host:port> --json`
prints the `DeviceDescriptor` the daemon attached, or the one it already hosts for that endpoint,
since one endpoint is one radio and a second attach is not an error; without the flag the id is on
stdout and the sentence about it on stderr, as `ley play --persistent` does. An endpoint that
cannot be reached is exit 1 with the daemon's `DEVICE_IO` sentence and nothing remembered. `ley daemon start --json` and `daemon stop --json`
print the same `DaemonInfo` as `daemon status --json` (start from a fresh `GetState` after the
action; stop the last info the daemon reported, pid included, or only `socketPath` when nothing was
running); `daemon install`, `uninstall` and `logs` have no JSON shape and reject `--json` as a
usage error (exit 2).

**Recording** (`docs/design/recording.md`). A recording is a job's output, not a sink somebody
attaches: `Control.AttachSink(file)` stays refused, because a sink attached to a channel dies with
that channel's owner and leaves a file nothing indexes, while a job goes through the allocator,
outlives its client and produces a resource. The job's id **is** the recording's id, so
`Job.result_uris` carries `ley://recordings/<job_id>` from the moment the job exists.

`ley record <freq|preset|chan_ID>` writes audio as WAV (PCM S16 mono at the channel's audio rate)
or, with `--iq`, the capture's raw samples as `.cf32` at the capture rate. A channel id records
what somebody is already listening to, with their mode, bandwidth and squelch, and ends
`COMPLETED` when that channel closes; `--mode`, `--bw` and `--squelch` are refused there rather
than ignored. `--gate squelch` records only while the squelch is open and writes **one file per
exchange**: a re-open inside `--hang` (default 5 s) continues the same file, so the pauses between
overs stay in one part, and `--pre` (default 500 ms) keeps what came just before each key-up.
`--listen` also plays the channel through the daemon's speakers while it records, so you hear
what is going into the file without a second command holding a second channel; the sink belongs to
that terminal and goes when it exits, which is why it is refused with `--detach`, and with `--iq`,
whose samples have not been through a demodulator. Audio is what `record` writes unless `--iq`
says otherwise; `--audio` is accepted as the explicit spelling of that default, because the V0
story names the pair, and asking for both is refused. `--stop-after-quiet D` ends the job after that long with nothing on the air. `--part D` cuts a new
file on a timer (the default for `--iq` is 60 s, because 2.4 MSPS is 19.2 MB a second); audio is
one file unless asked otherwise. `--gate squelch` with `--iq` is refused, and so are `--pre`,
`--hang` and `--stop-after-quiet` without a gate. Silence is never edited out of a file: each part
says where on the capture's timeline it starts, and the times nothing was recorded are listed in
the manifest as `coverage_gaps` (AGENTS.md invariant 5). The verb runs in the foreground and prints, on stderr, a banner of the decisions **the daemon**
made rather than the ones asked for — it waits up to two seconds for the manifest so the rate,
format, gate and radio in it are the real ones — then a live line, then what it recorded; the
recording's URI is on stdout when it ends. Ctrl-C cancels the job, which finalises the files, so
a cancelled recording is complete and readable; and `--detach` exits at once with the job id
and the URI for a script.

`ley recordings` lists the store through `Resources.ListResources(RECORDING)`, newest first;
`--kind`, `--freq` and `--since` filter on the resource's own metadata, whose keys are frozen
because `metadata_filter` matches them by exact string: `kind` (`audio`|`iq`), `frequency_hz`,
`mode`, `sample_rate`, `format`, `duration_ms`, `parts`, `started_at_ns`, `ended_at_ns`,
`ended_by`, `device`. `ley recordings show <id>` prints the manifest and `ley recordings path
<id> [--part N]` the directory or one part's samples file, so `open -R "$(ley recordings path
job_…)"` reveals it in Finder. Every id argument takes a full job id, an id prefix or a
`ley://recordings/` URI, `ley play` included: `ley play job_01J…` plays a recording's first part,
and `--part N` picks another.

**What `ley play` does with a recording depends on what is in it.** An **IQ** part is raw samples,
so it is attached as a pretend radio and tuned, exactly as a fixture is. An **audio** part is a
WAV: it holds what a demodulator already produced, and there is no signal left in it for a channel
to decode — attaching it as a radio would put a fictional capture and a fictional mode into
`ley state`, and demodulating audio gives noise. **The daemon plays it instead**
(`Control.StartPlayback`), through the same audio device a channel's audio comes out of, so the
sound comes out on the daemon's machine, and `ley play` holds the
terminal with a position until Ctrl-C stops it — the same shape as every other listening verb. A
daemon with no audio device answers `PLATFORM_UNSUPPORTED` and `ley` then hands the file to this
machine's own player (`$LEYLINE_PLAYER` when set — `afplay`, `mpv`, `vlc` — else `open` on macOS
and `xdg-open` elsewhere), saying which happened. Under `--json` nothing is played at all and the
`LocalPath` is printed instead: a script wants the path, not a sound.

A **`Playback`** is daemon state like everything else (`playback_id`, `resource_uri`, `path`,
`sample_rate`, `samples`, `position`, `volume`, `created_by`, `state`), so it appears in
`GetState` and on the event stream, `ley state` lists what is playing and how far in, and a second
client — the Mac app — renders a position and a stop button without polling. It is not a job (a
job's output is a resource; a playback produces nothing) and not a sink (a sink is where a
*channel's* audio goes; a playback has no channel). It belongs to the client that started it and
stops when that client goes, which is what makes Ctrl-C stop the sound; `Control.StopPlayback`
stops one early, and the final event carries `state` unset as the tombstone, so a client can tell
"it reached the end" from "somebody stopped it". Seeking, pausing and looping are not in v1:
`position` is reported and not writable.

`ley record --json` prints the `Job` as each state change arrives, one object per line, and
nothing else on stdout — the URI is in its `resultUris`. `ley recordings --json` prints a
`ListResourcesResponse` and `ley recordings path --json` a `LocalPath` (`{"path": "..."}`); without
`--json` the path is printed alone so it composes into a shell command. **`ley recordings show
--json` is the eighth documented exception**: it prints `recording.json` itself, byte for byte the
document beside the files, because the daemon owns that format and a client that re-rendered it
would drift from what Finder shows. Its keys are snake_case: `{job_id, uri, kind, frequency_hz,
mode, bandwidth_hz, sample_rate, format, device, gains, squelch_dbfs, gate, part_ms, started_at_ns,
ended_at_ns, ended_by, created_by, anchors, parts, coverage_gaps, bytes}`, where `parts` is
`[{part, file, start_sample, end_sample, samples, bytes, peak_dbfs, mean_dbfs, squelch_opens}]`
(`peak_dbfs` and `mean_dbfs` absent on a part nobody finished measuring, such as one a restart
repaired), `coverage_gaps` is `[{from_sample, to_sample, reason}]` and `anchors` is one entry per
capture the recording spanned, each dating its own capture's samples. `ended_by` is one of
`duration`, `quiet`, `cancelled`, `channel ended`, `restart`, `store full`, `error`. Beside each
part is its own sidecar — the `iqfile` document (`iq-files.md`) with a `recording` block — which is
what makes a part a file `ley play` can read.

The store is a plain directory Finder can open and Spotlight can index:
`~/Library/Application Support/Leyline/recordings` on macOS, `$XDG_DATA_HOME/leyline/recordings`
elsewhere, `leylined --recordings PATH` to move it, with `--recordings-cap BYTES` (default 20 GiB)
and `--recordings-age DAYS` (default 0, never) as its retention. A recording deleted in Finder is
gone with no further step: the listing is a scan of the manifests. Retention never removes a
recording whose job is running, and a daemon restart does not resume a recording — the next daemon
repairs the last part's WAV header from the file's length and closes the manifest with
`ended_by = restart`.

A radio moved out from under a running recording leaves a gap in it. The daemon never refuses a
user's retune to protect a job: it marks the job `DEGRADED`, closes the open part and records the
gap.
The guard is in the client, so `ley tune` and `ley set freq` refuse a retune of a capture a
recording is riding on, name the job and `ley jobs cancel`, and go ahead with `--retune`.

**Exit status** (also `ley help scripting`): 0 on success, including a Ctrl-C that ends a live
`tune`/`play`/`spectrum --watch`/`fft`/`listen`/`devices --watch` session; 1 when the daemon refused or
failed (the line reads `ley: <message> [CODE]`, keeping the daemon's stable `ErrorDetail.code`,
unless `ley` has a plainer sentence for that code); 2 usage error — bad flag or argument,
unknown verb (with Cobra's "did you mean"), unknown setting, unparseable value or unknown
preset — nothing was sent to the daemon (selector misses such as `--channel 9` depend on daemon
state and exit 1); 3 the daemon is not running, from any verb (`ley: the Leyline daemon is not
running (socket …). Start it with: ley daemon start`, or the stale-socket variant); 130
interrupted by Ctrl-C before the verb's live phase. Error lines read `ley: <plain sentence>.
<next command>`. `daemon status --json` always prints a `DaemonInfo`; when the daemon is not
running it carries only `socketPath` (no `pid`) and the status is 3. `daemon stop` exits 0 once
the socket has stopped answering and removes a stale socket file; under launchd the LaunchAgent
uses `KeepAlive.SuccessfulExit=false`, so a clean stop stays stopped while a crash is relaunched.

**Bare `ley` (decision, 2026-09-05).** On a TTY it prints an orientation screen — daemon status,
devices, what is playing, and the next commands chosen from the state; exit 0 in every state,
300 ms dial timeout. Piped it prints the same block unstyled (`ley --help` is the verb list);
`--json` prints exactly what `ley state --json` prints, including its failure when no daemon
answers. This screen is the placeholder the V0.5 TUI dashboard replaces on a TTY
(`docs/plans/user-stories.md`); its renderer (`renderOrientation` in `go/internal/cli`) is the one
function the dashboard reuses for its no-daemon and no-device states, so the words stay the same.

**Auto squelch and the daemon-side follow-up.** `tune --squelch auto` (the default for NFM and
AM, whatever the run prints; `--squelch off` opts out) and `set squelch auto` subscribe one FFT row of the capture, take the median bin
as the floor, scale it to the channel bandwidth (`+10·log10(bw / bin width)`) and write
`floor + 10 dB` with `WriteParams`. The measurement is the daemon's own spectrum and a median is
presentation, so no DSP moves client-side (AGENTS.md invariant 2); but the threshold is a
snapshot, and every client would have to repeat it. The recorded follow-up is an additive
daemon-side relative squelch — `ParamWrite.squelch_relative_db`, "mute at noise floor + N dB"
tracked by the daemon — after which `auto` becomes a one-field write. Not in v0.

**Roadmap stubs.** There are none: every verb `ley` knows reaches the daemon. The mechanism stays
(a hidden verb that exits 2 naming its milestone and what to use today, listed by `ley help
roadmap`), because a newcomer who types a planned verb should learn what is coming rather than see
Cobra's "unknown command". `scan` was one until Milestone D.13, `watch` until D.17 -- the name went
to the record-watch verb (a decode job with a predicate and a notifier, DEC-9a), the newer spec,
and D.15 will place the audio-transcript watch that had reserved it -- and `record` until C.12.

Deliberate omissions at v0: no remote flags (UDS-only) and no TX verbs.
