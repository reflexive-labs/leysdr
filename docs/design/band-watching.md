# Design: Band Watching — Persistence, Burst Capture, Occupancy

Status: partial. Persistence (`ley phosphor`) and the stationary transmission log (`ley monitor`)
are implemented. Channel-grid occupancy and burst capture are not. Companion to `signal-views.md`
and `data-planes.md`.

## Context

`ley spectrum` shows current energy and `ley waterfall` shows changes at up to 30 rows per second.
Those rates suit voice and broadcast carriers that last seconds. They cannot resolve the symbol
shape of a short LoRa transmission. This design covers longer-term persistence, stationary
monitoring and the retained high-resolution capture required for burst shape.

## What LoRa actually looks like, and why 30 rows a second is not enough

LoRa is chirp spread spectrum: every symbol is a linear chirp sweeping the channel bandwidth. A
packet draws a run of parallel diagonals (the preamble), two of the opposite slope (the sync word),
then data. Nothing else on the band looks like it, which is why the waterfall is the usual way to
spot it. On a single spectrum frame the same packet is a flat-topped rectangle: you
learn the bandwidth and the centre and nothing else, because a chirp's time-averaged spectrum is
flat by construction.

Symbol time is `2^SF / BW`:

| SF | at 125 kHz |
|---|---|
| 7 | 1.02 ms |
| 9 | 4.10 ms |
| 12 | 32.8 ms |

`DefaultSpectrumLadder.maxRowsPerSecond` is **30**, so our fastest row is 33 ms. An entire SF7
transmission appears in one or two rows: a bright smudge that shows something happened but loses the
only feature that identifies it. Even SF12 gets roughly one row per symbol, which cannot
show a slope.

To draw a diagonal you want several rows per symbol, so SF7 needs rows of about 250 µs: **4,000
rows a second**. That is not a display rate: no terminal renders it and nobody can read it.
Raising the cap does not help; this needs a different kind of view.

### How big a chirp is, no matter what you do

No FFT choice can beat this limit. A spectrogram window
trades frequency resolution against time resolution, and the number of resolution cells a chirp
occupies is set by its time-bandwidth product, `BW × T = 2^SF`. Along the diagonal that is about
`sqrt(2^SF)` cells:

- SF7 → about **11 × 11 cells**
- SF12 → about **64 × 64 cells**

So a LoRa chirp is an 11-cell diagonal at the fastest spreading factor and a 64-cell one at the
slowest, and that is true whether you capture at 250 kHz or 2.4 MHz. **A terminal is large enough
for this**: 90 columns is more than enough. The problem is not frequency resolution or screen size.
It is that the 10 ms of interest is buried in a stream too fast to watch.

The optimum window length falls out of the same arithmetic: for a chirp rate `BW/T`, smear is
minimised when the window is about `sqrt(T/BW)`, which at 2.4 MSPS and SF7/125 kHz is around 217
samples. The ladder's smallest size, 256, is already the right one, so burst capture needs no new
FFT sizes.

## Three views, in value order

### 1. Persistence

A 2D histogram of the spectrum: for each column, how often each level has been seen. Bright means
usual, faint means rare but present. It is the standard tool for finding intermittent signals,
it is what a phosphor analyser and Fosphor draw, and of the views here it is the only one that
**works at the row rates we already have**, because it accumulates over time instead of resolving
it.

This suits an ISM band: LoRaWAN US915 uplink is 64 channels of 125 kHz on a 200 kHz
grid from 902.3 MHz, so a 2.4 MHz span at 910 MHz covers about a dozen of them, each carrying short
bursts at a low duty cycle. On a live spectrum you see noise with occasional flickers. On a
persistence display the occupied channels show as faint but clear plateaus, and the
unoccupied ones stay flat.

- **Where it runs.** `PersistenceAccumulator` runs in the daemon on the existing FFT ladder. Each
  frame contains the full histogram, so a dropped frame does not lose accumulated state.
- **Cost.** One `bins × levels` counter table. At 1024 bins and 64 levels of `uint16` that is
  128 KB, updated once per row.
- **Decay.** A pure histogram never forgets, so a band that was busy an hour ago still looks busy.
  Counts halve on a schedule (an exponential window), and the header states the window, because
  "usual" needs a time span.
