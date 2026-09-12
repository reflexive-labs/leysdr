# Design: Audio meters — `ley levels` and `ley waveform`

Status: implemented. Companion to `design-scope.md` (the millisecond view, which stays), to
`design-signal-views.md` (the spectrum, waterfall and channel views) and to `cli-style.md`, whose
palette and layout rules every picture here obeys. The point of this document is the visual
language, because a meter that is honest but dead-looking is not looked at.

## Context

The scope shows a few milliseconds and redraws twenty times a second: for a tone that is a still
picture, for speech it is a strobe. The questions a person asks about audio are answered by two
other instruments, and audio equipment settled their look decades ago:

1. **Level by frequency** — the spectrum-analyser display on a hi-fi or a rack unit: vertical
   bars per octave band, dancing, each with a peak cap that hangs and falls. "Is that voice or
   noise, is there bass, is there a tone under it."
2. **Level over time** — the clip in an editor: a symmetric envelope scrolling under a playhead.
   "Did I key up, how loud, for how long, was the gap really a gap."

Both are renderings over a stream of daemon-computed numbers. The first needs one new stream.

## The stream: audio spectrum rows

`Bulk.Subscribe` with `kind = FFT` and a **channel** as the source (today FFT sources are
captures). `FftParams` apply as they do for the radio: `bins` (256 … 4096, the design's cap for
this path), `rows_per_second` (≤ 20), `bin_format`; a new additive `AudioTap tap` picks the audio
or the demod tap, reusing the enum from `AudioParams`. The daemon computes a real FFT over a
Hann-windowed sliding window of the tap's samples (2048 at 48 kHz is 43 ms and 23 Hz per bin,
enough to put a PL tone in its own band) and answers rows of dB per bin from 0 Hz to half the
audio rate; the descriptor's `center_hz` and `span_hz` are `rate/4` and `rate/2`, so the row
layout every FFT client already understands holds. Allocation-free like the ladder: scratch sized
at subscribe, one transform per row, no per-block work for channels nobody is listening to this
way. `rawIQ` channels have no audio and refuse. The fake serves rows built from its synthetic
tone and PL.

Band levels are sums of bins in power, divided by the window's equivalent noise bandwidth (1.5 for
Hann) and back to dB; that is aggregation over the daemon's row, the same kind of presentation as
`spectrum`'s peak list, and the client does it. The correction is what makes a band level a level:
a Hann-windowed tone leaks a quarter of its power into each neighbouring bin, so the bins of a band
add up to about one and a half times what is really in it, and broadband power is spread by the
same factor. A band too narrow to hold a bin centre -- the low third-octaves against a coarse row --
reads the bin its centre falls in, corrected the same way, so it is a bar rather than a gap and the
bars beside it do not step 1.76 dB where the signal is flat. Both `levels` and the later `sonogram`
(a waterfall over the same rows) read this one stream.

## `ley levels`

```
147.435 MHz NFM  tap demod  squelch open  PL 100.0 Hz
   0 ┤                                                 ▁▁
  -6 ┤                                                 ██
 -12 ┤                        ▂▂                       ██
 -18 ┼ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─██─ ─ ─ ─ ▅▅ ─ ─ ─ ─ ─ ─ ██ ─ ██ ─ ─
 -24 ┤                        ██        ██             ██   ██
 -30 ┤             ▃▃   ▇▇    ██   ██   ██   ▆▆        ██   ██
 -40 ┤   ▅▅        ██   ██    ██   ██   ██   ██   ▄▄   ██   ██
 -50 ┤   ██   ▂▂   ██   ██    ██   ██   ██   ██   ██   ██   ██
 -60 ┤   ░░   ░░   ░░   ░░    ░░   ░░   ░░   ░░   ░░   ░░   ░░
     └───────────────────────────────────────────────────┴────┴───
       63  125  250  500   1k   2k   4k   8k  16k Hz    rms  peak
                                                        -18   -9 dBFS
```

**One still, or the meter.** The bare verb draws one frame from the first complete row — the bands
as they were measured, no ballistics and no caps — and exits, exactly as `spectrum` does;
the transcript above is that still. `--watch` is the meter itself, twenty frames a second until
Ctrl-C, and `--rate` and `--count` belong to it.

**What is on screen.** Nine octave bands on the ISO centres (`--bands third` gives twenty-five
at 100 columns and up), and at the right a master pair, `rms` and `peak`, drawn as two more bars
so the whole thing reads as one instrument. A dB gutter on the left with the marks a meter carries
(0, −6, −12, −18, −24, −30, −40, −50, −60), the −18 dBFS line drawn across as a dashed `Muted`
rule: that is the alignment level on every professional meter, and it gives the eye a horizon the
way the noise-floor rule does in `spectrum`. Band labels under the bars; the current numbers
under the master pair, plain ink, because they are the answer.

