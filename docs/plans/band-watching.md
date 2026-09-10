# Plan: Band Watching

Implements `docs/design-band-watching.md`. Build order is deliberately the inverse of how
interesting the items are: BW-1 needs no new plane and works at today's row rates, BW-3 needs a
retention ring and a detector that does not exist yet.

## BW-1 `[x]` Persistence (`ley phosphor`)

A 2D histogram of the spectrum: frequency across, level up, shade by how often that pair has
occurred. Bright means usual, faint means rare-but-real. The only view here that works at the row
rates the ladder already serves, because it accumulates over time instead of resolving it.

- **Wire.** New `StreamKind PERSISTENCE`, `PersistenceParams { bins, levels, floor_db, range_db,
  half_life_seconds, rows_per_second }`, payload `bins × levels` LE `uint16` counts, bin-major.
  Delivery LATEST_WINS: a dropped frame costs nothing, since every frame is the whole state.
- **Daemon.** A `PersistenceAccumulator` fed from the ladder as an ordinary `SpectrumSink`, so the
  FFT work is shared rather than duplicated. Counts halve every half-life, which keeps them bounded
  and makes "usual" mean "usual lately".
- **Scale.** The client supplies `floor_db` and `range_db`; the daemon does not guess. `ley phosphor`
  takes one FFT row first to find the floor, exactly as a one-shot `ley spectrum` does, and the
  descriptor echoes what was used. A daemon-chosen scale would have to be reported in the descriptor
  before any row has arrived, which it cannot be.
- **CLI.** `ley phosphor [frequency]`, its own verb rather than a `ley spectrum` flag: the payload
  is 2D where a spectrum row is 1D, and the render is a density field rather than a trace. The
  capture setup, axis and header are already shared through `session.openBand` and `spectrumTicks`.
  Named `phosphor` because `persist` collides with `--persistent`, which means something else
  entirely on `ley tune`.

**The shading curve is the feature, and the first cut got it wrong.** A linear normaliser against
the frame's peak makes persistence useless: the shade ramp has four steps, so anything under a
quarter of the peak count draws as blank, and a signal present 1% of the time -- exactly what this
display exists to find -- was invisible. `shadeFor` is `log1p(count)/log1p(peak)`, which keeps a 1%
signal at the first step while still putting a permanent one at full brightness. Every phosphor
display compresses the count for the same reason.

Two smaller corrections: the header reported a row count taken from the frame's sample index, which
is not a row count and is not on the wire at all (the half-life is the honest statement of the
window, so the number is gone); and the legend line overflowed a 40-column terminal.

Tests: `TestPhosphorRareSignalStaysVisible` (which asserts the linear version would have failed, so
it cannot quietly regress), `TestPhosphorDrawsRareAndSteadyAlike`, `TestPhosphorStripsToPlain` at
40/80/160 in both alphabets, `TestPhosphorRejectsAShortPayload`,
`TestPhosphorHeaderStatesTheWindow`; and engine-side `PersistenceTests` -- a steady carrier lands in
one level bucket while noise of the same mean spreads across several, counts decay, counts saturate
rather than wrap, out-of-range levels clamp instead of dropping.

Verified on the real daemon against `two_nfm.cf32`: both carriers rise clear of a noise floor whose
distribution is visible as a gradient, and the columns the carriers occupy show the noise displaced.

## BW-2 `[ ]` Channel occupancy

Same accumulator plus a **given** channel grid (`--channels 902.3M:200k:64` or a named band plan).
Reports per channel: busy fraction, burst count, longest burst, time since last. A table, not a
picture, and the only view here that survives being left running for an hour.

Inferring channel edges from energy is out: it silently misattributes traffic, which is the class of
thing invariant 12 exists to stop.

**Design input, measured on a real 915 ISM band before building this.** A first cut at the occupancy
metric compared each channel's *max over its bins* against the *band's median bin*, and reported two
channels as 99-100% busy. That was an artefact: the maximum of ~53 noise bins sits about 8 dB over
the median of all of them, so a 12 dB threshold had only 4 dB of real margin and quiet channels
tripped constantly. It is the same max-versus-median bias that made `ley spectrum`'s scale
misbehave, in a new place.

Comparing each channel against **its own** 10th percentile over time instead separates three states
cleanly, and those are the three the table should report:

```
chan  MHz     quiet  median   peak   busy%   what it is
34    909.1   -41.3   -38.1  -25.5    0.3%   CONTINUOUS: quiet level 11 dB over the band
39    910.1   -35.5   -32.2  -12.4    0.3%   CONTINUOUS: 18 dB over the band
38    909.9   -52.0   -50.5  -10.8    1.3%   bursty: 41 dB excursions, 1% of the time
41    910.5   -53.2   -51.5  -36.2    3.3%   bursty
36    909.5   -53.1   -51.7  -46.1    0.0%   quiet
```

So the metric is per-channel, never band-relative, and "busy" and "continuously occupied" are
different columns: a channel that is *always* loud has a busy fraction near zero against its own
baseline, which is correct and would read as a bug if the table only had one number. `ley phosphor`
already draws this distinction correctly -- the two continuous channels are its dense clumps and the
bursty ones its faint scattered marks.

## BW-3 `[ ]` Burst capture

The only view that shows a LoRa chirp, and by far the largest piece.

- Pre-trigger IQ retention in the daemon: the same shape as `CaptureDSPCore`'s existing `BlockRing`
  with the opposite policy. ~19 MB per second at 2.4 MSPS, so opt-in per capture.
- A trigger. `Detection` is declared in `CoreProtocols.swift` and in the proto and **has no
  implementation**; this builds the v0 energy detector the proto already promises, plus an explicit
  client-issued trigger, because an operator watching a waterfall wants to keep what just happened.
- The daemon computes the high-resolution spectrogram and serves it as an FFT stream at a non-LIVE
  `StreamPosition` — the first use of that field. Invariant 2 holds; the client renders.
- Zoom is the feature, not a nicety: 40 rows over a 70 ms SF7 packet is too coarse to show a
  diagonal, and over 10 ms it is four rows a symbol.

## Decisions

- A new `FftAccumulation` value is the wrong home for persistence: it changes what a row *is*, and
  a persistence frame is 2D where an FFT row is 1D.
- No LoRa demodulator, no constellation or eye diagram (both meaningless for chirp spread spectrum),
  and no raising `maxRowsPerSecond`. Needing 4000 rows a second is a different feature, not a
  bigger number.
