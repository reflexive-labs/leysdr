# Design: Scan

Status: decided, implemented in Milestone D.13. Companion to `design-semantic-tier.md`, which
introduced the detector and the scan resource in prose; this doc is the version with numbers in it.

## The story

> As an operator, I can `ley scan 144M..148M` and get a list of detected carriers with frequency,
> bandwidth, and SNR.

Build order puts this at D.13 — "Detector (energy detection, noise floor, persistence tracking);
telemetry plane; `ley scan`" — ahead of the job store at D.15. The wire contract for it has been
sitting in `jobs.proto` and `telemetry.proto` since the protos were written, unimplemented:
`ScanConfig`, `Scan`, `NoiseFloorSegment`, `Detection`, `TelemetryType.DETECTION`, and a `Detector`
protocol in `CoreProtocols.swift` with exactly the signature a spectrum sink needs. This work fills
them in rather than inventing a shape beside them.

## What a scan is

A sweep points the radio at a series of centre frequencies, looks at the spectrum at each one, and
reports the carriers it is confident about. Everything hard is in the word *confident*.

The failure mode this design exists to prevent has already happened twice in this repo. The spectrum
chart's peak list once used a 6 dB threshold and four of five "loudest bins" were random noise
quoted like carriers. The ISM occupancy measurement compared each channel's loudest bin against the
band's median and reported quiet channels as 99% busy, because the maximum of N noise draws sits
about 8 dB above their median by chance alone. `docs/plans/cli-papercuts.md` recorded the general
form of the bug and reserved the fix for exactly this work:

> The honest quantity scales with bin count, because the maximum of N noise bins grows with ln N …
> If `scan` ever wants real detection it needs the scaled form, and that is a design change rather
> than a papercut.

So the detector below is specified by its false-alarm rate, and every number in it was measured by
Monte Carlo before it was written down.

## The sweep

### Geometry

A capture at 2.4 MSPS sees 2.4 MHz. Two parts of it cannot be believed:

- **The centre.** The RTL-SDR's DC offset lands on the exact capture centre, and nothing in the
  pipeline corrects it — the driver applies only the `(u − 127.5)/127.5` conversion. A detector
  thresholding against a noise floor would report a carrier in the middle of every step, forever.
- **The edges.** The tuner's IF filter rolls off, so the outer few percent read low and a real
  signal there looks weaker than it is.

So a step analyses only the two quarter-bands between **5% and 45% of the span** either side of
centre, and the sweep advances by **half a window**, `(0.45 − 0.05) × span`. That is what makes
step *k+1*'s lower quarter land on step *k*'s DC hole, so the hole is covered instead of skipped.
Two extra steps sit outside the requested range, one at each end, placed so the first and last
hertz asked for fall inside a window rather than on its edge.

144–148 MHz at 2.4 MSPS is therefore **seven steps**, not the four a naive `range/span` would give.
What the extra steps buy is the thing the rest of the design leans on: **most of the range is seen
at two different tuner settings.** Every artefact that is referenced to the local oscillator — the
IQ image above all — moves when the tuner moves, and a real carrier does not.

Coverage is complete: `SweepPlanTests.testEveryFrequencyInRangeIsLookedAt` walks four ranges at four
sample rates and asserts no frequency inside the covered range falls outside every window. The DC
hole is the one place that gets a single look; covering it twice would mean halving the advance and
doubling the sweep, so instead each detection carries how many looks it had and the operator can
see which ones are single-sourced.

### Settling, and why it is 218 ms and not 1 ms

Retune is cheap on the control plane — `device.tune`, set an atomic, tell the channels — and it
stops nothing. Two things are still in flight afterwards:

- **librtlsdr's USB queue.** `rtlsdr_read_async(d, cb, ctx, 32, 32768)` keeps 32 buffers of 32768
  bytes. At two bytes per complex sample that is 524 288 samples, **218 ms at 2.4 MSPS**, captured
  at the old frequency and delivered after the new one is set.
- **The capture's own block ring**, 64 slots of 16384 samples, which `retune` does not drain
  (only `setSampleRate` does).

The tuner PLL relocks in well under a millisecond; it is not the problem. The problem is that the
ladder stamps every row with the centre frequency in force *when the row is computed*, so rows
straddling a hop are mislabelled in both directions — energy attributed to a frequency the radio was
not listening to. That is precisely the quiet wrong answer a scan must not produce.

