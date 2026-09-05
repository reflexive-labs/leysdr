# Plan: CLI ergonomics and documentation for newcomers

Status: in progress (2026-09-05). Scope: `ley` and its docs. The wire contract, engine and daemon
are out of scope except where a client convenience needs a value the daemon already provides.

## Goal

Someone who owns an RTL-SDR and knows roughly what a radio does — but not what dBFS, FFT rows,
captures or channels are — can, using only `ley` and its help: start the daemon, see their
radio, hear a station, adjust it while listening, and see what is on the air. Power users keep
every existing knob and `--json`; nothing gets less capable, the defaults just get smarter and the
words get plainer. The CLI adds no capability the protocol lacks (CLAUDE.md): presets, band
defaults and automatic squelch are client-side translations into the same RPCs.

## What the V0 stories look like today (docs/sdr-user-stories.md) and what blocks a newcomer

| story | today | blocker for a newcomer |
|---|---|---|
| `devices` shows my SDR | works; empty table when nothing is found | no hint what to check next |
| second terminal, no device-busy | works (capture reuse) | `set` demands `--channel` as soon as two channels exist |
| `tune 146.52M --mode nfm` and hear audio | works | bare `146.52` is read as Hz; `--mode fm` on 101.1 MHz silently means NFM; mode must be known; squelch is "off" so you hear full-scale static until a signal arrives |
| adjust gain/squelch/filter live | works | `-5dB` shapes, dBFS scale unknown, "squelch 5" is silently a level above full scale |
| record / play | `play` works; `record` is Milestone C.12 | help does not say record is coming |
| `fft --rate 10` rows for tools | works | "FFT rows" is meaningless without a spectrum view; human mode prints raw JSON |
| `scan` detections | Milestone D | nothing in `ley` says so |
| two channels on one device | works | ids everywhere; no way to say "the one I just made" |
| `--json` everywhere | works | fine |

Concrete traps seen in the current build: the daemon-not-running error is a gRPC transport dump;
`tune 146.62` → "147 Hz is outside the device tuning range"; `set squelch 5` is accepted;
`set foo 1` complains about channel selection before saying `foo` is not a parameter.

## Principles

1. **Plain words first, jargon second, always an example.** "Squelch: mute the audio when the
   signal is weaker than this level (try `-40`, or `auto`)."
2. **Accept what people type.** Frequencies with or without units (a bare number is MHz),
   levels with or without `dB`/`dBFS`, modes by alias (`fm` picks WFM on the broadcast band and
   NFM elsewhere), case-insensitive, named presets.
3. **Say what you decided.** `tune` prints the frequency it understood, the band it recognised,
   the mode it chose and why, and the squelch it set. Wrong guesses are visible, not silent.
4. **Every error says what to do next**, in one line, with the exact command to run.
5. **Progressive disclosure.** Bare `ley` orients; `tune` does the whole job with defaults;
   `set` adjusts; `spectrum` shows; `state`/`fft`/`--json` expose everything for scripts and
   agents. Help topics (`ley help squelch`) hold the longer explanations so `--help` stays short.
6. **Docs and help say the same thing.** The task guide is written from the help texts, and a
   golden-file test keeps the help texts from drifting unnoticed.

## Work items

Each item lands with tests against the fake daemon and, where the wire is involved, the real
daemon e2e. One commit per item. Every frequency-taking flag uses the same parser and echoes the
interpreted value; every error keys on the daemon's `ErrorDetail.code`, never on message text.

### A. Input parsing and tables (`go/pkg/leyline`)
- `ParseUserFrequency`: bare number < 100 000 → MHz (`146.52`, `7.040`, `1010` → 1010 MHz), ≥ 100 000
  → Hz; units as today (`k`, `M`, `G`, `Hz`, `e6`). Callers add hints on `FREQ_OUT_OF_RANGE`: the
  device's range is always printed; a unit hint only when re-reading the input as kHz lands inside
  that range or in a known band ("for 1010 kHz AM broadcast type 1010k"); otherwise the honest
  reason ("this device cannot tune below 24 MHz; HF needs an upconverter"). Commas are rejected
  with a hint. `ParseFrequency` stays Hz-strict for library callers.
- `ParseSquelch`: `-40`, `-40dB`, `-40 dBFS`, `off`, `auto`; a positive number is an error that
  explains the scale ("levels are dBFS, 0 is loudest; try -40 or auto").
