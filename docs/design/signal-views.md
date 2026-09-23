# Design: Signal Views — Waterfall, Channel View, Sub-Audible Tones

Status: draft. Companion to `data-planes.md` (which owns the plane split this builds on) and
`docs/dev/cli-style.md` (which owns how any of it is drawn). Covers three related features that all answer
one question — *what is actually happening on this frequency* — and one shared standard for
reporting only what was measured.

## Context

`ley spectrum` answers "what is on the air **now**". Three things it cannot answer:

1. **Is that signal continuous, or did it start and stop?** A single frame cannot show duty cycle.
   A birdie and a two-minute transmission look identical in one frame.
2. **What am I hearing, and how well?** Audio level, deviation, tuning error, and the history of
   transmissions on this channel are not on the wire at all today.
3. **Who is this repeater for?** A sub-audible CTCSS/PL tone is transmitted with almost every
   analogue two-way transmission, and the NFM chain currently removes it one stage after the
   discriminator.

These are one design because they share a plane, a timebase, and an honesty standard, and because
two of the three are nearly free once the third's groundwork exists.

## What the terminal can and cannot show

Measured, not assumed. A waterfall drawn from a real 2.4 MHz capture of the FM broadcast band, at
100 columns, gives **24 kHz per column**. That is an *activity map*: it shows where energy is and
when, and it cannot show signal shape or separate 12.5 kHz neighbours. It is most useful below
about 200 kHz span, and the header must state the per-column bandwidth so the user knows the
resolution.

The only thing it adds over `ley spectrum --watch` is **intermittency**; the max-hold trace already
answers "birdie or real?". That is a narrow benefit, but a real one: in testing, a transmission that
keyed up for four seconds was invisible in any single spectrum frame and unmistakable in the
waterfall.

## The snapshot problem

`DefaultSpectrumLadder.process` computes **one unaveraged periodogram per row**, from whichever
capture block happens to cross `nextDue`. At 2.4 MSPS a 1024-point FFT covers 1024 of the ~600,000
samples in a 250 ms row: **0.17% of the row**. A 40 ms burst therefore appears in roughly one row in
six and flickers, so it looks like noise.

A snapshot waterfall therefore misses short bursts, which are what a waterfall is for. This is not
a rendering problem and cannot be fixed in the client.

**Decision.** The ladder gains an accumulation mode: one look per capture block (~6.8 ms at
2.4 MSPS / 16384-sample blocks), capped at 64 looks per row, combined as max-of-looks.

- Cost: 146 FFTs/s of size 1024 rather than 4 — about 7.5 Mflop/s on vDSP.
- Guarantee: any burst lasting at least one block period lands in at least one look and is drawn at
  full level. Sub-block bursts stay probabilistic, and the docs state this.
- `MAX` raises the apparent noise floor by roughly 6 dB relative to `SNAPSHOT`, because the maximum
  of N exponential draws is biased upward. The renderer's floor estimate must be computed from the
  same rows it draws, so the bias cancels instead of showing noise as signal.
- Default stays `SNAPSHOT`, so `ley spectrum` is byte-identical and only a client that asks for
  accumulation pays for it.

## Drawing the waterfall

The full rules live in `docs/dev/cli-style.md`; the decisions that are specific to this view:

- **One shaded cell per column.** New `ui.Glyphs.Shade` = `" ░▒▓█"`, ASCII `" .:+#"`. These are
  density textures that tile; the block ramp `▁▂▃` does not — stacked, it looks like scan lines.
  U+2591–2593 are CP437 and have universal font coverage.
- **Level is double-encoded**: the shade carries it, `ui.Style.Level` hue refines it. A waterfall
  whose level is only in colour is a blank rectangle under `NO_COLOR` or `--ascii`, which fails
  principle 1. This is why **half-blocks are rejected**: `▀` with a
  foreground and background colour doubles the on-screen time depth, but every cell becomes the same
  glyph and the colour-off rendering carries nothing. It also costs two SGR sequences per cell with
  few mergeable runs, roughly 3× the bytes.
- **The floor draws as a space**, so the terminal's own background shows through. The same reasoning
  that made `ley spectrum` a trace rather than a fill: ink only where there is signal. On
  a real FM capture this paints about 22% of cells instead of 100%.
