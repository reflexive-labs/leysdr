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

## SV-6 `[x]` CTCSS detector

- `SubAudibleSource` on `NFMDemodulator`, tapping the discriminator before the high-pass; two FIR
  decimation stages into a `FloatRing`, everything allocated in `configure`. DC is removed in the
  detector's window rather than by a separate filter -- the discriminator's DC is the tuning error,
  and one subtraction per window is cheaper than a filter on the hot path.
- Slow per-channel task at utility priority: Goertzel bank as a gate, phase-slope estimate for the
  frequency, and the accept rules. Every branch is here; the DSP thread only decimates.
- `SubAudible` telemetry, `Channel.subaudible_detect = 12`, the `PL` line, `--json`.

Detection is armed for NFM channels, since that is the only mode CTCSS is sent under. Making it a
per-channel request is a control-plane change and field 12 is the contract for it; until then the
mode is the answer, and the cost is two decimation stages (~0.6 Mmult/s) that never gate audio.

**Two bugs worth recording.** The tap was first armed before `demodulator.configure`, which is what
decides the tapped rate, so the rate was zero and the guard silently disarmed it -- the unit tests
all passed and nothing came out end to end. And the first tap test regenerated its signal from t=0
for every block, putting a phase discontinuity into the discriminator that is in no real signal; it
detected a tone but classified it as unclassifiable, which is the detector behaving correctly on a
corrupt input.

Verified end to end through the real daemon, every fixture:

```
nfm_pl       expect 100.0  got 100.0   dev 700 Hz  snr 87 dB  conf 1.00
nfm_pl_67    expect  67.0  got  67.0   dev 700 Hz  snr 99 dB  conf 1.00
nfm_pl_69    expect  69.3  got  69.3   dev 700 Hz  snr 97 dB  conf 1.00
nfm_pl_only  expect 123.0  got 123.0   dev 700 Hz  snr 92 dB  conf 1.00
nfm_hum      expect  none  got  none   SUB_AUDIBLE_NONE
nfm_tone     expect  none  got  none   SUB_AUDIBLE_NONE
```

The measured deviation is 700 Hz against a generated 700, which is what says the amplitude
calibration is right rather than merely self-consistent. On screen: `PL  67.0 Hz  dev 699 Hz
tone/band 59 dB`.

Tests: `SubAudibleTests` (detects four tones across the ladder; discriminates the 67.0/69.3 pair;
rejects voice across six seeds; rejects mains hum by deviation and says so; refuses to classify an
ambiguous measurement; confidence is zero without a classification), `SubAudibleTapTests` (the tone
survives the tap and provably does **not** survive the audio, measured on both), and the CLI
tracker tests.

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

## SV-8 `[x]` The scope: `ley scope`

Implements `docs/design-scope.md`, in four work items the loop runs by section name. Read the
design doc first for every one of them; it states the contract each item serves. Additive `AudioParams.tap` (`AUDIO`, `DEMOD`); the demodulators
produce the raw stage into preallocated scratch; the channel core routes it to `DEMOD` subscribers
and keeps it flowing while the squelch is closed; `rawIQ` refuses the tap. Fixture test: the NFM
`demod` tap on `nfm_pl.cf32` carries the PL tone the sidecar names, and the `audio` tap does not.
Fake: the `demod` tap is the audio plus the configured tone. CLI: the trace (braille, ASCII
fallback), the trigger, the header with the daemon's tone, `--json` frame statistics, tests against
the fake. Docs: `interfaces.md` tree and JSON paragraph, `cli-guide.md` section.

## SV-9 `[ ]` The audio spectrogram: `ley sonogram`

Daemon-side FFT ladder over the audio or demod tap, rendered like the waterfall. After SV-8.

### SV-8a `[x]` The tap on the wire, the fake, the client (cross-language, first)

- `proto/leyline/v1/bulk.proto`: `AudioParams` gains `AudioTap tap = 3;` with
  `enum AudioTap { TAP_AUDIO = 0; TAP_DEMOD = 1; }` (enum value names are package-scoped, so they
  cannot collide with `StreamKind.AUDIO`). Comments state the contract from the design: `TAP_AUDIO`
  is what a speaker gets and the default, so every existing subscription is unchanged; `TAP_DEMOD`
  is the detector's output before conditioning, per mode as the design lists, keeps flowing while
  the squelch is closed, and is refused with `INVALID_ARGUMENT` on a `RAW_IQ` channel. The daemon
  echoes the tap in the answered `StreamDescriptor`. `make proto`.
- `go/pkg/leyline`: `SubscribeAudio` keeps its signature (tap audio); add `SubscribeAudioTap(ctx,
  channelID, sampleRate, format, tap)` beside it.
- Fake: `Bulk.Subscribe(AUDIO, tap=TAP_DEMOD)` refuses `RAW_IQ` channels; otherwise the frame payload
  is the channel's synthetic audio plus the same `carrierTone(hz)` sub-audible tone the fake's
  `SUB_AUDIBLE` telemetry reports (at about a tenth of full scale) plus a small constant DC offset,
  and unlike the audio tap it does not go to zeros while the squelch is closed. Descriptor echoes
  the tap. Tests in the fake's suite: both taps negotiate, the demod payload differs from the audio
  payload, rawIQ refused, unknown tap value refused.