- `ParseGain`: `auto`, `30`, `30dB`; negatives rejected with the element's range when known.
- `ParseBandwidth`: bare number < 1000 → kHz (`12.5`), else Hz; `12.5k`, `200k`, `12500`.
  `--bw` and `set bw` take strings. `ParseVolume`: `0..1`, `50%`, or `1..100` as percent.
- `ResolveMode(name, hz)` (new; `ParseMode` unchanged): `fm` → WFM on 87.5–108 MHz else NFM;
  `ssb` → USB ≥ 10 MHz else LSB; `nbfm`/`wbfm` aliases; explicit modes as today.
- `bands.go` (presentation only): FM broadcast, AM broadcast, airband, 2 m, 70 cm, NOAA weather,
  marine VHF, HF amateur segments → name, default mode, default bandwidth; `BandFor(hz)`; no
  band → NFM with a printed "(no band recognised, using NFM)".
- `presets.go` (pure table): `noaa` = `noaa1` (162.550), `noaa1..7`, `calling` (146.520 NFM),
  `marine16` (156.800), `guard` (121.500 AM). Resolution order: number/unit form first, then
  preset name (case-insensitive), else an error listing the nearest names. No probing.
- Selectors: `--channel`/`--capture`/`devices detach` accept a full id, an id prefix, a 1-based
  index from the printed list, or a frequency (`--channel 146.62`).

### B. `ley tune`
- Mode: explicit `--mode` > (play: sidecar mode) > band default > NFM. Rationale printed only
  when inferred, one line.