- **The scale is held for the whole run.** Auto-scaling per row makes the time axis misleading: the
  same signal would change shade because a different part of the band got louder.
- **Time runs newest-at-bottom, scrolling, one printed line per row.** No cursor addressing and no
  wrap buffer: it works piped, in scrollback and in tmux, and it composes with everything else `ley`
  prints. The terminal keeps the history; `ley` writes one line at a time.
- **A gap draws its own row.** Delivery is `GAP_MARKED` (invariant 3); if a dropped row is simply
  not drawn, time silently compresses and the picture is wrong.

`ley watch` later reuses this renderer over a client-side ring of raw bin rows, reduced at paint
time so a resize re-renders correctly.

Wire: `StreamKind FFT`, `bin_format DB_U8`, `rows_per_second` = the display rate, `GAP_MARKED`.
About 4 KB/s, too little to need the shm bypass; the Mac app's Metal waterfall does need it.

## The channel view

`ley tune` gains a live view on **stderr** when stderr is a TTY and width ≥ 60; stdout keeps
carrying ids, events and NDJSON. Below that width the existing one-line meter is unchanged. No new
verb.

The main element is the **transmission table**, not a chart: the per-event log of what happened
on this frequency. That is what a scanner operator actually reads, and it is the cheapest thing on
this page to build.

```
146.520 MHz  NFM 12.5 kHz      RTL-SDR v3 · gain auto · sq -46

signal  -38 dBFS  ████████▲█░░░░░░░░   snr 26 dB
audio    -6 dBFS  ███████████████░▲░   dev 3.4 kHz   off tune +1.1 kHz
PL      100.0 Hz  held 4.2 s   tone/band 18.4 dB   dev 712 Hz

TRANSMISSIONS   last 5 of 23 since 11:38:02
   now        4.2 s   PL 100.0    snr 26 dB   peak  -4 dBFS
   11:41:58   0.9 s   PL 100.0    snr 19 dB   peak  -9 dBFS
   11:41:31  12.4 s   PL  77.0    snr 31 dB   peak  -3 dBFS
   11:40:02   2.1 s   no tone     snr  8 dB   peak -22 dBFS
```

Every number on the screen comes from the telemetry plane, so `--json` and the MCP adapter see
exactly what the listener sees, and `ui.Strip` of the styled render is byte-identical to the plain
one. `▲` on row 1 is the squelch threshold; on row 2 it is the peak hold. "off tune" is `Warn` and
appears only above 10% of channel bandwidth.

**Not built: an audio spectrum.** Neither a continuous 0–4 kHz chart nor a broken-axis
60–260 Hz ∥ 300–3400 Hz variant. The sub-audible band's only real content is one tone, so the chart
would only duplicate the number beside it; and 18 columns cannot separate 67.0 from 69.3 Hz, so it
would imply resolution it does not have and could contradict that number. An
`AUDIO_FFT` stream stays the additive path if DCS or two-tone paging ever needs it.

## Sub-audible tones

### Where the signal is

`NFMDemodulator.process` calls `discriminate(s, count:scale:)`, which writes the discriminator
output into `scratch.real`; every stage after that — the 4 kHz low-pass, the 300 Hz high-pass that
removes CTCSS, de-emphasis, the limiter — reads from or writes to `out`. **`scratch.real` therefore
still holds the untouched discriminator output when `process` returns.** The tap is free: no change
to the audio chain, no regression risk, and no reason to relax the high-pass.

### Layering

The hot path decides nothing.

- **Hot path** (`ChannelDSPCore.process`): two FIR decimation stages (÷12 then ÷4) plus a 20 Hz
  one-pole DC block, writing into a fixed ring. Two FIRs rather than a boxcar: an unfiltered boxcar
  aliases voice near 1.3 kHz down into the 60–300 Hz band at about −13 dB and creates false tone
  energy. Cost ≈ 0.6 Mmult/s; the ring is allocated in `configure`.
  The discriminator's DC *is* the tuning error, and is what feeds `freq_error_hz`.
- **Slow per-channel task**, normal priority, allocates freely: drains the ring, runs the detector,
  pushes telemetry. Every branchy accept/reject decision lives here.

The decimated rate is `r2 / round(r2/1000)` and must be carried as an exact `Double` — `r2` is
48 kHz at 2.4 MSPS but 51.2 kHz at 2.048 MSPS.