The fix is to ask the device how much it has in flight. `RadioDevice` gains `inFlightSamples`, which
RTL-SDR answers from its own buffer geometry and a file device answers 0, and the sweep discards
every row whose samples begin before `hopIndex + inFlightSamples + ringDepth + margin`. The sample
timeline is monotonic across a retune (the anchor is not republished and the index does not reset),
so this arithmetic is exact rather than a guess about wall-clock timing.

### Gain is pinned for the sweep

`RTLSDRDevice` opens with `gain = .auto`, which means the tuner's own AGC moves after every hop and
whenever a strong signal enters the span. SNR measured against a moving reference is not a number.
Worse, a gain step in the middle of a dwell fakes a threshold crossing in the early sub-blocks and
suppresses a real one in the later ones.

So the sweep pins manual gain for its whole duration: if the capture is in auto it reads the value
the driver settled on, freezes it, and restores the previous setting on release. The pinned gain is
recorded in the `Scan` (`gains`), because a scan run at a different gain is a different measurement
and a scan that does not say which one it was cannot be compared with another.

This also gives the operator the standard front-end-overload test by hand: intermodulation products
fall about 3 dB for every dB of attenuation while real signals fall 1 dB, so a signal that survives
`--gain 20` was real.

## The detector

Daemon-side, as an accumulator on the existing FFT ladder (invariant 2). It implements the
`Detector` protocol that has been declared and unimplemented since the protos were written, and
taps the ladder through `SpectrumSink` the way `PersistenceFrameSink` already does.

### What a row is

`.mean` accumulation: the linear-power mean of the looks taken across the row interval. Not `.max`,
whose noise floor reads a few dB high because the maximum of N draws is biased up — the exact bias
that produced the ISM occupancy bug. Not `.snapshot`, which at 2.4 MSPS looks at 0.17% of a 250 ms
row.

The consequence is worth stating plainly rather than discovering: a row is only as honest about a
burst as the fraction of itself it looked at. A 1024-point FFT covers 1024 of every 16384-sample
block, so a scan sees about 6% of the dwell. A carrier that is on throughout the dwell is found; a
200 ms packet may or may not be. **Scan answers "what is sitting on this band", not "what
transmitted during these four seconds".** Duty cycle is what `ley phosphor` and the band-watching
accumulator are for.

### M, and the bug that was nearly shipped

Every number below depends on **M**, the number of looks averaged into a row, because the
distribution of an averaged bin is Gamma with shape M. The ladder knows M, and until this work it
threw it away: `looksPerRow` on the subscription is a *cap* of 64, while the actual count is
however many blocks arrived during the row interval — two to eight at typical rates, not sixteen.
Assuming sixteen when the truth is two puts the threshold **4 dB** too low, silently, and floods the
output with noise.

So `SpectrumSink.write` gains a `looks:` argument. The ladder already has the number and now hands
it over, and the detector computes its threshold per row from the M it actually got. The sweep also
*chooses* M by choosing the row rate — at 2.4 MSPS blocks arrive 146 times a second, so 9.2 rows/s
gives M = 16 — but it verifies rather than assumes.

### The noise floor

A local median, CFAR-style: for each bin, the median of 96 reference bins either side, skipping a
96-bin guard band so that a wide signal does not raise its own floor.

A single median per row was the first design and it is wrong for a measured reason. The R820T's IF
response plus the RTL2832's decimation skirt tilt the floor several dB across the analysis windows —
the same magnitude as the detection threshold itself. Measured against a synthetic 12 dB edge-to-edge
droop:

```
floor model          inner quarter    outer quarter
one median per row       +3.03 dB        -6.37 dB      <- 9 dB of error across the row
sliding 256 bins         +0.24 dB        -1.06 dB
sliding 128 bins         +0.05 dB        -0.29 dB
sliding  64 bins         -0.03 dB        -0.10 dB
```

The cost of going local is estimator noise, and it is small: measured false-alarm rates for window
sizes from 32 to 512 bins all land within 20% of nominal. The guard band is what makes the window
size a real choice — 96 bins is 225 kHz at 2.4 MSPS/1024, so a 200 kHz WFM signal is excluded from
its own floor estimate.