**The scale is a meter's, not a chart's.** Fine at the top and coarse at the bottom: 6 dB per
row from 0 to −24, then 10 dB per row to −60. A voice living at −20 gets four rows of resolution
where it matters and the floor is still on screen. Held, never fitted to the data (`cli-style.md`
section 5): a bar of a given height means the same dB tomorrow.

**Bars are LED ladders.** Two cells wide with a one-cell gap (three wide when the width allows),
built from the column ramp ` ▁▂▃▄▅▆▇█`, so each row carries eight sub-levels and a bar has about a
hundred positions over its height. The lit part is inked with the **level ramp** (`ui.Style.Level`),
cold at −60 and hot at 0, which is the guide's one sanctioned use of colour depth and already
the hue rule of the spectrum and waterfall: green in the working range, amber approaching −6, red
at the top. The **unlit part is drawn, faintly**: `░` in `Muted`. Every real LED meter shows its
dark segments, and it is what lets the eye read a level against the scale when nothing is playing.
A bar at or over 0 dBFS lights `OVER` in `Err` above it and holds it for two seconds.

**A shut squelch is not a level.** While `METER` reports `squelch_open` false nothing is passing:
every ladder draws unlit, the header says `squelch closed`, and the caps stop where they are. The
spectrum keeps arriving behind it — on the demod tap it is the detector's own noise — and a lit
bar would report that as sound. The rows still go out under `--json`, with `squelch_open` on them.
Between words the squelch is open, which is where the demod tap's PL stands.

**Ballistics are what make it alive.** Attack is instant: a bar rises to the row's value within
one frame. Release is slow, 20 dB a second, so a syllable leaves a trail the eye can follow instead
of a flicker. The **peak cap** (`━` in `Label`, drawn at its own sub-row) sits on the highest value
of the last 1.5 s and then falls at 10 dB a second. These are presentation over the daemon's rows:
the numbers printed under the master pair are the current row's own values, `--json` carries the
raw rows, and nothing smoothed is ever reported as a measurement.

**Degradation.** With colour off the ramp is height and the cap is still bold; with `--ascii` the
ladder is ` .:-=+*#%`, the unlit segment `.`, the cap `=`, the horizon `- -`. Strip the styling
and the plain text is the same picture, per the guide's identity rule. Width below 60 columns
drops the master pair's labels to one line; below 44 it drops to six bands.

**Motion.** Under `--watch`, twenty frames a second, redrawn in place with the writer `spectrum
--watch` uses.

Flags: `[frequency|preset|channel]` and the tune flags as `scope` takes them, `--tap`, `--bands
octave|third`, `--watch`, `--rate`, `--count`, `--width`, `--height` (default 12, clamped to the
terminal like the spectrum chart).

## `ley waveform`

```
147.435 MHz NFM  tap audio  10 s  scale ±0.5  squelch open
+.5│                                     ▄▄▄▄████▄▄▄▄                        ▏
   │                 ▄▄▄▄▄▄▄▄         ▄████████████████▄     ▄███████▄   ███ ▏
  0│─────────────────████████─────────██████████████████─────█████████───███─▏
   │                 ▀▀▀▀▀▀▀▀         ▀████████████████▀     ▀███████▀   ███ ▏
-.5│                                     ▀▀▀▀████▀▀▀▀                        ▏
   ─│──────────│──────────│──────────│──────────│──────────│──────────│───────
   -10 s       -8 s       -6 s       -4 s       -2 s       -0 s
```

Newest at the right under a `Label` playhead, scrolling left. Each column covers its slice of
the window (`--seconds 10` across 77 columns is 130 ms) and draws the **peak envelope** of that
slice, symmetric about the centre line, the way an editor draws a clip: filled with block glyphs,
with half-cell precision at either edge. The column's ink is the level ramp for its peak against
the scale the frame is drawn at, so the loudest thing on screen is hot and a quiet passage is cold
before the height says so. A centre rule runs through silence. A squelch-closed slice is **left
blank**, not drawn at zero: the floor draws as space (guide, section 5), and a gap between
transmissions then looks like a gap. `--scale` as on the scope, `auto` by default here because the point is the shape. The DC
offset of the demod tap is removed before drawing (the scope shows it; the editor's view would only
shift the clip off its centre line), and said in the header.

Flags as `scope`, with `--seconds 2..120` in place of `--window` and no trigger.

## What it costs

Engine M (the channel-sourced FFT stream: sliding window, real FFT, dB rows, tap selection,
refusal on `rawIQ`), proto S (a channel as an FFT source, the tap on `FftParams`, comments), fake S,
`ley levels` M (the ladder renderer, ballistics, band summing, tests with goldens in both
alphabets), `ley waveform` S–M (envelope renderer over the audio stream the scope already uses),
docs S. The sonogram afterwards is S over the same stream.