### Detector

Measured against synthesised NFM at a 0.5 s window, Goertzel evaluated exactly at each standard tone
frequency:

| case | detected | margin over next-best tone |
|---|---|---|
| 15% deviation (nominal) | correct | 8–11 dB |
| 5% deviation | correct | 8–11 dB |
| 2% deviation, noisy | correct | 7.5–11 dB |
| no tone, voice only | — | 0–2 dB |

A gate of "beat the next-best standard tone by at least 6 dB" separates cleanly with margin on both
sides and did not false-alarm on voice. The bank costs about 19k multiply-adds per window and 2
floats of state per tone.

The bank is a **gate, not the answer**. Its bin width at N=512 is ~1.95 Hz and the EIA ladder is
spaced as tightly as 2.3 Hz (67.0 / 69.3), so identity comes from a phase-slope frequency estimate
at the winning bin, taken across hops. Voice is rejected by requiring that estimate to be *stable*
for a whole second (eight hops at the tap's 1 kHz): a human pitch contour moves far more than 1 Hz
per 100 ms, but a synthesised one can hold a vowel still for three hops, and NOAA weather radio's
announcer was reported as a PL that way on 2026-09-14 (233.6 Hz, then 241.8, on a station that sends
none). The deviation must hold too, within a ratio of 1.5 across the horizon: a transmitter sends
its tone at one level, while a voice fundamental's level rises and falls with every syllable. The
numbers behind both, from the captures, are in `docs/plans/signal-views.md`, SV-13.

### What honest means here

This is invariant 12 applied to a second detector, and it is the easiest part to get wrong.

- **Report the measured frequency, not a snapped one.** When two standard tones both fall inside
  tolerance, report `tone_hz` and set `standard_tone_hz = 0`. Snapping to "nearest within ±1.5 Hz"
  on a 2.3 Hz ladder mislabels 67.0 as 69.3 and reports a guess as a measurement.
- **Confidence is a stated score, not a probability.** The formula lives in the proto comment, and
  the raw measurements (`tone_hz`, `deviation_hz`, `tone_snr_db`, `hops_agreeing`) are always
  populated so a client can threshold on them and ignore the score. Shipping a calibrated
  *P(correct)* would require a fixture corpus we do not have; without one, the calibration would
  itself be a guess presented as a measurement, which the invariant forbids.
- **No lock claim before fixtures.** `fixtures/` gains NFM voice + 100.0 Hz PL, the 67.0/69.3
  discrimination pair at 6/10/20 dB tone-to-band, mains hum with no PL, and PL with no voice.
- **Documented false positive:** 50 Hz mains hum lands on exactly 100.0 Hz, is stable, and passes
  every frequency test; 100.0 Hz is also one of the most common real PL tones. Only the deviation
  plausibility window rejects it, imperfectly. 60 Hz mains lands at 120 Hz, which is not a standard
  tone and is rejected cleanly. The user docs must state this.
- **Documented false positive, closed:** a synthesised voice. NOAA weather radio's announcer holds
  its pitch fundamental, which sits in the 60 to 260 Hz band, still enough for a 400 ms stability
  test and at 200 to 350 Hz of deviation, inside a transmitter's range. The second-long horizon and
  the deviation-ratio test above fixed it; the announcer's tap is a committed regression
  fixture (`engine/Tests/EngineCoreTests/Captures/noaa-wx2-auto.f32`).
- A tone identifies neither a talkgroup nor a person, and a repeater's output tone often differs
  from its input tone.

### DCS

Not a tone: a 134.4 bps NRZ stream at about ±750 Hz deviation carrying a repeating Golay(23,12)
codeword with a polarity variant. Same tap, same rate, same message with `kind = DCS`, a separate
detector. Ships after CTCSS, with no schema change. A DCS lock must suppress the CTCSS claim, since
its broadband sub-audible energy feeds the Goertzel bank.

### Deliberately deferred: tone squelch

Gating audio on the detector is the main reason operators use CTCSS, and it is the next step. It
ships only after the detector has a fixture record, because a false negative mutes the audio and the
user cannot tell why. `Channel` field 13 is held for `subaudible_squelch_hz`.

## Wire changes

All additive within v1. Field numbers are settled here once, because a field number can never be
reused once assigned.

```protobuf
// ---- bulk.proto : FftParams (1-3 in use) ----
FftAccumulation accumulation = 4;   // default SNAPSHOT = today's behaviour
uint32 looks_per_row = 5;           // descriptor answer only; 0 in a request

enum FftAccumulation {
  FFT_ACCUMULATION_UNSPECIFIED = 0;
  SNAPSHOT = 1;   // one periodogram per row (current behaviour)
  MEAN = 2;       // power mean over the row: stable floor, dilutes short bursts
  MAX = 3;        // max over the row: catches bursts; floor sits ~6 dB high
}
// No new StreamKind. FFT stays capture-scoped.

// ---- telemetry.proto ----
enum TelemetryType { ...; SUB_AUDIBLE = 5; }                // 1-4 in use
message TelemetryMsg { ...; SubAudible sub_audible = 7; }   // 3-6 in use

message Meter {                     // 1-4 unchanged, still 10 Hz, still full state
  double audio_dbfs      = 5;   // demodulated level; NaN before the first block
  double audio_peak_dbfs = 6;   // peak over the meter interval; floored at -120
  double deviation_hz    = 7;   // FM only, from the calibrated discriminator
  double freq_error_hz   = 8;   // discriminator DC; FM and squelch-open only
}

message SquelchTransition {         // 1-2 unchanged; 3-5 set on the close edge only
  uint64 duration_samples = 3;  // CAPTURE samples: SampleTime's rate, which every
                                // client knows; the channel's own rate is not on the wire
  double peak_snr_db      = 4;
  double peak_audio_dbfs  = 5;
  reserved 6;                   // SubAudible tone, when CTCSS lands
}

message SubAudible {
  string channel_id       = 1;
  SubAudibleKind kind     = 2;  // NONE | CTCSS | DCS
  double tone_hz          = 3;  // measured; 0 unless CTCSS
  double standard_tone_hz = 4;  // classified; 0 = measured but not classifiable
  uint32 dcs_code         = 5;  // octal as decimal (023 -> 23); 0 unless DCS
  bool   dcs_inverted     = 6;
  double deviation_hz     = 7;
  double tone_snr_db      = 8;  // tone against the 60-260 Hz residue
  double confidence       = 9;  // stated score, not a probability; formula in the comment
  SampleTime first_seen   = 10;
  uint32 hops_agreeing    = 11;
}
enum SubAudibleKind { SUB_AUDIBLE_KIND_UNSPECIFIED = 0; NONE = 1; CTCSS = 2; DCS = 3; }

// ---- control.proto : Channel (1-11 in use) ----
bool subaudible_detect = 12;    // NFM only; ignored for other modes
// 13 held for subaudible_squelch_hz
```

`SubAudible` is edge-triggered on identity or confidence-band change, plus a 1 Hz heartbeat while
held (the telemetry plane has no `GetState`), and carries full state on every message per
invariant 6.

Engine side: `ChannelTelemetryRecord.Kind` gains `.subAudible`; the POD record widens and carries
floats only — no `String` on the hot path, labels are applied in the mapping layer.

## Build order

Each of 1, 2 and 4 is independently shippable and improves `ley` on its own.

1. **`SquelchTransition` close-side summary + the transmission table.** Three fields the daemon
   already has, two compares in the hot path, zero DSP. The cheapest useful item here.
2. **`Meter` fields 5–8 + the two-bar channel view.** vDSP over data already in cache.
3. **Ladder accumulation.** It has no user-visible output, so it is the item most likely to be
   skipped. It must land *before* the waterfall, not after.
4. **The scrolling shaded waterfall** (`ley waterfall`) and `ui.Glyphs.Shade`.
5. **CTCSS fixtures**, then the detector, the `PL` line and `--json`.
6. **DCS**, same message, no schema change.

## Documentation debt this creates

- `docs/plans/build-order.md` item 14 and `docs/plans/user-stories.md` say "braille-cell waterfall"; both become
  "shaded-cell", with the reason (colour-off legibility) recorded here.
- `data-planes.md` gains a note that the FFT ladder can integrate over a row, and what `MAX`
  does to the apparent noise floor.
- `docs/dev/cli-style.md` gains the `Shade` glyph row and the waterfall rules.
