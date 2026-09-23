# Design: Band Watching — Persistence, Burst Capture, Occupancy

Status: draft. Companion to `signal-views.md` (which owns the spectrum, waterfall and channel
views this builds on) and `data-planes.md` (which owns the plane split).

## Context

`ley spectrum` answers "what is on the air now" and `ley waterfall` answers "did it start and stop".
Both are tuned for signals a person can hear: voice on a repeater, a broadcast carrier, something
that lasts seconds. Watching an ISM band is a different job. The question that prompted this
document was: *monitoring 910 MHz LoRa, is the waterfall all there is?*

The short answer: the waterfall is the right display, but **ours cannot resolve the signal**. The
reasons below set the rest of the design.

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
transmission lands in one or two rows: a bright smudge that shows something happened but loses the
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

- **Where it runs.** Daemon-side, as an accumulator on the existing FFT ladder — the client must not
  be handed rows to histogram itself (invariant 2), and a client that joins late should see the
  history rather than starting from nothing.
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
- **The trigger.** `Detection` exists in `CoreProtocols.swift` and in the proto, and **has no
  implementation** — `DetectorEngine` is a declared interface and nothing conforms to it. So this
  work item builds the v0 energy detector the proto already defines, or accepts an explicit
  client-issued trigger, and should probably do both: an operator watching a waterfall wants to
  press a key and keep what just happened.
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
  demodulator, if one ever lands.
- **Not a raised ladder rate cap.** 30 rows a second is the right cap for a scrolling display.
  Needing 4,000 calls for a different feature, not a higher cap.

## Wire changes

Sketched, not settled — each work item pins its own field numbers when it lands, following the
`signal-views.md` precedent of settling them in one place.

- **Persistence**: a new `FftAccumulation` value is the wrong home (it changes what a row *is*).
  Likely a separate `StreamKind` or a telemetry snapshot, since a late subscriber wants the whole
  histogram, not a stream of deltas — and invariant 6 says events carry full state.
- **Burst capture**: `SubscribeRequest.start` (`StreamPosition`) gains a non-LIVE meaning, plus a
  capture-level retention setting and a trigger RPC or telemetry type.
- **Occupancy**: a telemetry type carrying the per-channel counters, full state per message.

## Build order

1. **Persistence.** No new plane, no retention buffer, works at today's row rates, and it is the
   view most likely to be used daily. It also proves the accumulator that occupancy reuses.
2. **Channel occupancy.** Same accumulator plus a given channel grid; the highest value per line of
   code for actually watching a band.
3. **Burst capture.** The largest piece by far — retention ring, a detector that does not yet
   exist, non-LIVE stream positions — and the only one that shows a chirp. Build it last, and only
   if 1 and 2 have not already answered the question.