### SV-8b `[x]` The tap in the engine and the daemon (Swift lane)

- `CoreProtocols.swift` (hand-written; changing it is allowed): `Demodulator.process` gains a raw
  output beside `audioOut`, written into scratch sized at `configure` (invariant 4: no allocation on
  the hot path). Each demodulator writes its raw stage as the design lists: NFM the discriminator
  before the 300 Hz high-pass (the same samples that feed `tapSubAudible`), AM the envelope before
  the DC block and AGC, USB/LSB and CW the product detector before AGC, WFM the discriminator after
  decimation to the audio rate but before de-emphasis and the 15 kHz low-pass, `rawIQ` none.
- `ChannelDSPCore`: audio sinks carry a tap; the core writes the raw block to `TAP_DEMOD` sinks and
  the conditioned block to the rest; the squelch-closed zeroing applies to `TAP_AUDIO` sinks only;
  meter and squelch are unchanged. A channel with no demod subscriber pays one branch.
- Daemon: `StreamRegistry.subscribe(AUDIO)` reads `params.tap`, refuses `TAP_DEMOD` on a `rawIQ`
  channel and any unknown value with `INVALID_ARGUMENT`, attaches the bulk sink with the tap, and
  echoes the tap in the descriptor. `MalformedInputTests` gets the unknown-value case.
- Tests: `EngineCoreTests` on `fixtures/nfm_pl.cf32` (NFM, 1 kHz audio, 100 Hz PL at 700 Hz
  deviation): the demod tap carries the 100 Hz tone (Goertzel at 100 Hz at least 20 dB above 80 Hz
  and 120 Hz) and the audio tap has it at least 12 dB lower than the demod tap -- the two cascaded
  300 Hz poles put 100 Hz about 20 dB down and the de-emphasis make-up gain hands about 6 dB of that
  back, and this item routes the tap rather than touching the audio chain; on the AM fixture
  the demod tap's mean is the carrier level and the audio tap's mean is near zero; with the squelch
  closed the audio tap is zeros and the demod tap is not. `LeylineDaemonTests`: a `TAP_DEMOD`
  subscription on a file-device channel delivers frames whose descriptor echoes the tap; `rawIQ`
  refused. `docs/engine-internals.md` gets the paragraph under the channel pipeline.

### SV-8c `[x]` `ley scope` (Go lane, against the fake)

- `go/internal/cli/scope.go` and `scope_view.go`: `ley scope [frequency|preset|channel]` with the
  tune flags `listen` takes (a channel id or a frequency taps an existing channel exactly as
  `listen` resolves its target; a fresh frequency creates a channel with no system-audio sink),
  plus `--tap audio|demod` (default audio), `--window MS` (default 40, range 5..500),
  `--trigger auto|free` (default auto), `--rate N` frames per second (default 20, max 20),
  `--count N`, `--width N`.
- The trace: one window of samples per frame across the terminal width, full scale ±1.0 vertically
  over the available rows, braille cells (2 × 4 dots, U+2800 + bit pattern) on the Unicode glyph
  set and a three-level ASCII fallback (`_`, `-`, `¯` or similar) on `--ascii`, through the
  existing `ui.Glyphs` mechanism. `--trigger auto` starts the frame at a rising zero crossing when
  the window is periodic enough to hold still (a repeating zero-crossing interval), else free-runs.
  Redraw in place like `spectrum --watch`; stderr for prose, stdout only for `--json`.
- Header, one line: channel and mode, tap, window, the frame's peak and RMS in dBFS; on the demod
  tap for FM modes the DC offset as a tuning error in hertz (±1.0 ≙ ±5 kHz for NFM, ±75 kHz for
  WFM); and, from a `SUB_AUDIBLE` telemetry subscription on the channel, `PL 100.0 Hz (measured
  100.02 Hz, 18 dB, confidence 0.9)` when the daemon reports a tone. The view never estimates the
  tone itself.
- `--json`: one object per frame `{seq, sample_index, sample_rate, tap, window_ms, peak_dbfs,
  rms_dbfs, dc, tone_hz}` (`tone_hz` absent until the daemon has reported one), no samples; add it
  to the bulk-row exception paragraph in `docs/interfaces.md` and to the tree; `docs/cli-guide.md`
  gains a "See the waveform" section with a transcript recorded against the fake, and `ley help
  modes` points at `ley scope` as the way to see what a mode does.
- Tests against the fake: a tone renders as a periodic trace whose zero crossings match the tone
  (golden for the braille and the ASCII forms); the trigger holds a tone still across frames; the
  demod header shows the fake's tone and the tuning error; rawIQ exits 1 with the daemon's
  sentence; `--json` shape and `--count`; the `json_verbs_test` tree walk picks the new verb up.

### SV-8d `[x]` End to end, and the recorded transcript (cross-language, last)