Occupancy is the honest limit. A knocked-out global median holds to about 40% band occupancy and
collapses past 55%; the local window with a guard is better placed but a band that is genuinely full
has no visible floor by definition. When more than 40% of a window's reference bins are excluded,
the segment's floor is reported with that fact attached rather than as a number that looks solid.

### The threshold

For M averaged looks the normalised bin power is Gamma(M, 1/M), and the Wilson–Hilferty
approximation gives the quantile in closed form:

```
T(z) = (1 − 1/(9M) + z·sqrt(1/(9M)))³
```

The threshold over the *measured* floor is `T(z_p)/T(0)`, which cancels the median-to-mean
conversion — the floor estimator returns a median and the model is about the mean, and taking the
ratio means neither has to be converted explicitly. At M = 1 this reproduces the exact exponential
answer to within 0.2 dB and errs conservative.

`p` is set from a **whole-sweep** false-alarm budget rather than a per-row one: 0.1 false detections
per scan, spread over N bins × K sub-blocks × S steps. For a 1024-bin, 4-sub-block, 7-step sweep
that is p = 3.5e-6, and at M = 16 the threshold is **4.17 dB over the local floor**.

Measured, against pure complex Gaussian noise through the real Hann-windowed FFT and the real CFAR
floor:

```
  M   threshold   false detections per sweep   P(detect), 12.5 kHz signal in ONE sub-block
                                                  4 dB      6 dB      8 dB     10 dB
  4     7.44 dB              0.117               0.44      0.88      0.96      1.00
  8     5.60 dB              0.000               0.80      1.00      1.00      1.00
 16     4.17 dB              0.000               1.00      1.00      1.00      1.00
```

The dB figures are over the **per-bin** noise floor, which is where the wideband level minus
10·log10(N) sits. That distinction is not pedantry: a scan's floor reads about 30 dB below the
number `ley tune`'s meter shows for the same air, because one is per bin and the other is per
channel.

"0.000" is 0 of 60 trials; the 95% upper bound is about 0.05 false detections per sweep, and it
holds for stationary Gaussian noise only. Hardware artefacts are a different problem and are handled
below, not by this threshold.

### Persistence is evidence, not a gate

The first design required a bin to clear the threshold in at least two of four sub-blocks. It was
measured, it worked against noise, and it was wrong: `.mean` already dilutes a burst by its duty
cycle, so demanding presence in half the dwell makes intermittent FM voice, APRS packets and
repeater tails invisible. A scan that quietly drops the transmissions an operator most wants to see
is worse than one that shows a few uncertain rows.

Setting the threshold from the whole-sweep budget instead makes the persistence gate unnecessary: a
single sub-block crossing is already worth 0.05 false detections per scan. So every crossing is
reported, and the counts go on the wire — `Detection.looks` (sub-blocks that cleared) and
`Detection.looks_possible` (sub-blocks that covered that frequency at all). A carrier reads 8/8, a
packet burst reads 1/8, and the difference is visible instead of decided in the daemon.

This is the `SubAudible` pattern: publish the measurement and the evidence, let the client
threshold. Invariant 12 is a rule about not dressing up guesses, and a count is not a guess.

### Grouping, centre and bandwidth

Contiguous runs of bins over threshold, joined across gaps of up to two bins, so that a notch in the
middle of a wide signal does not split it into two carriers.

**Centre** is the power-weighted centroid of the floor-subtracted excess power, computed in linear
power, and bin *b* is the frequency `lowEdge + b·binWidth` -- a point sample of the spectrum, not
the interval `[b, b+1)`. Treating it as an interval put every reported frequency half a bin high,
which the fixture run showed as carriers at 145.201 MHz where the generator had put 145.200. With
that corrected, all four fixture carriers report at exactly their generated frequencies — the rows arrive in dB and a centroid over decibels is a different, floor-biased statistic.
Measured accurate to 0.1 kHz against a 2.34 kHz bin.

**Bandwidth** is the harder honesty question. The obvious answer, the width of the run above the
threshold, is not a property of the signal: it grows with SNR, because the window's skirts clear a
fixed threshold further out as the signal gets louder. Measured, a pure tone reads 2.3 kHz at 6 dB
SNR and 7.0 kHz at 30 dB. Subtracting a fixed mainlobe width does not fix it either — convolution
adds variances, not widths.