- Squelch default: `auto` for NFM and AM in interactive runs; `off` for WFM, SSB, CW, raw, and for
  `--json` and `--persistent` runs (scripts get today's behaviour unless they pass `--squelch auto`).
  `auto` = subscribe one FFT row of the capture, floor = median bin dB + 10·log10(channel bw / bin
  width) (the daemon's own spectrum; a median is presentation), threshold = floor + 10 dB, written
  with WriteParams and printed ("squelch auto → -58 dBFS, 10 dB above the band's noise floor").
  If no row arrives within 2 s, squelch stays off and the banner says so. Follow-up recorded in
  interfaces.md: an additive daemon-side relative squelch (`ParamWrite.squelch_relative_db`).
- Banner: `Listening to 146.620 MHz (NFM, 2 m amateur band) on <model>, gain auto. Squelch auto →
  -58 dBFS. Ctrl-C stops. From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum`.
- Meter line: `146.620 MHz NFM  signal -42 dBFS  muted, waiting for a signal` / `audio`
  (OPEN/CLOSED stay in `--json` only). Gain shown in the banner and by `set` with no args.
- Friendly failures by code: no device (checklist: plugged in, `rtl_test`, `ley daemon logs`),
  DEVICE_BUSY (`ley state` shows who), FREQ_OUT_OF_RANGE (range + unit hint rule above), audio
  unavailable. In `--json` mode all prose goes to stderr; stdout is NDJSON only.

### C. `ley set`
- Parameter parsing with per-parameter help in the error; unknown parameter lists parameters
  before any target lookup; `set squelch auto` uses the same measurement as tune.
- `ley set` with no arguments prints the target channel's current values (frequency, mode,
  bandwidth, squelch, gain, volume).
- Target: one active channel → it; several → the most recently created channel owned by a
  `cli` client if exactly one such exists, always printing which one was chosen; otherwise a
  numbered list with `ley set squelch -40 --channel 2` as the example. Selectors per A.
- The negative-number workaround (DisableFlagParsing) stays confined to `set`, commented, with
  tests for `set squelch -40`, `set --json squelch -40`, `set squelch -40 --json`, `set -h`.

### D. `ley spectrum` (new) and `ley fft`
- `ley spectrum [freq] [--span 2.4M] [--bins 1024] [--watch|-w] [--rate 2] [--count N] [--device ID]
  [--width N]`: one FFT row rendered as an ASCII bar chart across the band, header with centre,
  span, bin width and the median floor, then the N loudest bins as "loudest bins: 88.5 MHz -12 dB,
  …" (no bandwidth, no SNR, never called signals; `scan` will do detection later). Once by default;
  `--watch` redraws in place on a TTY and appends otherwise; Ctrl-C exits 0. A capture is created
  for the run when needed and destroyed on exit.
- `--json` for `spectrum` and `fft --format json` emit the documented FFT row line shape
  (`{seq, sample_index, center_hz, span_hz, bins}`; spectrum adds `peaks`). Bulk rows have no
  proto message, so this is the one documented exception to the proto3 rule, recorded in
  interfaces.md beside the shm bypass. `fft`'s help explains what a row is and points to spectrum.

### E. Bare `ley`
- Root gets a `RunE` with a custom `Args` validator that keeps Cobra's "did you mean" for unknown
  verbs. On a TTY it prints an orientation screen: daemon status, devices, what is playing, and
  the next two or three commands chosen from the state (no daemon → how to start it; no device →
  checklist; idle → `ley tune …`; listening → `ley set …`, `ley spectrum`). Exit 0 in every state,
  dial timeout 300 ms; piped or `--json` → the command list / a pointer to `ley state --json`.
- Decision recorded in interfaces.md: this screen is the placeholder the V0.5 dashboard replaces
  on a TTY; the renderer is one function the dashboard reuses for its no-daemon/no-device states.

### F. Help texts, groups and topics
- Every verb: plain `Short` (≤ 60 chars), `Long` in plain words, an `Example` block, a `GroupID`
  (Listening, Adjusting, Looking around, Data for tools, Daemon); help and completion assigned to
  a group. Hidden stub verbs `record`, `scan`, `watch` exit 2 with "not implemented yet
  (Milestone …); today: …" and appear in `ley help roadmap`.
- Topics via a custom help command (`root.SetHelpCommand`) that dispatches `ley help <topic>` and
  falls back to Cobra for verbs; topics are hidden commands with a template that omits Usage:
  `squelch`, `frequencies`, `modes`, `gain`, `presets` (generated from the tables), `glossary`,
  `scripting` (exit codes, `--json`, presence), `roadmap`. Root help lists them.

### G. Daemon lifecycle messages and exit codes
- Exit codes (interfaces.md + `help scripting`): 0 ok · 1 daemon/runtime error · 2 usage error ·
  3 daemon not running (all verbs) · 130 interrupted before the live phase. Error lines are
  `ley: <plain sentence>. <next command>` and keep `[CODE]` when a daemon code exists.
- Not running → `the Leyline daemon is not running (socket …). Start it with: ley daemon start`;
  stale socket variant; `daemon start` prints the pid and `check with: ley daemon status`.
- Empty `ley devices` on a TTY prints the no-device checklist under the header.

### H. Documentation
- README: a newcomer quickstart (five commands with expected output) and a glossary pointer.
- `docs/cli-guide.md`: task walkthrough mirroring the V0 stories, then "for scripts and agents",
  then "when things go wrong"; cross-links to `ley help <topic>` rather than duplicating them.
- `docs/interfaces.md`: new verb, selectors, presets, exit codes, the bulk-row JSON exception,
  the bare-`ley` decision, the relative-squelch follow-up.

### I. Tests
- Golden snapshots for `ley --help`, every `ley <verb> --help`, `ley help <verb>` and `ley help
  <topic>` (`-update` refreshes; `Version` pinned); a meta-test that every verb has a GroupID, an
  Example and a short Short. Bare `ley` tested per state against the fake daemon (not golden).
- Table tests for every parser, `ResolveMode`, bands, presets, selectors.
- Fake-daemon tests: inferred-mode banner, auto squelch value (from the fake's spectrum), `set`
  with no args, `set` target rule with two `cli` channels and with a foreign owner, per-parameter
  errors, spectrum rendering and `--json`, exit codes per class, not-running message, stubs.
- e2e: `tune` with auto squelch against the real daemon and a fixture (floor from the real row).

## Out of scope

The TUI dashboard (V0.5), `scan`/detector (Milestone D), `record` (C.12), best-of-N preset
probing (needs `scan`), and any wire change. Auto squelch is a client convenience over daemon
data; the daemon-side relative squelch is the recorded follow-up.

## Review log

Reviewed by three independent passes (newcomer walkthrough, CLI conventions, invariants
guardian) on 2026-09-05; the revisions above resolve their must/should findings: floor from the
daemon's spectrum instead of a client power average (continuous carriers no longer get muted),
the `set` target rule no longer depends on a user identity the wire lacks, presets are a pure
table with a help topic, the bare-number rule has no dead zone and applies to every frequency
input, exit codes and the bulk-row JSON exception are written contracts, and the Cobra specifics
(root Run with suggestions, help-topic dispatch, groups) are called out. Invariants: no
client-side DSP (a median over a daemon row and top-N bins are presentation), state stays in the
daemon, `--json` stays proto3 except the documented bulk rows.