`go/internal/e2e`: play `fixtures/nfm_pl.cf32` through the real daemon, run
`ley scope --tap demod --json --count 20` on its channel, assert at least one frame within 10 s
carries `tone_hz` within 0.5 Hz of 100 and every frame has finite `rms_dbfs` and `dc`, then
`--tap audio --count 5` frames arrive and carry no `tone_hz` requirement. Then re-record the
`cli-guide.md` transcript against the fake if the wording moved.

`go/internal/e2e/scope_test.go`. The demod tap needs a few windows before the detector names a
tone, and a row drawn before the first telemetry message carries none, so the test keeps drawing
20-frame runs until one arrives or ten seconds pass. Against the real daemon on `nfm_pl.cf32` the
first run already carries `tone_hz: 100`.

The `cli-guide.md` transcript stands: rendering a demod frame with the guide's numbers reproduces
its two header lines exactly, so there was no wording to re-record.


### SV-8e `[x]` What the second look at the demod tap found (Swift lane)

An independent read of `c2a0b08..d39aa56` on the engine side, after the per-item verifiers. Line
numbers as of `4212935`. Engine and docs only.

1. `Demodulators.swift:284-286` (WFM): the one early return that does not zero `rawOut.count`; make
   it `rawOut?.count = 0` like every other exit, so a stale scratch block can never ship.
2. `ChannelDSPCore.swift:287-294`: keep one sink table plus a cached `hasDemodSink: Bool` rather than
   two arrays snapshotted per block, so an untapped channel pays one branch and the comment at
   `:292-293` becomes true; skip allocating `rawOut` for `rawIQ` channels, which can never have a
   tap.
3. `Demodulators.swift:59`: drop the dead `scale:` parameter on `emitRaw` (WFM rescales through its
   own path).
4. WFM's raw decimator is reset alone when a tap attaches mid-stream (`:289`), so from then on its
   block counts and the audio's differ by one on some blocks, and the two taps are not
   sample-aligned (different group delay, about 0.3 ms). That is acceptable for a scope, but say it:
   in `docs/engine-internals.md`'s demod-tap paragraph and on the `SampleTime` both taps share; and
   `DemodTapTests.swift:137,155` must stop claiming general alignment (assert the fresh-start case
   it actually exercises, and say so).
5. `DemodTapTests.swift:54` and the WFM test: `XCTAssertGreaterThanOrEqual` falls through into a
   `precondition` in `tonePowerDB` and traps the process; use `guard … else { XCTFail; return }`.
   `DemodTapStreamTests.swift:56-58`: bound the `for try await` with a deadline like the rest of
   the daemon tests.
6. Two daemon tests the contract lacks: destroying a channel closes its demod-tap stream; a
   capture-rate change ends it (the descriptor is no longer true), exactly as for the audio tap.
7. Pre-existing, now inherited by the tap: `SessionStore.swift:906-943` mode, bandwidth and offset
   writes call `engine.update` without reconciling audio rates, so a mode change that moves the
   channel's audio rate (NFM to WFM or back) leaves bulk audio streams, both taps, open at a rate
   their descriptor no longer describes. Route those writes through the same audio-rate
   reconciliation the capture-rate write uses, so the streams end and a client re-subscribes for a
   fresh descriptor; daemon test: `ley listen`-style audio stream open, mode write NFM→WFM, the
   stream ends. `StreamSources.swift:66` captures `captureRate` at subscribe; if the reconciliation
   above ends the stream on every audio-rate change the stale value is unreachable — say so in a
   comment, or read it live.
8. `StreamRegistry.swift:244`: the descriptor echo can be `req.audio.tap` (the unknown case has
   already thrown).
9. Comments: `docs/engine-internals.md:189` the block's mean is the tuning error in units of
   full-scale deviation, not hertz (the client scales by 5 000 or 75 000); `CoreProtocols.swift:443`
   is garbled ("A sink that does not say is listening."); the sentence "what a transmitter is
   sending between words is what it is for" appears in four places — keep it in the proto and the
   design doc, and have the two code comments refer to the field instead.

Suite green twice at the end.

Item 7's premise is wrong about NFM and WFM: the audio rate is `r1 / round(r1 / 48 kHz)` in both
modes (the channelizer decimates for NFM, the demodulator for WFM, by the same arithmetic on the
same `r1`), so a mode write never moves it and there is no NFM→WFM test to write. The write path
was reconciled anyway, because another route through it does move the rate: a channel left
`OUT_OF_CAPTURE` by a rate change has its chain re-planned by the first write that fits it back in,
at the current capture rate. `testOffsetWriteThatRePlansTheChainEndsAudioStreams` is that case --
an offset write, a listener's stream and a scope's stream both negotiated at 48 kHz, both ended,
and a fresh subscription served 51.2 kHz.