So bandwidth is the **equivalent rectangular width**: `sqrt(12 · (μ₂ − w₂))`, where μ₂ is the second
central moment of the same excess-power weights that give the centroid and w₂ is the analysis
window's own second moment (0.333 bins² for a periodic Hann). It is the width a flat spectrum with
the same second moment would have. Measured:

```
  true width     6 dB SNR   15 dB SNR   30 dB SNR
  pure tone        ~0          0.4         0.2      kHz
  12.5 kHz         10.2        11.4        11.4
  25 kHz           24.6        26.0        25.3
  200 kHz         198.0       198.8       198.6
```

SNR-independent, correct across a sixteen-fold range of widths, and it returns approximately zero
for a tone rather than an invented number. When it lands below one bin the CLI prints
`under 2.344 kHz` rather than a figure, because a width smaller than the resolution is not a
measurement.

One edge case the centroid inherits: a signal that straddles the boundary of the requested range is
reported at the centroid of **the part inside it**, because that is all the detector was allowed to
look at. A 150 kHz-wide carrier half outside `--band`'s edge reads tens of kHz low. Widening the
range fixes it, and the honest alternative -- reporting a centre from bins outside what was asked
for -- would be worse.

**SNR** is the peak bin's excess over the local floor, in dB, and it is a *spectral* SNR. The
`Meter.snr_db` a listening channel reports is a *temporal* one — block power minus a five-second
running minimum — and the two will not agree for the same signal. Both are on the wire; neither is
quoted as the other.

### Rejecting the IQ image

The R820T's image rejection is 30–40 dB. Any signal 40 dB over the floor — an ordinary local
repeater — plants a mirror at `2·centre − f` that is stationary, persistent, and looks exactly like
a carrier to an energy detector. Persistence cannot reject it and neither can averaging.

The test is one lookup: for a candidate at offset +Δ from the capture centre, if the bin at −Δ is
**20 dB or more stronger**, the candidate is an image and is dropped.

That test is only safe because of the sweep geometry. A real pair of signals placed symmetrically
about the tuner centre with a 20 dB level difference would have the weaker one wrongly dropped — but
the tuner centre is chosen by the sweep, not by the band, and almost every frequency is analysed at
two different centres. The mirror position moves with the tuner; the real signal does not. So a
wrongly rejected real signal is found in its other look, while an image, whose position moves with
the LO, fails to reappear at the same frequency.

The one artefact this does not catch is a spur at a fixed absolute frequency — the 28.8 MHz
reference oscillator's harmonics, for example, which put the fifth at exactly 144.000 MHz. Those do
not move with the LO, so no amount of cross-checking distinguishes them from a carrier. `ley scan`
annotates a detection that lands within a bin of a reference-clock harmonic, client-side and
labelled as a possibility rather than a verdict, and the design doc says plainly that it cannot be
told apart by measurement.

## The wire

Everything goes through the messages that already exist, plus four additive fields that each pay for
themselves.

`ley scan` is `Jobs.StartJob(ScanConfig{once})`. The job runs the sweep, emits `Detection` messages
live on the telemetry plane, accumulates a `Scan`, and reaches `COMPLETED`. `Jobs.GetScan` returns
the aggregate. `Jobs.CancelJob` stops it.

**Two additive fields make job state observable**, because today `Event.body` has no `Job` member
and `GetStateResponse` no jobs, so a client could only poll:

```
Event.body:          Job job = 9;
GetStateResponse:    repeated Job jobs = 7;
```

A job is daemon state, and invariant 7 says clients render daemon state by subscription rather than
by asking repeatedly. `Job` is already a full-object message, so invariant 6 holds unchanged and
reconnect stays `GetState` plus resume-from-seq. The alternative — a bespoke `Sweep` streaming RPC —
was rejected because it creates a second authoritative state channel beside `WatchEvents`, orphans
the `ScanConfig`/`Scan`/`GetScan` triple the protos already define, and would have to be replaced
when the job store lands at D.15.

**Three additive fields on `Detection`** carry the evidence the design turns on:

```
uint32 looks = 10;            // sub-blocks in which this cleared the threshold
uint32 looks_possible = 11;   // sub-blocks that covered this frequency at all
double floor_dbfs = 12;       // the local floor its SNR was measured against
```

Without them a carrier seen eight times out of eight and a single burst are indistinguishable on the
wire, and a per-row floor cannot describe a local one.

