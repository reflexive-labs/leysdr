# Design: Scope — the audio waveform, and what sits under it

Status: implemented (`ley scope`). Companion to `signal-views.md` (which owns the spectrum, waterfall
and channel views) and `docs/dev/cli-style.md` (which owns how anything is drawn).

## Context

`ley spectrum` and `ley waterfall` show what is on the air; `ley listen` hands a script the audio
samples; nothing shows a person what the demodulator produced. Two questions come up that only a
waveform answers:

1. **What does the mode actually do?** The level meter and the spectrum are the same in every
   mode, because both are measured before demodulation. The difference is in the waveform: an FM
   voice through the AM detector is a near-flat line with ripple, a carrier in CW is a sine, and
   NFM voice looks like voice.
2. **What is under the voice on a 2 m channel?** A CTCSS (PL) tone at 67–254 Hz is transmitted
   with almost every repeater exchange. It never reaches the speaker: the NFM chain high-passes at
   300 Hz before de-emphasis specifically to remove it, and the sub-audible detector reads a tap
   taken *before* that filter. A waveform of what you hear cannot show it. A waveform of the
   discriminator can.

So the view needs two taps; the second is the main reason to build it.

## Two taps

- **`audio`** — what the speaker gets: after the high-pass, de-emphasis, limiter and AGC. The default.
- **`demod`** — the detector's own output before any audio conditioning. For NFM that is the
  discriminator: the voice, the PL tone riding under it, and a DC offset that is the tuning error
  in hertz, read against the channel's own full-scale deviation (±2.5 kHz ≙ ±1.0 on a 12.5 kHz
  channel), which the audio descriptor answers. For AM it is the envelope, carrier level included
  as DC. For USB/LSB and CW it is the product detector before AGC. For WFM it is the discriminator
  before the 15 kHz audio low-pass, so the 19 kHz stereo pilot is visible at 48 kHz. When the
  squelch is closed the `audio` tap is zeros, as it is for the speaker; the `demod` tap keeps
  flowing, because it exists to show what the transmitter sends between words.

Both taps are the existing `AUDIO` bulk stream at the channel's audio rate (48 kHz at 2.4 MSPS),
`S16` or `F32`, `LATEST_WINS`. The wire change is one additive field:
`AudioParams.tap` (`AUDIO = 0`, the default, `DEMOD = 1`). Everything about negotiation, gaps and
teardown is unchanged.

## Daemon

`Demodulator.process` gains a second, optional output: the raw stage, written into a scratch
buffer sized at `configure` (hot path stays allocation-free, invariant 4). `NFMDemodulator` already
has this signal — it fills the sub-audible tap ring from it — so the change is routing, not DSP.
`ChannelDSPCore` hands the raw block to the sinks that subscribed with `tap = DEMOD` and the
conditioned block to the rest; a channel with no `DEMOD` subscriber pays one branch. `rawIQ`
channels have no demod tap (there is no detector) and the subscription is refused with
`INVALID_ARGUMENT`. The fake daemon synthesises the `demod` tap as its audio plus the PL tone it
already uses to drive `SUB_AUDIBLE` telemetry, so the CLI view is testable.

## The view

`ley scope [frequency|preset|channel] [--tap audio|demod] [--window MS] [--trigger auto|free]
[--rate N] [--count N]`, plus the tune flags every listening verb takes.

- One window of samples per frame, drawn as a trace across the terminal width; the vertical axis is
  a fraction of full scale, which on the `demod` tap of an FM mode is the deviation the daemon
  answers in the audio descriptor (±2.5 kHz on a 12.5 kHz NFM channel, ±75 kHz on WFM) and which the
  header shows. Braille cells (2 × 4 dots) on terminals that have them; the `--ascii` set draws with
  three levels per cell. Up to 20 frames a second; `--count` bounds it for scripts.
- `--window` defaults to 40 ms: a syllable of voice, two cycles of 50 Hz, four of a 100 Hz tone.
- `--trigger auto` (default) starts each frame at a rising zero crossing when the window is
  periodic enough to hold still (a tone, a PL tone between words), else free-runs; `free` never
  triggers. This is presentation, the same as a bench scope's trigger.
- The header shows the channel, mode, tap and window, and the frame's peak and RMS in dBFS. On the
  `demod` tap it adds the deviation full scale stands for and the DC offset as a tuning error in
  hertz for FM modes. When the daemon's sub-audible detector has a tone it prints `PL 100.0 Hz
  (measured 100.02 Hz, 18 dB, confidence 0.9)` from the `SUB_AUDIBLE` telemetry. **The number always
  comes from the daemon; the view never estimates the tone itself** (invariant 2 and the
  detector-stays-honest rule). The trace shows the raw signal and the header shows the daemon's
  measurement; they can disagree, and the trace lets you check the measurement.
- `--json` prints one object per frame, `{seq, sample_index, sample_rate, tap, window_ms,
  peak_dbfs, rms_dbfs, dc, tone_hz}`, with no samples: the samples are `ley listen --format json`.
  `peak`, `rms` and `dc` are frame statistics, presentation over the daemon's stream, like
  `spectrum`'s peaks.

## What it shows

- Tune a repeater (NFM), then `ley set mode am` from another terminal: the voice trace collapses to
  a ripple; `ley set mode cw`: a 700 Hz sine while the carrier is up; back to `nfm`: voice.
- `ley scope --tap demod` on the same channel: the voice rides on a slow undulation, four cycles
  across the screen at 100 Hz, and the header shows the tone. Between words only the undulation
  remains. The trace sits above or below centre by the tuning error.
- A broadcast station in WFM on the `demod` tap: the 19 kHz pilot as fine hash on the trace.

## Later, not now

An **audio spectrogram** (`ley sonogram`): a daemon-side FFT ladder over the audio or demod tap,
rendered like the waterfall. It shows a PL tone as a line at 100 Hz, voice as formants, a 1750 Hz
tone burst, DTMF, and the tones of digital modes. It is the right tool for "which sub-audible
frequencies", and it belongs in the daemon (invariant 2: no FFTs client-side). The scope is the
cheaper half and stands on its own.

## Cost

Engine M (a second output on the demodulator protocol, which is hand-written and may change;
routing in the channel core; fixture tests that the NFM `demod` tap carries the PL fixture's tone),
proto S, daemon and fake S, CLI M (the trace renderer, trigger, header, tests), docs S. About the
size of `ley phosphor`.