Everything else landed as written. The sink table is one array plus `hasDemodSink`; `rawOut` is nil
for raw IQ; WFM's early return zeroes the tap; `emitRaw` lost its unused `scale:`; the alignment
claim is now in `docs/engine-internals.md` and on `AudioSink.write`, and the WFM test says it
asserts the fresh-start case; the tap tests guard instead of trapping, and the daemon one reads
under a deadline. Two new daemon tests cover destroy and a capture-rate change ending a tap stream.

Item 7's last clause could not be answered with a comment: two capture rates can plan to the same
audio rate (1.024 and 2.048 MSPS both give 51.2 kHz on NFM), so an audio-rate teardown leaves a
stream running with a stale `captureRate` and frame spans wrong by the ratio. A capture-rate write
now ends every bulk audio stream on the capture (`TeardownScope.captureRate`), which is what the
comment at `StreamSources.swift` rests on, and
`testCaptureRateChangeEndsTheAudioStreamWhenTheAudioRateHolds` is the case where no audio rate moves.

### SV-8f `[x]` A time axis under the trace (Go lane)

The trace has no timebase on screen. Draw one under it in the style `spectrum` uses for
frequency (`spectrum_axis.go`): a rule with tick marks and labels beneath, ticks chosen from
1, 2, 5, 10, 20, 50, 100 ms so that between four and eight fit the width, labels in milliseconds
(`0 ms`, `2 ms`, …, the right edge labelled with the window length), the same rule under the
`--ascii` form. When `--trigger auto` has locked, the axis is still time from the frame's start;
the header already says the window. Left of the trace, one gutter column with `+1`, `0` and `-1`
at the top, middle and bottom rows, so the vertical scale is on screen too (full scale is ±1.0;
the header's tuning-error line carries the hertz). Re-record the goldens and the transcript in
`docs/cli-guide.md`; `--json` is unchanged. Keep the axis out of `--width` accounting only if it
was already excluded for `spectrum`; otherwise the trace shrinks by the gutter width.

### SV-8g `[x]` A vertical scale, and the squelch said out loud (Go lane)

Two things a first real-radio session showed. Full scale on the demod tap is ±5 kHz of deviation
and speech spends most of its time at a tenth of that, so a voice draws one or two dots high; and
on the audio tap a closed squelch zeroes the trace while the header still reports the PL tone from
the daemon's detector, which reads as "the tone is there but my voice is not".

- `--scale full|auto|<n>` (default `full`). `auto` fits the trace to the signal: the scale is the
  frame's peak with a little headroom, held with a slow decay (about a second) so it does not
  flicker between syllables, and snapped to 0.02, 0.05, 0.1, 0.2, 0.5 or 1 so the gutter reads a
  round number. `<n>` in 0.02..1 pins it. The gutter labels become `+0.2`, `0`, `-0.2`; the header
  says `scale ±0.2`; `--json` gains `scale`. The DC offset still reads out in hertz. `full` keeps the
  rule that a trace that grows is a signal that grew, and the guide says which to use when.
- The scope already subscribes to telemetry for `SUB_AUDIBLE`; take `METER` on the same channel as
  well and, while `squelch_open` is false and the tap is `audio`, print on the header's second line
  `squelch closed: the audio tap is muted; --tap demod shows what the detector hears`. Nothing is
  printed on the demod tap or with the squelch off.
- `docs/cli-guide.md` section 7: a short "looking at speech" paragraph — `--window 250
  --trigger free --scale auto` for an envelope, `--window 40` with the trigger for a tone — and the
  sentence that full scale is ±5 kHz on NFM and ±75 kHz on WFM. Re-record the transcript if the
  header moved. `docs/interfaces.md` JSON paragraph gains `scale`.
- Tests against the fake: the auto scale snaps to the expected step for a 0.14 tone and holds
  across frames; a pinned scale labels the gutter; the squelch line appears only on the audio tap
  with the squelch closed; `--json` carries `scale`; goldens as needed.

The squelch sentence is 81 columns, one more than the default width, so it is drawn as the one
sentence it is where the width takes it and split at the semicolon where it does not -- two lines
under the header at 80 columns. The header names the scale only when something has changed it
(`--scale auto` or a pinned number), which keeps the default view byte-identical: re-rendering the
guide's demod frame reproduces its two header lines and its gutter exactly, so the transcript in
`cli-guide.md` stands and section 7 gained only the "looking at speech" paragraph. The gutter's
width is fixed for the run rather than per frame -- `auto` reserves the widest step it could pick,
`+0.02` -- because a trace that changes width between frames is harder to read than a column of
space. The auto scale's hold is a peak with 10% headroom decaying on a one-second time constant,
so a 0.14 tone sits at ±0.2 through a quarter-second pause and is back down within two seconds.

## SV-10 `[x]` Audio meters: `ley levels` and `ley waveform`

Implements `docs/design-audio-meters.md`; read it first for every item, it carries the visual
language the renderers must match and the honesty rules (ballistics shape bars, never numbers).

### SV-10a `[x]` The audio spectrum on the wire, the fake, the client (cross-language, first)

- `proto/leyline/v1/bulk.proto`: `FftParams` gains `AudioTap tap = <next>` (the enum from
  `AudioParams`), meaningful only when the subscription's source is a channel; comments state the
  contract: `kind = FFT` with a `channel_id` source is the spectrum of that channel's audio or
  demod tap, rows of dB per bin from 0 Hz to half the audio rate, the descriptor's `center_hz` and
  `span_hz` are `rate/4` and `rate/2` so every FFT reader's row layout holds, `rows_per_second` at
  most 20, `bins` from the ladder's sizes, `rawIQ` refused with `INVALID_ARGUMENT`. `make proto`.
- `go/pkg/leyline`: `SubscribeAudioSpectrum(ctx, channelID, bins, rowsPerSecond, format, tap)`
  beside `SubscribeFFT`, returning the same `Subscription`.
- Fake: an FFT subscription on a channel source answers rows synthesised from what the fake's
  channel carries: a floor near −90 dB, the 1 kHz audio tone, and on the demod tap the
  `carrierTone` PL at its level, at the negotiated bins and rate; `rawIQ` refused; the descriptor
  echoes tap, bins, rate, centre and span. Tests in the fake's suite.

### SV-10b `[x]` The audio spectrum in the engine and the daemon (Swift lane)

- `ChannelDSPCore` gains a spectrum tap beside the audio sinks: subscribers are fed from the
  audio or demod block into a sliding window (`2 × bins` samples), Hann-windowed, transformed with
  the existing FFT (real input; a zero imaginary half through the complex transform is acceptable
  if no real transform exists, and the portable kernel must run on Linux), `|X|²` to dB scaled so
  a full-scale sine reads about 0 dBFS, one row whenever the window has advanced by
  `rate / rows_per_second` samples. Allocation-free like `SpectrumLadder`: scratch sized at
  subscribe, no per-block work for channels without a subscriber.
- Daemon: `StreamRegistry.subscribe(FFT)` with a channel source takes this path, validates
  `bins`, `rows_per_second` (clamped like the ladder's) and `tap`, refuses `rawIQ` and unknown
  taps with `INVALID_ARGUMENT`, reuses the FFT frame sink and formats (`DB_F32`, `DB_U8`), and
  echoes tap, bins, rate, `center_hz = rate/4`, `span_hz = rate/2`. Teardown and the rate-change
  ending follow the audio tap's rules from SV-8e.
- Tests: `EngineCoreTests` on `fixtures/nfm_pl.cf32`: the demod-tap spectrum has its two largest
  peaks at 100 Hz and 1 kHz (within a bin), the audio-tap spectrum has 1 kHz and its 100 Hz bin at
  least 12 dB below the demod tap's; the AM fixture's tone at its bin; a `KernelParityTests`-style
  guard is not needed because the FFT is shared. `LeylineDaemonTests`: subscribe on a file-device
  channel, rows arrive with the echoed descriptor; `rawIQ` refused; `MalformedInputTests` for
  absurd `bins` and `rows_per_second`. `docs/engine-internals.md` paragraph under the channel
  pipeline.

The spectrum tap is an `AudioSink`, which is what let it inherit the demod tap's rules whole: it
sits in the same sink table, is refused on a raw-IQ channel for the same reason the demod tap is
(nothing there produces audio to take a spectrum of), and is torn down with the audio streams on an
audio-rate change (`BulkSubscription.readsChannelAudio` is the one place that says so for both).
`AudioSpectrumSink` keeps a `2 × bins` sliding window, emits every `rate / rows_per_second`
samples, and scales by `-20·log10(Σw/2)` -- the half being the energy a real sine puts in its
negative frequency -- so a full-scale sine reads 0 dBFS at its bin, which a synthetic test asserts
to 0.5 dB on a bin centre. The fixture tests read the pair of taps as spectra: the PL and the voice
tone are the demod tap's two peaks, and 100 Hz is more than 12 dB down on the audio tap. Absurd
`bins` and `rows_per_second` clamp rather than refuse, like the ladder's.

### SV-10c `[x]` `ley levels` (Go lane, against the fake)

Everything in the design's `ley levels` section, as written: the octave bands on ISO centres
(`--bands third` at ≥ 100 columns), band levels as power sums of the row's bins back to dB, the
master `rms` and `peak` pair from the daemon's `METER` telemetry (`audio_dbfs`, `audio_peak_dbfs`),
the meter's scale (6 dB rows to −24, 10 dB below, −18 dBFS horizon as a dashed `Muted` rule), the
LED ladders (column ramp for sub-levels, lit part in `ui.Style.Level`, unlit `░` in `Muted`, cap
`━` in `Label`, `OVER` in `Err` latched two seconds), the ballistics (instant attack, 20 dB/s
release, cap holds 1.5 s then falls 10 dB/s; presentation only), the header (channel, mode, tap,
squelch, PL), the numbers under the master pair from the current row, twenty frames a second in
place, degradation with colour off and under `--ascii`, and the width rules. Flags as the design
lists. `--json`: one object per row, raw and unsmoothed: `{seq, sample_index, tap, bands:
[{center_hz, db}], rms_dbfs, peak_dbfs}`. Tests: goldens in both alphabets for a still frame,
unit tests for the ballistics and the scale mapping, band summing against a synthetic row, `--json`
shape, the tree walk picks the verb up.

The meter is drawn as one block packed from the left -- bands, a wider gap, then the master pair --
rather than spread to the resolved width: a picture whose bars drift apart as the terminal grows
is harder to compare with yesterday's than one that keeps its shape, and the gap is what makes the
pair read as a second instrument. The `OVER` line is drawn only while something is lit, because a
frame carrying a blank line reads as the end of one where frames are separated by blank lines. The
scale's rows are a piecewise ruler (`levelsRows`), so the gutter's marks and the bars are placed by
one function and land on the same rows; at the default height each mark gets a row of its own. In
`--json` the master pair is `null` until the daemon's first meter, the way `scope`'s `tone_hz` is
absent until it has looked: the alternative is a level nobody measured, and NaN is not JSON. The
axis has no cross glyph where the horizon meets it -- the alphabet carries none and the dashed rule
is what names the alignment level -- so the gutter is the scope's, `│` on every row.

### SV-10d `[x]` `ley waveform` (Go lane, against the fake)

Everything in the design's `ley waveform` section: over the audio stream the scope subscribes
(share its subscription and stats code), peak envelope per column symmetric about the centre,
braille with the ASCII fallback, column ink from the level ramp for its peak, a centre rule through
silence, squelch-closed slices blank (state from `METER` telemetry on either tap), the DC offset
removed on the demod tap and said in the header, newest at the right under a `Label` playhead, a
seconds axis in the scope's axis style, `--seconds` 2..120 (default 10), `--scale` as the scope
with `auto` the default, `--tap`, `--rate`, `--count`, `--width`. `--json`: one object per column
as it completes: `{sample_index, seconds, peak_dbfs, rms_dbfs, squelch_open}`. Tests: goldens in
both alphabets, the blank-when-squelched rule, DC removal, `--json` shape, the tree walk.

A column is a fixed number of samples rather than a slice of wall clock, so the axis measures the
signal the picture is built from and the `--json` rows carry the same slices the picture would
have drawn at that width. Each one is folded from five running numbers -- count, sum, sum of
squares and the two extremes -- so a two-minute window costs what a two-second one does, and the
demod tap's offset comes out of the peak and the rms together rather than being drawn around; the
header says how much was taken out. A slice whose envelope reaches no dot either side of the
centre is drawn as the centre rule, because below that the picture cannot resolve it and a pair of
marks around the axis would claim more than the view knows. Blank is kept for what never came
through -- a slice the squelch was shut for, or a column the run has not reached -- so a gap reads
as a gap; a slice the squelch opened partway through counts as open, since something did come
through it. The playhead is the alphabet's own vertical stroke in `Label` ink, and the gutter,
the scale and the ASCII fallback are the scope's, so a clip and a trace asked for the same
`--width` line up.

### SV-10e `[x]` End to end, and the docs (cross-language, last)

`go/internal/e2e`: play `fixtures/nfm_pl.cf32` through the real daemon; `ley levels --tap demod
--json --count 5` reports the 125 Hz band (88–177 Hz, where the 100 Hz PL falls) and the 1 kHz
band as the two loudest; `--tap audio` has the 1 kHz band loudest and the 125 Hz band at least
10 dB lower than on the demod tap; `ley waveform --seconds 2 --json --count 10` columns have
finite peaks and `squelch_open` true. Docs: `docs/interfaces.md` tree and the bulk-row exception
paragraph (the audio-spectrum rows are FFT rows, the two `--json` shapes are named), a
`docs/cli-guide.md` section "Hear it with your eyes" with both transcripts recorded against the
fake, README's "What works today" sentence, and `docs/design-audio-meters.md`'s status line.

The e2e reads the meters as numbers rather than pictures: `ley levels --json` over the real daemon
on `nfm_pl.cf32` puts the 125 Hz and 1 kHz octave bands at the top of the demod tap and drops 125 Hz
by more than 10 dB on the audio tap, which is the high-pass doing what the guide says it does, and
the band levels are averaged over the five rows so one row caught between syllables cannot decide
the order. The guide's section is section 8, ahead of the two-channel one, so the three audio views
sit together; its waveform transcript is recorded with `--squelch -50` against the fake, whose
carrier power swings through that threshold, because a steady tone at full duty draws a solid block
and the picture is about when something came through. The `--json` shapes are described in prose
there rather than shown, the way `scope`'s are: a nine-band row is one 470-character line.

### SV-10f `[x]` What the second look at the audio spectrum found (cross-language)

An independent read of `fe26cd3..54ca99f`, after the per-item verifiers. Line numbers as of
`54ca99f`. Engine, fake, client and docs together.

1. **Cap channel-sourced `bins` at 4096**, the design's number, in the engine
   (`AudioSpectrum.swift:23` rounds up the whole ladder to 16384, a 32768-point transform inline
   on the DSP thread) and in the fake (`fakedaemon/bulk.go:102-110`); a larger request rounds down
   to 4096 and the descriptor says so; the proto comment on `FftParams` states the cap for a
   channel source and that each subscription runs its own transform (so N subscribers on one tap
   cost N transforms, bounded by the cap). `MalformedInputTests.swift:225` asserts the cap.
2. **One default row rate.** An unset, non-positive or non-finite `rows_per_second` on a
   channel-sourced FFT means 10 in both implementations, like the capture-sourced FFT
   (`StreamRegistry.swift:167`); the engine's `AudioSpectrum.swift:26-29` and
   `MalformedInputTests.swift:226-227` change from 20 to 10, the fake at `bulk.go:192-194` already
   reads 10. The maximum stays 20.
3. **Validate `accumulation` on the channel path** in both: a known value is answered
   `ROW_SNAPSHOT` (a row is one transform of the window), `UNRECOGNIZED` is `INVALID_ARGUMENT`,
   exactly as the capture path does two lines below (`StreamRegistry.swift:172-179`,
   `fakedaemon/bulk.go:227-236`).
4. `AudioSpectrumSink.write` (`AudioSpectrum.swift:95`) brackets itself with the `.audioWrite`
   signpost like `CallbackSink` and `CoreAudioSink` do; `emit` keeps `.fft`.
5. `AudioSpectrum.swift:63`: the `precondition(audioRate > 0)` on a client-reachable path becomes
   a thrown `INVALID_ARGUMENT` at subscribe.
6. Say the two facts the audit measured: bin 0 carries DC at 6 dB above a tone of the same
   amplitude (no mirror image), which matters only on the demod tap and sits below the 63 Hz band
   anyway; and a row emitted across a retune straddles it, which is accepted. Both in
   `docs/engine-internals.md`'s audio-spectrum paragraph, the first also in the proto comment.
7. Small truths: `AudioSpectrumStreamTests.swift:84` claims a −200 dB floor an empty row would
   read; it reads about −248 at 512 bins, so say "the floor an empty row reads" without the
   number; `:73-80` bounds its `for try await` with the harness's deadline pattern;
   `AudioSpectrumTests.swift:97-98` reports a timeout as a failure, not a failure and a skip;
   `go/pkg/leyline/client.go:~505` says a raw-IQ channel refuses either tap;
   `go/internal/fakedaemon/streams_test.go:~561` stops saying FFT is capture-scoped;
   `docs/design-audio-meters.md:24` reads "256 … 4096, the design's cap for this path" and stays
   true after item 1; wrap `docs/engine-internals.md:228` and `docs/plans/signal-views.md:474`.

Both suites green, `make proto` clean, the e2e green at the end.

### SV-10g `[x]` `ley levels` behaves like `spectrum`, and tells the truth about tones and squelch (Go lane)

- **Snapshot by default, `--watch` for live**, exactly `spectrum`'s shape: the bare verb prints one
  frame after the first complete row and exits (no ballistics, no caps in a snapshot; `--json`
  prints that one row); `--watch` is the twenty-frames-a-second meter with `--rate` and `--count`
  as they are today. The guide and `interfaces.md` say so; the design doc's transcript is the
  snapshot.
- **Squelch closed means nothing coming through.** On either tap, while `METER` reports
  `squelch_open` false, every ladder draws unlit and the header says `squelch closed`; the caps
  do not update. The raw rows still go out under `--json` with the squelch state alongside
  (`"squelch_open": false`). The demod tap between words still shows the PL, because the squelch
  is open then.
- **Band sums corrected for the window.** A Hann-windowed tone spreads over about 1.5 bins of
  power, so a band sum overstates a tone by 1.76 dB (measured on the PL fixture: −15.6 and −4.3
  where the tones are −17.1 and −6.0). Divide each band's power sum by the window's equivalent
  noise bandwidth (1.5 for Hann) before the dB; a tone then reads its own level and broadband power
  is still right. The e2e on `nfm_pl.cf32` asserts the 125 Hz band within 1 dB of −17 and the
  1 kHz band within 1 dB of −6 on the demod tap.
- Tests against the fake for the snapshot, the watch loop, the squelch-closed rendering in both
  alphabets, the corrected sums; goldens re-recorded where the header moved.

### SV-10h `[x]` The waveform as a clip, and frames on the three views (Go lane)

- **Filled columns, not dots.** The envelope column is drawn with the block glyphs `█`, `▀` and
  `▄`: full cells between the edges, `▄` for a top cell whose edge falls in its lower half and `▀`
  for a bottom cell whose edge falls in its upper half, so both edges have half-row precision and
  the clip is solid, as an editor draws it. `--ascii` uses `#`. Braille stays on the scope, which
  is a line.
- **Ink relative to the scale on screen.** A column's ramp fraction is its peak over the current
  scale (`peak / scale`), so the loudest thing on screen is hot and a quiet passage at
  `--scale 0.1` still has colour; the header's `scale ±n` says what full colour means. Squelched
  slices stay blank.
- **The same frame `spectrum` has.** `levels`, `waveform` and `scope` wrap their chart and axis in
  `ui.Style.Box` the way `spectrum_render.go:137` does, header above the frame, width accounted
  for so nothing exceeds `--width`. Goldens re-recorded; the guide's transcripts re-recorded
  against the fake.

### SV-11 `[x]` One chart toolkit, one colour rule (Go lane)

The four live views and `spectrum` each carry their own header line, gutter, axis, frame handling,
in-place redraw and ramp normalisation. Consolidate into one package-level toolkit in
`go/internal/cli` (a `chart.go` with the shared pieces; `ui` stays the palette and glyph layer):

- `headerSeg`/header line (scope and waveform already share one; spectrum and levels join it);
  the dB or amplitude gutter; one axis renderer (`spectrum_axis.go`, `scope_axis.go` and the
  waveform's are three copies of the same tick-and-label rule); the `Box` framing with width
  accounting; the in-place redraw writer.
- **One ramp normalisation** in one place with named constants: `rampFrac(value, floor, top)`,
  where the floor is the chart's own reference (the noise line for `spectrum`, −60 dBFS for
  `levels`, zero for the waveform's scale), replacing `levelFrac(band)` and `levelsFrac(dBFS)`.
  `docs/cli-style.md` section 3a gains the sentence that says what the cold end is per chart.
- `spectrum`'s goldens must be byte-identical after the change (it is the reference the others
  join); the other views' goldens change only where SV-10h intended. `waterfall` and `phosphor`
  adopt the header and axis pieces where they fit without changing their pictures.

## SV-12 `[x]` Full scale is the channel's own limit

A narrow-mode handheld (`fixtures/ht-narrow.cu8`: PL at 305 Hz, speech to 2.8 kHz) draws at a
quarter of the trace and plays quietly, because NFM full scale is hard-wired to ±5 kHz while the
default channel is 12.5 kHz wide and cannot carry more than ±2.5 kHz. Three items, in order.

Closed 2026-09-12 (d87c5b8, e860a98, 347b009): the owner confirmed on the real handheld that
scope, waveform and levels all fill the trace now. Measured on the narrow take, speech p90 moved
from −10.0 to −4.1 dBFS and the PL band from −24.3 to −18.3 dBFS.

### SV-12a `[x]` The full-scale deviation on the wire (cross-language, first)

`proto/leyline/v1/bulk.proto`: `AudioParams` gains `uint32 full_scale_deviation_hz = 4`, set by the
daemon in the answered descriptor for FM modes (0 for AM, SSB and CW, whose taps are amplitude,
not deviation): the deviation that ±1.0 on either tap stands for. Comment: it follows the channel's
bandwidth for NFM (`min(5000, max(2500, bandwidth / 5))`, so 12.5 kHz → 2.5 kHz and 25 kHz →
5 kHz) and is 75 kHz for WFM; a client converts a DC offset or a peak to hertz with it and never
hard-codes a number. `make proto`. The fake echoes it by the same rule. `go/pkg/leyline` exposes it
on the `Subscription`'s descriptor as it does the rest.

### SV-12b `[x]` The engine scales to the channel (Swift lane)

- `NFMDemodulator.configure(inputRate:bandwidthHz:)` sets `scale` from `fullScaleDeviationHz =
  min(5000, max(2500, bandwidthHz / 5))` instead of the constant; the sub-audible detector's
  `deviation_hz` and the tap ring keep reporting hertz correctly (they convert amplitude with the
  same number); `WFMDemodulator` stays at 75 kHz. The daemon fills `full_scale_deviation_hz`.
- The audio path inherits the change (a narrow channel now plays 6 dB louder), which is what a
  radio does; the limiter stays at ±1.
- Tests: `DemodTapTests` and `AudioSpectrumTests` absolute levels move by +6 dB on the 12.5 kHz
  fixture channels (the PL band to about −11, the 1 kHz tone to about 0); a test that a 25 kHz
  channel keeps the old numbers; `SubAudibleTests` still see 700 Hz on `nfm_pl`; fixture
  round-trips green. `docs/engine-internals.md` Demodulators paragraph states the rule.

### SV-12c `[x]` The views follow the descriptor, and a burst cannot own the scale (Go lane)

- `scope`, `waveform` and `levels` read `full_scale_deviation_hz` from the descriptor for every
  hertz readout (tuning error, the header's "full scale ±n kHz" note); the `nfmFullScaleHz` and
  `wfmFullScaleHz` constants go, with a fallback only for a descriptor that reports 0 on an FM mode.
- `scope` defaults to `--scale auto`, as `waveform` does; `full` stays available.
- Auto scale on both is fitted to a high percentile of the recent column or frame peaks (the 90th
  over the hold window) rather than the maximum, so the squelch tail's burst, one column at 4.8×
  full scale, no longer sets the scale for the next second; the burst itself still draws, clamped.
- The e2e meters assertions move with SV-12b (−11 and 0 within a dB on the demod tap). Goldens
  and the guide's transcripts re-recorded against the fake; the guide's "looking at speech"
  paragraph says why a narrow radio fills the trace now.
