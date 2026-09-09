# Plan: Signal Views

Implements `docs/design-signal-views.md`. Work items in build order; each of SV-1, SV-2 and SV-4 is
independently shippable. Mark `[x]` only when the item's tests pass and the full gate is green.

## SV-1 `[x]` Transmission log

The cheapest real win: three fields the daemon already has.

- `SquelchTransition` gains `duration_samples = 3`, `peak_snr_db = 4`, `peak_audio_dbfs = 5`, set on
  the **close edge only** (an open edge leaves them zero/NaN, and the comment says so).
- Engine: `ChannelDSPCore` tracks peak SNR and peak audio level over the open interval, resetting on
  the open edge. Two compares per block in the hot path, no allocation.
- `ley` keeps a bounded ring of closed transmissions per channel and renders the table.
- `--json` carries the same fields.

Tests: `ChannelTests.testSquelchCloseEdgeSummarisesTheTransmission` (close edge carries a duration
and both peaks; every open edge carries 0 and NaN); `TestClosedTransmissionOnlyOnTheCloseEdge`,
`TestClosedTransmissionConvertsWithTheCaptureRate`, `TestFmtDuration`,
`TestTransmissionStyledStripsToPlain`, `TestTransmissionOmitsUnmeasuredValues`, and
`TestTuneReportsAFinishedTransmission` end to end against the fake daemon.

Built as reported here rather than as a table: the live meter redraws one line in place, so a
finished transmission scrolls above it as prose and the meter redraws on its next tick. The table
arrives with SV-2, which is where the screen gets its other rows.

**Correction to the design doc:** `duration_samples` is in **capture** samples, not channel samples.
The channel's own rate is not on the wire, so a duration in channel samples would be unconvertible;
capture samples is the rate `SampleTime` already counts in and that every client knows.
`leyline.ChannelCaptureRate` looks it up. Verified on the real daemon against `two_nfm.cf32`: a
squelch closed four seconds in reported `transmission  4.0 s  peak -20 dBFS`, and -20 dBFS is the
fixture's tone level.

## SV-2 `[x]` Audio meter fields and the two-bar channel view

- `Meter` gains `audio_dbfs = 5` and `audio_peak_dbfs = 6`. New `Kernels.meanSquare` and
  `Kernels.maxMagnitude`, vDSP on Darwin and plain loops in `PortableKernels`.
- Engine: accumulate sum-of-squares and peak over the demodulated block in `ChannelDSPCore.process`,
  drained and reset on each meter tick. Two passes over data already in cache. The sum is a `Double`
  because a 100 ms interval at 48 kHz is 4800 squares and `Float` would drift.
- CLI: two detail rows under the contractual meter line, on a terminal at least 60 columns wide.
  The inline bar is dropped when they draw, because it repeats the signal row.

**`deviation_hz` and `freq_error_hz` are deferred to SV-6, and their field numbers are `reserved`
in the proto so the wire does not churn.** Both must come from the raw discriminator, and a
deviation read off the de-emphasised, high-passed audio would be wrong by whatever de-emphasis did
to it. The tap that makes them correct is SV-6's, so they ship with it rather than being
approximated here.

Tests: `ChannelTests.testMeterReportsAudioLevelSeparatelyFromChannelPower` (the two are different
measurements; RMS never exceeds full scale; peak is never under RMS);
`TestMeterDetailRowsAppearOnAWideTerminal` (line 1 stays the contract line byte for byte),
`TestMeterNarrowTerminalIsUnchanged`, `TestMeterNoDetailRowsWithoutAnAudioLevel`,
`TestMeterDetailStripsToPlain` at 60/80/160 in both alphabets, `TestMeterSilentAudioReadsQuiet`.

Verified on the real daemon against `two_nfm.cf32`: channel power -20.0 dBFS (the fixture's tone
level) against demodulated audio -15.2 dBFS, stable across meters.

## SV-3 `[x]` Ladder accumulation

No user-visible output. Lands before SV-4.

- `FftParams.accumulation = 4` (`SNAPSHOT` | `MEAN` | `MAX`) and `looks_per_row = 5` (descriptor
  answer only). Default `SNAPSHOT`: `ley spectrum` output is byte-identical.
- `DefaultSpectrumLadder` accumulates one look per capture block, capped at 64 looks per row.
- `StreamDescriptor` reports the looks actually taken, so a client can say so.

Enum values carry a `ROW_` prefix (`ROW_SNAPSHOT`, `ROW_MEAN`, `ROW_MAX`): proto3 enum values are
siblings of their type within the package, and a bare `SNAPSHOT` collides with `ResourceKind` in
jobs.proto.

Two things the design did not anticipate:

- **`MEAN` must average in the power domain.** The ladder emits dB, and the mean of decibels is a
  different statistic that reads several dB low on a row with any structure in it. Each look is
  converted with a new `Kernels.dbToPower` and the row converted back at emit. The conversion may
  not touch the ladder's shared row buffer, which every same-size subscriber in the same pass reads,
  so a mean subscriber gets a scratch buffer of its own. Both are allocated at subscribe time.
- **An accumulating subscriber's first row waits a whole interval.** Emitting on the first block
  would put one look in a row that claims to summarise the interval, which is exactly the lie this
  work item exists to remove.

Looks are spread evenly across the row on their own `nextLook` schedule rather than taken back to
back, so the 64-look cap thins the sampling at a slow row rate instead of covering only the start of
the row.