**One additive field on `Scan`**: `repeated GainState gains = 7`, the gain the sweep pinned.

`ScanConfig` also gains `bool take_over = 6` for the don't-disturb override below.

### Lifetime

A scan job is **not persistent**. It is owned by the client that started it and cancelled when that
client goes away, which is what makes Ctrl-C stop the sweep and hand the radio back rather than
leaving it walking a band nobody is watching. `ley scan` sends `CancelJob` on interrupt; the
existing five-second presence reaper is the backstop for a hard kill.

This is `design-semantic-tier.md`'s rule applied literally — "ad-hoc scans return the same shape
inline and are gone when the client is" — and it is the same rule that already governs channels.
Persistence follows intent (invariant 8), and nobody typing `ley scan` has declared an intent to
keep anything.

The daemon keeps the last sixteen finished jobs and their scans in memory so a `--json` consumer can
re-read one, and loses them on restart. `result_uris` carries `ley://scans/<id>`, which names the
scan and is resolved by `Jobs.GetScan`. It is deliberately **not** a Resource yet: nothing lists it
and `ResolveLocalPath` has no file for it, because there is no file. Durable scans arrive with the
resource store at D.15, and the URI is the same one.

`ScanConfig.recurring` is rejected with `INVALID_ARGUMENT`. A schedule needs the job table that
survives a restart, which is D.15; accepting the field and ignoring it would be the dishonest
option.

## Don't-disturb

Invariant 9: jobs go through `CaptureAllocator`, and never touch captures directly. The declared
protocol returns a `ChannelID`, which suits a watch job and cannot express what a sweep needs — a
whole capture, to itself, for several seconds, retuned repeatedly. `CoreProtocols.swift` is
hand-written by design, so the protocol grows a second request shape and a lease:

```swift
enum AllocationRequest {
    case channel(frequencyHz: UInt64, bandwidthHz: UInt32)
    case exclusiveCapture(rangeHz: ClosedRange<UInt64>, sampleRateHz: UInt64, takeOver: Bool)
}
enum AllocationResult {
    case channel(ChannelID)
    case capture(any CaptureLease)
    case declined(code: String, message: String)
}
protocol CaptureLease: AnyObject, Sendable {
    var captureID: CaptureID { get }
    var sampleRateHz: UInt64 { get }
    func retune(centerHz: UInt64) async throws
    func release() async              // idempotent
}
```

The lease is what keeps the invariant literal: the sweep never names a capture and has no way to
retune anything but its own lease. It also bypasses `WriteCoalescer` deliberately — that path
coalesces last-value-wins on a 20 ms tick and would silently eat sweep steps.

Policy, first match wins:

1. An idle device that covers the range: the allocator creates the capture and destroys it on
   release.
2. Otherwise an existing capture, but only if it has no channels, no live audio sinks, and no
   interactive write in the last 60 seconds. Its centre frequency and gain are restored on release.
3. Otherwise **decline, with a reason naming what is using it.** Never queue: a scan that blocks
   silently for minutes is worse than one that says no.

`ley scan --take-over` skips the politeness checks in (2). It does not skip lease exclusivity — two
sweeps never share a radio.

Release runs on cancellation and on error, not only on success, or a borrowed radio is left parked
mid-band with no event explaining why.

## The CLI

```
ley scan <lo>..<hi> [--band NAME] [--dwell MS] [--min-snr DB] [--sort freq|snr]
                    [--gain dB|auto] [--device SEL] [--take-over] [--json]
```

A range positional, parsed by `leyline.ParseUserRange`, which accepts `144M..148M` and `144..148`
and refuses band names: `2m` is 2 MHz everywhere else in `ley`, and letting it mean the 2 m band
here is the collision `--band` exists to avoid (see PC-9 in `docs/plans/cli-papercuts.md`).
`--band 2m` is the way to say the band. Giving both is a usage error, not a precedence rule.

There is deliberately no `--step`: the geometry is what makes the sweep honest, and a user-supplied
step that broke DC-hole coverage would produce a scan with silent blind spots. The effective step is
reported in the `Scan`.

