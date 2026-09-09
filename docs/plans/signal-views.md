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

## SV-3 `[ ]` Ladder accumulation

No user-visible output. Lands before SV-4.

- `FftParams.accumulation = 4` (`SNAPSHOT` | `MEAN` | `MAX`) and `looks_per_row = 5` (descriptor
  answer only). Default `SNAPSHOT`: `ley spectrum` output is byte-identical.
- `DefaultSpectrumLadder` accumulates one look per capture block, capped at 64 looks per row.
- `StreamDescriptor` reports the looks actually taken, so a client can say so.

Tests: a fixture with a burst shorter than a row interval appears at full level under `MAX` and is
diluted under `MEAN`; `SNAPSHOT` is bit-identical to today; the looks cap holds at a high row rate;
no allocation added to the ladder pass.

## SV-4 `[ ]` The waterfall

- `ui.Glyphs.Shade` = `" ░▒▓█"`, ASCII `" .:+#"`.
- `ley waterfall [frequency]`: negotiates an FFT stream with `MAX`, draws one shaded cell per
  column, floor blank, scale held for the run, newest at bottom, one printed line per row, gap rows,
  frequency axis reprinted periodically, per-column bandwidth in the header.

Tests: strip-to-plain; a row never exceeds the resolved width; a gap draws its own row; the scale
does not move once set; ASCII renders the same information.

## SV-5 `[ ]` CTCSS fixtures

`leyfix` gains a sub-audible tone generator. Fixtures: NFM voice + 100.0 Hz PL at 700 Hz deviation;
the 67.0/69.3 pair at 6/10/20 dB tone-to-band; 50 Hz mains hum with no PL; PL with no voice.
Nothing in SV-6 may claim a lock until these pass.

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