Tests: `testMaxAccumulationCatchesABurstSnapshotMisses` -- a burst filling 6% of a row is found by
every `MAX` row and by no `SNAPSHOT` row, which is the whole claim;
`testMeanAccumulationDilutesABurst`; `testSubscriptionReportsItsLooks`. `looks_per_row` is refused
in a request, since a client asking for a look count is asking the daemon to spend CPU it does not
own.

## SV-4 `[x]` The waterfall

- `ui.Glyphs.Shade` = `" ░▒▓█"`, ASCII `" .:+#"`.
- `ley waterfall [frequency]`: negotiates an FFT stream with `MAX`, draws one shaded cell per
  column, floor blank, scale held for the run, newest at bottom, one printed line per row, gap rows,
  frequency axis reprinted periodically, per-column bandwidth in the header.

`ley spectrum` and `ley waterfall` pick their capture by identical rules, so those 50 lines moved
into `session.openBand` rather than being copied.

Two things the first cut got wrong, both caught by the width test rather than by eye: the header and
the key overflowed a 40-column terminal, and `headerSeg.width()` measured bytes, which counts escape
sequences as columns for a key whose glyph is already inked. The greedy packer the spectrum header
used is now shared as `packSegments`, and `headerSeg` takes an explicit visible width.

The scale is taken from the first row rather than the first two: one row of eighty-odd columns is
plenty of evidence for a median, and taking it immediately lets the header state the floor its
shades are measured from instead of printing a dash.

Tests: `TestWaterfallStripsToPlain` at 40/80/160 in both alphabets, `TestWaterfallFitsWidth` (which
found the overflow), `TestWaterfallDrawsAGap`, `TestWaterfallScaleIsHeld`,
`TestWaterfallQuietBandIsMostlyBlank` (a band with nothing on it inks under a tenth of its cells,
and a carrier 40 dB up still draws at full density), `TestWaterfallHeaderStatesColumnBandwidth`.

Verified live on the FM band over rtl_tcp: KQED draws a persistent bright column under the 88.5
marker, KPOO a fainter one at 89.5, and the noise floor stays blank.

## SV-5 `[x]` CTCSS fixtures

`fmTone` gains `subToneHz`/`subDevHz`, so a fixture carries CTCSS the way a transmitter does.
`iqfile.Expect` gains a `sub_audible` block whose `detect` is deliberately separate from `tone_hz`:
a fixture can carry a tone and still expect no detection, which is exactly what `nfm_hum` asserts.

Five fixtures: `nfm_pl` (100.0 Hz at 700 Hz deviation), `nfm_pl_67` and `nfm_pl_69` (the 2.3 Hz
discrimination pair), `nfm_hum` (100.0 Hz at only 40 Hz deviation, the documented false positive),
`nfm_pl_only` (a keyed carrier with a tone and no voice).

Verified before building anything against them, with an independent Goertzel bank over each
fixture's own discriminator output:

```
nfm_pl       winner 100.0 Hz  margin 10.8 dB   expect 100    detect true
nfm_pl_67    winner  67.0 Hz  margin  8.1 dB   expect 67     detect true
nfm_pl_69    winner  69.3 Hz  margin  8.1 dB   expect 69.3   detect true
nfm_hum      winner 100.0 Hz  margin 10.8 dB   expect 100    detect FALSE
nfm_pl_only  winner 123.0 Hz  margin 34.8 dB   expect 123    detect true
nfm_tone     winner 179.9 Hz  margin  0.3 dB   no tone       (rejected by the 6 dB gate)
```

The pair discriminates correctly, and `nfm_hum` passes the frequency test with a healthy margin --
which is the point of it. Only deviation separates hum from PL.

The three fixtures carrying a real 700 Hz tone expect a much lower **audio** SNR (8 dB, measured
~11) than `nfm_tone`'s 30. That is a fact about the signal rather than a slack expectation: 700 Hz
of sub-audible deviation is 11 dB under the 2.5 kHz voice deviation, the 300 Hz high-pass takes
about 20 dB off it, and de-emphasis then pulls the 1 kHz tone down another 10 while leaving the
residue alone.

## SV-6 `[ ]` CTCSS detector

- `SubAudibleSource` protocol on `NFMDemodulator`, tapping `scratch.real`; two FIR decimation
  stages plus a 20 Hz DC block into a fixed ring, allocated in `configure`.
- Slow per-channel task: Goertzel gate, phase-slope estimate, the accept rules from the design doc.
- `SubAudible` telemetry, `Channel.subaudible_detect = 12`, the `PL` line, `--json`.

## SV-7 `[ ]` DCS

Same tap, same message, `kind = DCS`. A DCS lock suppresses the CTCSS claim.

## Decisions

- Half-blocks rejected for the waterfall: level would live only in colour, so `NO_COLOR`/`--ascii`
  would render a blank rectangle. Recorded in the design doc with the reasoning.
- No audio spectrum in the channel view. A picture of a scalar, at a resolution that would
  contradict the number beside it.
- Confidence is a stated formula, not a calibrated probability, until a fixture corpus exists.

## Closing

Follow-ups deliberately left out of this plan: tone squelch (`Channel` field 13 is held for it),
`ley watch` reusing the waterfall renderer over a client-side ring, and `AUDIO_FFT` if DCS or
two-tone paging ever needs it.