- **Drawing it.** One cell per column, shade by the *mode or a high percentile* of that column's
  histogram rather than its current value. This reuses `ui.Glyphs.Shade` and the level ramp
  unchanged.

### 2. Burst capture

The only view that shows a LoRa chirp: stop scrolling, and capture.

**Trigger, capture a window around it, then draw a fixed image you can zoom.** This is what a
spectrum analyser's single-sweep-with-trigger does and what a logic analyser does, and it is the
same idea as the DVR story in `docs/plans/user-stories.md` — the difference is scale, milliseconds
rather than minutes.

This needs **pre-trigger IQ retention in the daemon**, the one real cost in this document. You
cannot capture the 20 ms *before* a burst unless something was already holding it. Streaming
full-rate IQ to the client so it can keep its own history is wrong for two reasons: it is 19 MB/s at
2.4 MSPS, and it moves the decision client-side.

- `CaptureDSPCore` already owns a `BlockRing` of 64 slots × 16384 cf32 samples — the device-to-DSP
  handoff, drained continuously. A retention ring is the same shape with the opposite policy: keep
  the last N seconds, overwrite the oldest. At 2.4 MSPS one second is 19 MB, so a 2 s ring is 38 MB,
  which is why this is opt-in per capture rather than always on.
- **The trigger.** The scan and monitor detector can supply an energy trigger. Burst capture also
  needs an explicit client trigger so an operator can retain the interval that just ended. Neither
  trigger currently writes a retained IQ window.
- **What comes back.** Not IQ. The daemon computes the high-resolution spectrogram (256-point FFTs,
  75% overlap, which at 2.4 MSPS is ~37,500 rows/s and is trivial offline) and serves *that* as an
  FFT stream with a `StreamPosition` other than LIVE. Invariant 2 holds, and the client renders.
  This is the first real use of the `start`/`StreamPosition` field, which v0 documents as LIVE-only.
- **Zoom is required.** A 40-row terminal over a 70 ms SF7 packet is 1.75 ms a row, still too
  coarse. Over 10 ms it is 250 µs a row — four rows per symbol, and the diagonals appear. So the
  view must let the user narrow the window, which a stored spectrogram makes cheap and a live
  stream cannot do at all.

### 3. Channel occupancy

For ISM monitoring the question usually is not "what does this packet look like" but **which
channels are busy, how often, and when**. That is a table, not a picture:

```
CHANNEL          BUSY   BURSTS   LONGEST   LAST
909.9 MHz        2.1%       47     84 ms   3 s ago
910.1 MHz        0.4%        9     71 ms   41 s ago
910.3 MHz          --        0         --  --
```

It falls out of the same accumulator persistence uses, plus a channel grid. The grid should be
given (`--channels 902.3M:200k:64` or a named band plan) rather than guessed: inferring channel
edges from energy is guessing, which invariant 12 forbids, and a wrong guess silently misattributes
traffic.

This is also the only one of the three views that is useful left running for an hour.

## What this is not

- **Not a LoRa demodulator.** Dechirping (multiplying by a conjugate chirp so each symbol becomes a
  tone) turns the diagonals into horizontal lines and recovers symbol values. That is a decoder, it
  belongs behind `DemodMode`, and it is a much larger piece of work than any of the above. Nothing
  here should claim to identify a signal *as* LoRa; the operator reads the diagonals.
- **Not a constellation or eye diagram.** Both are standard SDR views and both are meaningless for
  chirp spread spectrum, which has no symbol constellation. They belong with a linear digital
  demodulator, if one is added.
- **Not a raised ladder rate cap.** 30 rows a second is the right cap for a scrolling display.
  Needing 4,000 calls for a different feature, not a higher cap.

## Wire status

- **Persistence is implemented** as `StreamKind.PERSISTENCE` with `PersistenceParams`; each frame
  is a complete `bins × levels` histogram.
- **Stationary monitoring is implemented** as `MonitorConfig`; detections use the existing
  telemetry stream and `ley monitor` folds them over time.
- **Burst capture is not implemented.** It requires a retained IQ window, a non-live
  `StreamPosition`, trigger control and a stored spectrogram response.
- **Channel-grid occupancy is not implemented.** It requires full per-channel counters, probably
  as a telemetry snapshot rather than client-computed DSP state.