```
$ ley scan 144M..148M
sweeping 144.000 MHz to 148.000 MHz: 7 steps, 440 ms each, gain pinned at 28.0 dB
step 4/7  146.040 MHz  3 found

FREQUENCY     WIDTH        SNR  SEEN  BAND
145.230 MHz   11.4 kHz   21 dB   8/8  2 m amateur
146.520 MHz   11.9 kHz   34 dB   8/8  2 m amateur (calling)
144.390 MHz   under 2.344 kHz   9 dB   1/8  2 m amateur

3 signals, floor -88 dBFS per 2.344 kHz bin, swept in 4.1 s
  ley listen 146.520
```

The sweep line and the progress line are stderr and the progress line is rewritten in place on a
TTY; the table and the summary are stdout. `SEEN` is the evidence: 8/8 was there throughout, 1/8 was
a burst. The `BAND` column is the client-local band and preset tables, the same ones `ley bands`
prints — presentation over the daemon's measurement, added by the client, never by the detector.

Nothing found prints a sentence saying what the threshold was and what to try, and exits 0: an empty
band is an answer. A range wider than the radio can tune is clamped, with a line saying so, in the
same shape `ley spectrum --band` already uses.

`--json` is the proto3 JSON mapping of the `Scan` message, alone on stdout.

## Testing without hardware

`FilePlaybackDevice` cannot be swept. It reports a single-point tuning range and refuses any other
centre, and that refusal is pinned by tests in both languages.

Making it retunable was considered seriously and rejected on a technical point rather than on cost.
A mix by `fileCenter − requestedCenter` at the file's own rate is circular in frequency: fixtures
are 2.4 MSPS and the sweep advances 960 kHz, so by the second step a carrier has shifted past the
Nyquist edge and aliases back into the analysis windows. No post-mix filtering removes it, because
the aliasing happens in the shift. An honest retunable file device needs an oversampled wideband
source, a mix-filter-decimate chain and a new class of large fixtures — a harness rewrite, bought to
test one milestone, whose intermediate version would produce ghost detections. **A harness that lies
is worse than no harness, and it would lie in exactly the frequency-labelling dimension the sweep
exists to get right.**

So the sweep is covered in three pieces:

1. **Step geometry as a pure function.** `SweepPlanTests` asserts the quarter-band edges, the
   half-window advance, complete coverage of four ranges at four rates, that no window touches the
   capture centre, that a narrow range still gets two tuner positions, and that a request beyond the
   tuner clips and says so.
2. **The detector against fixtures**, one step, through the real pipeline: floor estimation on
   `noise_floor`, threshold and grouping and centroid and equivalent width on a new multi-carrier
   fixture whose carriers are at known offsets and known levels above a known floor.
3. **A synthetic retunable device in the daemon tests** for the multi-step loop: hop discard, row
   labelling across a hop, cross-step merging, image rejection, and lease release on cancel. It
   changes its emitted content with a deliberate delay after `tune`, so the settling logic is
   actually exercised rather than passing trivially.

## Deliberately not in v0

- **Recurring schedules.** They need a job table that survives a restart, which is D.15.
- **Persisted scans and the Resources service.** Invariant 8: an interactive scan is ephemeral.
- **`modulation_guess`.** Empty, confidence 0. Invariant 12; a real classifier slots into the field
  later without a schema change.
- **Sweeping while someone is listening.** The allocator declines. A sweep is not a retune; it takes
  the radio for seconds at a time.
- **Continuous rescanning (`--watch`).** That is a watch job, and it wants the occupancy accumulator
  from `design-band-watching.md` rather than a loop around this.
- **Audio clips per detection.** Record-job territory.
- **Multi-device parallel sweeps.** Invariant 10.

The first thing to add afterwards is occupancy over time: a scan says what is on a band now, and the
question an operator asks next is what is on it usually.

## Open questions

- **The settle constant is derived, not measured.** 218 ms comes from librtlsdr's buffer geometry
  and is arithmetic, not observation; the ring depth and the tuner's own behaviour after a hop are
  bounds rather than measurements. The first hardware run should sweep a band with one known
  continuous carrier at several dwell values and check that the reported frequency does not drift
  with dwell. Until then `--dwell` is the knob and the number is stated as a bound.
- **Occupancy limit.** The floor estimator degrades above roughly 40% occupancy of its reference
  window. The design reports when that happens; it does not yet have a better estimator for a band
  that is genuinely full.
- **Reference-clock spurs** cannot be separated from carriers by measurement. The annotation is a
  hint from a client-side table, and the table is a guess about which crystal a dongle has.
