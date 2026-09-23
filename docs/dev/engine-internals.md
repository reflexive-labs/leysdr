# Engine internals

Status: v0 implementation contract. Companion to `docs/design/control-plane.md` and `docs/design/data-planes.md`;
the wire contract is `proto/leyline/v1`, the engine contract is `engine/Sources/EngineCore/CoreProtocols.swift`.
AGENTS.md invariants apply throughout; this doc says *how* the engine keeps them.

## Module map

```
swift/LeylineProto/           SwiftPM package: generated leyline.v1 messages + grpc-swift 2 stubs —
                              never hand-edit (`make proto`). Its own package outside engine/, so the
                              Apache-2.0 contract is not inside the GPL directory and the app can
                              depend on it without the engine (../decisions/D2-licensing.md).

engine/                       SwiftPM package (macOS 26+, Swift 6 toolchain, Swift 5 language mode),
                              depending on swift/LeylineProto for the contract
├── Sources/CRTLSDR           optional dlopen shim over librtlsdr
├── Sources/CHackRF           optional dlopen shim over libhackrf
├── Sources/EngineCore        the engine. Proto-free: it never imports LeylineProto.
│   ├── CoreProtocols.swift   the contract (hand-written)
│   ├── Identifiers.swift     ULID + prefixed IDs
│   ├── Buffers.swift         SampleBuffer / SampleFormat / SampleStorage
│   ├── Model.swift           DeviceDescriptor, GainElement, ChannelConfig helpers, EngineError codes
│   ├── Rings.swift           lock-free SPSC rings (audio floats, sample blocks)
│   ├── Signposts.swift       os_signpost wrappers (no-op off macOS)
│   ├── BlockingWork.swift    runs non-cancellable blocking calls (device open/close) off the cooperative pool
│   ├── Devices/              DefaultDeviceRegistry, RTLSDRDevice, RTLTCPDevice, FilePlaybackDevice, IQFile (sidecar format)
│   ├── Capture/              DefaultCaptureEngine (actor façade) + CaptureDSPCore (hot path, DSP thread)
│   ├── Channels/             DefaultChannelEngine (actor façade) + ChannelDSPCore (hot path)
│   ├── DSP/                  Kernels (Accelerate + portable), FIR, NCO, Channelizer, Demodulators, FFT, SpectrumLadder,
│   │                         SweepPlan (scan job sweep math), EnergyDetector (carrier detection), SubAudible (CTCSS),
│   │                         Persistence (phosphor histogram)
│   └── Sinks/                CoreAudioSink (AVFoundation), NullSink, CallbackSink
├── Sources/LeylineDaemon     `leylined`: gRPC over UDS; maps EngineCore <-> leyline.v1
│   ├── DaemonCommand.swift   ArgumentParser entry (--socket, --log-level, --pidfile)
│   ├── Server.swift          GRPCServer + UDS lifecycle + signals
│   ├── ClientContext.swift   per-RPC client identity (interceptor -> task-local)
│   ├── Session/              SessionStore actor (devices/captures/channels/sinks tables, events, attribution)
│   ├── Jobs/                 JobStore (durable job table), ScanRunner (sweep execution), DecodeRunner
│   │                         (a decode job's plugin and its records), SessionCaptureAllocator
│   │                         (don't-disturb capture and channel leasing for jobs)
│   ├── Decoders/             DecoderRegistry (manifests on disk), PluginProcess (the stdio wire),
│   │                         RecordHub (the live plane), RecordStore/RecordWriter (kept records)
│   ├── Recording/            RecordRunner (a record job's drain and gate), RecordGateMachine (the
│   │                         squelch state machine, no DSP), PartWriter (one open file + the
│   │                         manifest), RecordingStore (the directory, retention, restart repair),
│   │                         PlaybackEngine + WAVReader (playing a recording back through the
│   │                         daemon's own audio device)
│   ├── Services/             Control, Telemetry, Bulk, Jobs (scan, monitor, decode and record
│   │                         implemented; watch UNIMPLEMENTED), Decoders, Resources
│   ├── Bulk/                 stream registry: FFT/audio/IQ subscriptions -> rings -> gRPC frames
│   ├── WriteCoalescer.swift  ParamWrite coalescing
│   ├── RememberedDevices.swift  devices.json beside the socket: the rtl_tcp endpoints to re-attach
│   └── Mapping/              engine <-> proto conversions
├── Tests/EngineCoreTests     unit tests; fixture round-trips. Most of the target builds and runs on Linux;
│                             `KernelParityTests` and anything under `#if canImport(Accelerate)` or
│                             `#if canImport(AVFoundation)` need macOS and do not compile elsewhere.
└── Tests/TestSupport         fakes both test targets drive (the rtl_tcp server); no product depends on it
```

Go clients live in `go/` (`docs/reference/cli.md` for the verb tree). `go/internal/fakedaemon` is an in-memory
implementation of the leyline.v1 services used to test `ley` without hardware or Swift.

## Threads and ownership

There are exactly three kinds of execution context in the engine. Every function is in one of them.

1. **Device I/O thread** — owned by the `RadioDevice`. `RTLSDRDevice` runs `rtlsdr_read_async` on a
   dedicated `Thread`; `FilePlaybackDevice` runs a paced reader `Thread`. The device calls `deliver`
   with a borrowed native-format `SampleBuffer` (`.cu8` for RTL-SDR, `.cf32` for files) and the
   `SampleTime` of the first sample. `deliver` must return quickly: it converts into the next free
   slot of the capture's block ring and signals the DSP thread. A full ring drops the block, counts
   an overrun, and emits a signpost — it never blocks the device. A capture ring carries complex
   baseband only: a real-valued (`.f32`) buffer is refused before it can take a slot or move the
   timeline, and counted as `CaptureStats.unsupportedBlocks` so a misrouted device never reads as a
   throughput problem.
2. **DSP thread** — one per capture (`Thread`, `.userInteractive` QoS, named `leyline.dsp.<cap_id>`).
   Loop: wait for a block; snapshot the channel table; for each channel run
   channelizer → demodulator → squelch/meter → `AudioSink.write`; run the spectrum ladder; feed
   capture taps. Everything here is synchronous, allocation-free and lock-free. Config changes
   arrive by *swapping* immutable tables (see below), never by mutating shared state under the DSP thread.
3. **Control plane** — Swift concurrency. `DefaultCaptureEngine`, `DefaultChannelEngine`,
   `DefaultDeviceRegistry` and the daemon's `SessionStore` are actors. They own the hot-path core
   objects and hand them configuration.

### Hot-path rules (invariant 4, enforced)

- No `async`, no `await`, no actor hops, no `Task`, no `DispatchQueue` from the device or DSP thread.
- No allocation: all scratch is `SampleStorage` sized at configure time for `maxBlock`. If a block
  would exceed scratch, process it in sub-blocks; never grow.
- No locks *held across calls*. Config handoff uses one pattern: the control side builds a new
  immutable table (channels, subscribers, taps) and stores it under an `NSLock`; the DSP thread
  takes the lock, copies the reference, releases — a few nanoseconds, once per block. Anything
  finer-grained than "per block" is unnecessary at 16384-sample blocks.
- Sinks copy-or-consume. `CoreAudioSink.write` pushes into an SPSC float ring the render callback
  drains; bulk-stream sinks push into a slot ring and poke an `AsyncStream<Void>` (buffering
  newest 1) whose reader `Task` drains the ring into gRPC frames.
- `os_signpost` intervals around: block ingest, per-channel process, ladder pass, ring overrun
  events. Category `"SamplePath"`. The spikes (S1/S2) are measured from these.

### Block size

Ring blocks are 16384 complex samples. `RTLSDRDevice` asks librtlsdr for `buf_len = 32768` bytes
(`buf_num = 32`), so one USB callback is exactly one slot. A libhackrf callback is larger; capture
ingest splits it into 16384-sample slots without allocating. The block ring holds 64 slots of cf32
(8 MiB per capture, ~0.44 s at 2.4 MSPS). `FilePlaybackDevice` delivers the same block size.

## Capture pipeline

```
device (cu8/cs8/cf32) ──deliver──▶ convert to cf32 ──▶ BlockRing ──▶ DSP thread
                                                                   ├─▶ Channel[n]: NCO mix ▶ FIR↓D1 ▶ FIR↓D2 ▶ demod ▶ squelch ▶ sinks
                                                                   ├─▶ SpectrumLadder: window ▶ FFT(N) ▶ |X|² dB ▶ subscribers (rate-limited)
                                                                   └─▶ CaptureTaps: cf32 blocks (IQ recording / IQ bulk stream)
```

### Conversion

`.cu8 → .cf32`: `(u − 127.5) / 127.5`, done in one vDSP pass (`vDSP_vfltu8` with stride, then
`vDSP_vsmsa`). Portable kernel does the same loop. `.cs8 → .cf32`: `/128`; `.cs16 → .cf32`:
`/32768`. Before the
conversion, `deliver` walks the native block once more for the samples at the converter's rails
and the peak (`Kernels.countAtRails*`, the same plain loop on both platforms), which is where the
capture's level comes from ("Telemetry service" below).

### Timebase and anchor

`SampleTime.sampleIndex` is the count of samples delivered on this capture's timeline since the
capture first streamed. The `CaptureAnchor` is set when the first block arrives:
`hostTimeNsAtSampleZero = now − blockDuration`. Retune does not restart the stream and does not
touch the anchor. Sample-rate change restarts the stream: the index continues monotonically (no
reset) and a new anchor is published (`Event.anchor`). Device loss → `.detached`; rebind on
matching-serial replug continues the same `CaptureID` and index and publishes a new anchor.

**Capture-owned index base.** Devices number samples per stream: `RTLTCPDevice`, the rtl-sdr
callback and `FilePlaybackDevice` all restart at 0 on every `startStreaming`. The capture, not the
device, owns the timeline. `CaptureDSPCore` keeps an `indexBase`; `expectNewAnchor()` (called by
`DefaultCaptureEngine` before every stream start) marks the next delivered block as the start of a
new *device epoch*, and on that block the core sets `indexBase = lastDeliveredEnd − deviceIndex` so
the committed index `deviceIndex + indexBase` continues exactly where the previous epoch ended. The
anchor is computed from the rebased index, so `hostTimeNsAtSampleZero` and frame `SampleTime`s
agree. Before installing a new rate `setSampleRate` waits for the DSP thread to drain the ring
(`drainPending`) so no old-rate block is processed under the new plan, and the spectrum ladder
clamps each subscriber's `nextDue` to at most one interval past the current index so a shrunken
interval (or a rewound timeline from a misbehaving device) can never stall rows.

**Channels start over across a restart.** Alongside `expectNewAnchor()`, `DefaultCaptureEngine`
calls `captureStreamRestarted()` on every channel before the stream starts, which resets that
channel's `ChannelDSPCore`: filter history, NCO phase, demodulator, the meter's last block power and
the transmission in progress all go, and the capture forgets its band floor (`BandFloor.reset`) so
the first block of the new stream is read for a fresh one. The samples either side of the gap are not continuous, so filtering
the first blocks against pre-gap history, judging them against a floor measured on the old stream,
or reporting an open duration that spans the dead air would all report signal that was never received.
A squelch that was open when the reset lands gets a close record stamped with the last block the
channel saw, so the transmission ends on the wire instead of vanishing and the sub-audible detector
drops the phase history it had been building. The reset needs nothing in flight: the device is
stopped and the ring drained first. That drain is bounded, and if it expires while the DSP thread is
still running the resets are skipped and logged rather than run against a block mid-flight.

### Channelizer plan

Given capture rate `Fs` and mode:

- Stage 1: `D1 = max(1, floor(Fs / 240_000))`, `r1 = Fs / D1` (≥ 240 kHz). Complex NCO mix at
  `−offsetHz` (phase accumulator, oscillator block generated with `vvsincosf`) then FIR low-pass +
  decimate (`vDSP_zrdesamp`, polyphase-efficient: only kept outputs are computed). Cutoff:
  `min(bw/2 + 5 kHz, 0.4·r1)` for narrow modes; `bw/2` for WFM (bw 200 k → 100 k < r1/2).
- Stage 2 (narrow modes only): `D2 = round(r1 / 48_000)`, `r2 = r1 / D2` (≈ 48 kHz). An anti-alias
  FIR (cutoff `0.45·r2`, transition `0.1·r2`, ~200 taps at `r1`) decimates to `r2`, then a
  non-decimating selectivity FIR at `r2` with cutoff `bw/2` (transition `≤ cutoff/2`, up to 2047
  taps) — that filter *is* the channel bandwidth, so a 500 Hz CW channel rejects a tone 1 kHz off
  by > 40 dB. Narrow-mode `bandwidthHz` above `0.9·r2` (43.2 kHz at 2.4 MSPS) is rejected with
  `INVALID_ARGUMENT` rather than silently clamped; wide channels use WFM. WFM demodulates at `r1`
  and decimates its audio by `D2` after the discriminator.
- The channel's `audioRate` is `r2` (≈ 48 kHz; exactly 48 000 at 2.4 MSPS). CoreAudio is told the
  true rate; AVAudioEngine converts to the device rate.
- FIR design: windowed sinc (Blackman), taps chosen from the transition width
  (`taps ≈ 4·rate/transition`, odd, capped at 1023 for the decimating stages and 2047 for the
  selectivity filter at `r2`). Filter history of `taps−1` samples is kept across blocks so
  decimation phase is continuous.
- SSB/CW: the NCO offset is shifted by `±bw/2` so the wanted sideband is centred at DC for the
  stage-2 low-pass, then the demodulator mixes back by `∓bw/2` (CW: to a 700 Hz BFO) and takes the
  real part.

### Demodulators (all vDSP-backed on macOS; see `DSP/Kernels.swift`)

- **NFM**: quadrature discriminator `arg(x[n]·conj(x[n−1]))` (`vDSP_zvmul` conjugate + `vvatan2f`),
  scaled so the channel's own full-scale deviation ≈ ±1.0 — `min(5 kHz, max(2.5 kHz, bw/5))`, so a
  12.5 kHz channel reads ±2.5 kHz and a 25 kHz one ±5 kHz, because a narrow-mode radio cannot send
  more than its channel carries and should be as loud on the trace and in the speaker as a wide one;
  a 300 Hz two-pole high-pass pushes CTCSS/PL tones under the voice (about 20 dB at 100 Hz, of which the make-up gain below returns some 6 dB), then 6 dB/octave de-emphasis above 300 Hz (τ ≈ 530 µs, matching transmitter pre-emphasis) with ×2 make-up gain, then a 1-pole LPF ≈ 4 kHz; output hard-limited
  to ±1 (unsquelched noise otherwise reaches ±2.4).
- **WFM**: same discriminator at `r1`, ±75 kHz deviation, 75 µs de-emphasis, FIR LPF 15 kHz +
  decimate by `D2`, output hard-limited to ±1. Mono in v0.
- **AM**: `|x|` (`vDSP_zvabs`), DC block (1-pole HPF ≈ 50 Hz), audio LPF ≈ 5 kHz, gain normalised
  by a slow envelope when `agc == .auto`.
- **USB/LSB/CW**: product detector as above, gain normalised by the same slow envelope of the
  channel IQ magnitude when `agc == .auto` (so a −30 dBFS SSB signal plays at the same level as AM).
- **rawIQ**: no demodulation; channel IQ is available to taps/stream sinks only (no audio).

`Demodulator.configure` allocates all scratch; `process` allocates nothing. Each demodulator keeps
one sample of history for the discriminator and IIR states in stored properties.

### The demod tap

`process` takes an optional second output, `rawOut`, and fills it with the detector's own stage
before any audio conditioning: the discriminator ahead of the 300 Hz high-pass for NFM (the very
samples the sub-audible tap reads, so a CTCSS tone is still on them) and, decimated to the audio
rate ahead of de-emphasis and the 15 kHz low-pass, for WFM (so the 19 kHz pilot survives); the
envelope with the carrier still in it as DC for AM; the product detector before AGC for USB, LSB
and CW; nothing for raw IQ. Both FM stages are scaled so full-scale deviation reads ±1.0 — the
channel's limit for NFM, 75 kHz for WFM — which makes the block's mean the tuning error in units of
full-scale deviation. The daemon reports that deviation in the audio descriptor's
`full_scale_deviation_hz` (0 for the amplitude modes), which is what a client multiplies by; no
client carries a full scale of its own. The callee sets
`rawOut.count`, because WFM decimates the tap through a filter of its own and handles its own
alignment; every buffer either needs is sized in `configure`, so a block nobody is tapping costs a
nil check.

`AudioSink` carries an `AudioTap`, and `ChannelDSPCore` keeps one sink table plus a cached
`hasDemodSink`, recomputed when the table is set: the conditioned block goes to `.audio` sinks, the
raw block to `.demod` sinks, and the demodulator is handed a raw buffer only while something asked
for one, so a channel nobody scopes pays a single branch per block. The squelch's zeroing is part
of what a listener hears, so it applies to `.audio` sinks alone; the demod tap keeps flowing through a
closed squelch, so a client can see what the transmitter sends between words.
Both taps stamp a block with the same `SampleTime` — the capture time the block started — but the
two taps are not sample-aligned. WFM's tap runs its
own decimator, which is reset alone when a tap attaches mid-stream, so from then on the two block
counts can differ by one, and the two filters have different group delay (about 0.3 ms) in any case.
That is acceptable for a scope; anything needing the two stages aligned to the sample needs a
daemon-side sink, not two subscriptions.

The squelch decision and the power and SNR telemetry still come from the channelized IQ, before
either tap; only the audio-level meter reads the conditioned block. A raw-IQ channel has no
detector, so attaching a `.demod` sink to one is `INVALID_ARGUMENT`, and so is a `TAP_DEMOD`
subscription over the bulk plane.

### The audio spectrum

A channel tap has a spectrum of its own, computed by `AudioSpectrumSink`: an `AudioSink` like any
other, so it rides the same sink table and the same tap rules, and a channel nobody is metering
does no work for it at all. It keeps a sliding window of `2 × bins` samples of whichever tap it
asked for, and whenever the window has advanced by `rate / rows_per_second` samples it Hann-windows
the newest window, runs it through the ladder's `FFTPlan` with a zero imaginary half, and emits the
first `bins` magnitudes in dB — 0 Hz to half the audio rate, DC first, not fft-shifted, because
half the row of a real signal is the mirror of the other half. The scale is `-20·log10(Σw/2)`,
where the half is the energy a real sine puts in its negative frequency, so a full-scale sine reads
about 0 dBFS at its own bin. Window and scratch are sized at subscribe: the write path copies,
transforms and calls the `SpectrumSink`, and allocates nothing.

A row rate faster than the window is long overlaps windows, a slower one leaves samples between
them unused, and either way the row is the newest window rather than a summary of the interval
it closed — which is what a meter wants, and the reason `accumulation` does not apply here.
`bins` rounds to a ladder size so every FFT reader's row layout holds, capped at 4096 because every
subscription on a tap runs its own transform, and rows are capped at 20 a second and default to 10
— a row is a whole transform, and a meter is read by eye. Over the bulk plane this is `kind = FFT`
with a `channel_id` source; the descriptor answers `center_hz = rate/4` and `span_hz = rate/2`,
`ROW_SNAPSHOT` with one look, and the tap it serves. A raw-IQ channel has no audio and refuses with
`INVALID_ARGUMENT`, as does an unknown tap, an unknown `accumulation`, or a channel with no audio
rate yet. Because the stream reads a channel tap, it ends exactly as a bulk audio stream does when
the audio rate under it can move. Each row is stamped with the index of the sample that completed
its window, so the rows one block yields carry different times and advance by exactly the hop;
a row stamped with its block's first sample would be the same instant as the row before it.

Two inaccuracies in the row are documented rather than corrected.
Bin 0 is DC, and the window puts a DC offset
there about 6 dB above a tone of the same amplitude, with no mirrored copy of it further up the
row — only the demod tap carries an offset worth naming (AM's carrier), and bin 0 sits below the
lowest band a meter draws, so nothing is subtracted for it. And a row is emitted from the window as
it stands when it comes due, so one that spans a retune straddles the two frequencies; at a couple
of tens of milliseconds the smear is over before the next row, and pausing the meter across a
retune would cost more than it buys.

### Squelch and meters

Per block the channel computes mean power of the post-filter IQ in dBFS (`10·log10(mean|x|²)`).
Squelch opens when power > threshold, closes when power < threshold − 2 dB (hysteresis). While
closed the channel writes zeros to sinks so audio timing stays continuous. Meter cadence: every
100 ms of samples, emit `.meter`; on state change emit `.squelch` with the exact block start time.
`snrDB` is the block's power over the band's floor at the channel's width: the capture's
`BandFloor` reads a 1024-bin row of its own four times a second on the DSP thread (one transform
and one selection per row; `CaptureDSPCore.processBlock` runs it before the channels so the first
meter has a floor), takes the median bin as the floor per bin and publishes it as a density,
dBFS per hertz, in one atomic; each channel adds `10·log10(bandwidth)` once per block. That is
the same number the Mac app's "over noise" and `ley tune`'s auto squelch compute from a 2048-bin
row (median bin plus `10·log10(bandwidth / bin width)`; the bin count cancels), so the meter and
the clients agree by construction. NaN until a row has been read, which is the first block of a
stream. Until 2026-09-19 the floor was the channel's own running minimum over 5 s, which on a
carrier that never stops is the carrier, so a −12 dBFS signal read 0 dB over noise. The squelch
never reads `snrDB`: it compares power to its threshold in dBFS. The FM demodulators keep a
`DiscriminatorInterval` (sum, count, high and low of the raw discriminator since the last meter,
folded in where the sub-audible tap reads, ahead of de-emphasis and the high-pass), and the meter
takes it: the DC times the hertz per unit is `freqErrorHz`, positive when the transmitter sits
above the channel (the discriminator is `arg(x[n]·conj(x[n−1]))` and the channelizer mixes the
offset down to zero), and the larger excursion from that DC is `deviationHz`. Both are NaN for
every other mode, and `freqErrorHz` is NaN while the squelch is closed, because noise has no
tuning error. WFM's interval is read at `r1` with 150 kHz per unit, since its discriminator puts
±75 kHz at ±0.5.

Telemetry records leave the DSP thread through `ChannelTelemetryQueue`, a fixed-capacity (64) ring
with per-slot seqlock versions. Policy is drop-oldest: a full ring evicts the oldest unread record
(the producer advances `head` by CAS and counts it in `dropped`) so a stalled drain always sees the
newest readings; the consumer re-checks the slot version and retries if the producer overwrote it
mid-copy. Push and pop are allocation- and lock-free.

### Spectrum ladder

Sizes: 256, 512, 1024, 2048, 4096, 8192, 16384 (all ≤ one block). Per tick (max 30 Hz; tick rate
= highest subscriber rate) the ladder computes each *requested* size once from the most recent
block, Hann window, `vDSP_DFT_zop` on split complex, `|X|²` → dBFS with `10·log10(|X|²/(N·Σw)²)`
scaling so a full-scale tone reads ≈ 0 dBFS, fft-shifted so index 0 is `center − Fs/2`. Each
subscriber receives rows at ≤ its requested rate; `actualBins` is the nearest ladder size (rounded
up; capped to 16384), `actualRate` is `min(requested, 30)`.

## Devices

The two local USB libraries are runtime-loaded independently. `leylined` therefore builds and
starts with neither installed; the registry logs an unavailable backend once and continues with
the other local driver, `rtl_tcp`, and file playback. `LEYLINE_RTLSDR_LIBRARY` and
`LEYLINE_HACKRF_LIBRARY` can name an exact library path for tests or non-Homebrew installs. Loading
is once per process, so installing or replacing a library requires a daemon restart. The
`sdr-loader-test` gate exercises neither, each alone, and both with mock shared libraries.

### RTLSDRDevice (librtlsdr, libusb-backed — see docs/decisions/S3-usb-posture.md)

- Enumeration: `rtlsdr_get_device_count`, `rtlsdr_get_device_usb_strings` (no open needed). Tuner
  type and gain table need an open device: the registry opens each *unclaimed* device once at
  discovery, reads `rtlsdr_get_tuner_type` + `rtlsdr_get_tuner_gains`, closes, and caches on the
  `RTLSDRDevice`; later polls never re-open a successfully probed dongle. A dongle whose probe open
  fails is held by another program (rtl_tcp, SDR++, GQRX): the registry reports it `IN_USE` with
  feature `held_externally`, logs it once, and re-probes on a doubling backoff (2 s up to 60 s)
  rather than every poll, because each failed `rtlsdr_open` makes librtlsdr print its
  `usb_claim_interface` complaint to stderr. A successful re-probe (or one of our own captures
  opening it) flips it back to `AVAILABLE` with the real tuner and gain table. The reverse also
  holds: when a capture's own `rtlsdr_open` fails with a libusb ACCESS/BUSY code (another program
  grabbed a dongle that had probed fine), `RTLSDRDevice.open` throws `DEVICE_BUSY` naming the other
  program and the session store calls `markHeldExternally`, so the dongle reads `IN_USE` and the
  backoff re-probe starts from there.
  `RTLSDRDevice.open` retries `rtlsdr_open` once after 50 ms so a transient claim does not fail the
  capture.
- Descriptor: driver `"rtlsdr"`, model from USB product string, serial from USB serial (Nooelec
  dongles often ship `"00000001"` — stable IDs key on `(serial, usbLocation)` where
  `usbLocation` is the enumeration index-independent USB strings tuple; identical duplicates fall
  back to index order and are flagged in `features["serial_collision"]`). Tuning range by tuner
  (R820T/R828D: 24 MHz–1.766 GHz; E4000: 52–2200 MHz with the 1.1–1.25 GHz gap as two ranges;
  FC0012/13: 22–948 / 22–1100 MHz). Sample rates: `[250_000, 1_024_000, 1_536_000, 1_800_000,
  1_920_000, 2_048_000, 2_400_000, 2_560_000, 2_880_000, 3_200_000]`. Native format `.cu8`,
  advertised on the wire as `CS8`. Gain element `"TUNER"` with `validDB` from the tuner gain table
  (tenths of dB → dB), `supportsAuto = true` (`rtlsdr_set_tuner_gain_mode(0)`). Features:
  `bias_tee` (flag, settable), `direct_sampling` (integer 0/1/2), `ppm_correction` (integer),
  `tuner` (text), `rtl_agc` (flag).
- Streaming: `rtlsdr_reset_buffer` then `rtlsdr_read_async(cb, ctx, 32, 32768)` on a dedicated
  thread; `stopStreaming` waits for the thread's `started` handshake, calls `rtlsdr_cancel_async`
  until it takes (it is a no-op before the thread reaches `rtlsdr_read_async`) and joins with a
  bounded wait — never unbounded; a `rtlsdr_read_async` failure clears `streaming`, is exposed as
  `streamError`, and reports `.disconnected` through the state-change hook so the capture detaches
  like a physical unplug. The callback context is an
  `Unmanaged` pointer to the device; the callback must not touch Swift concurrency.
- Retune and gain changes are applied directly while streaming (librtlsdr supports this).
  `setSampleRate` refuses with `DEVICE_BUSY` while a stream is live (or while a detached USB thread
  is still recorded): the caller stops the stream, sets the rate and starts again, and that restart
  is what re-anchors the capture timeline.
- Hot-plug: the registry polls enumeration every 1 s while idle (cheap USB descriptor reads) and
  publishes `arrived`/`removed`. IOKit arrival notifications are a later refinement.
  `leylined --no-hardware` never starts the poll: the daemon hosts only what is attached to it
  (file devices, rtl_tcp), for a run that must see nothing but its test radios, such as an eval's.

### HackRFDevice (libhackrf, libusb-backed)

- Enumeration: `hackrf_device_list` supplies stable serials. The registry briefly opens an
  unclaimed radio once to read its board id, which distinguishes HackRF Pro from the USB-compatible
  HackRF One, then caches the probe. Claimed devices are listed without opening; another program's
  claim is reported as `IN_USE` and retried with the same 2–60 s backoff as RTL-SDR.
- Descriptor: driver `"hackrf"`; HackRF Pro advertises its 100 kHz–6 GHz operating range and other
  boards the common 1 MHz–6 GHz range. The discrete rates Leyline offers are 2, 2.4, 4, 8, 10,
  12.5, 16 and 20 MSPS. Native format is `.cs8`, libhackrf's backwards-compatible interleaved
  signed 8-bit I/Q mode. Gains are three manual elements: `LNA` (0–40 dB, 8 dB step), `VGA`
  (0–62 dB, 2 dB step), and `AMP` (off or approximately 11 dB). HackRF has no RX AGC and opens
  at the conservative `hackrf_transfer` defaults of LNA 8 dB, VGA 20 dB and AMP off.
- Open applies the cached sample rate, frequency and all three gain stages before exposing the
  handle. `hackrf_start_rx` owns the transfer thread and calls the allocation-free Swift callback;
  `hackrf_stop_rx` joins it before the borrowed callback state is cleared. Retune and gain changes
  are live; sample-rate changes refuse while streaming so the capture can stop, change, restart and
  publish the new anchor.
- libhackrf's legacy queue is four 262144-byte transfers, or 524288 complex samples. That bound is
  `inFlightSamples`, so scan settling discards samples the driver requested before a retune.
- This is receive support only. HackRF hardware is half-duplex and advertises `tx_capable`, but a
  future transmit implementation composes the separate transmit protocol; `RadioDevice` stays RX.
  HackRF Pro's extended-precision and half-precision modes are also later work; the basic path is
  the compatibility mode documented by Great Scott Gadgets.

### FilePlaybackDevice

Reads the IQ file format in `docs/reference/iq-files.md` (`<name>.cf32` + `<name>.json`). Descriptor: driver
`"file"`, model = file name, serial = path hash, one tuning range `[center, center]`, one sample rate,
native `.cf32`, no gain elements, features `loop`, `duration_s`, `path`. Streaming is paced to real
time by default (sleep per block); `realtime: false` (tests, `leyline` internal only) delivers as fast
as the consumer drains. At EOF: loop if configured, else stop delivering and mark the device
`disconnected` (the capture goes `detached`, exactly like an unplug).

### RTLTCPDevice (remote dongle over rtl_tcp)

A dongle served by osmocom's `rtl_tcp` on another machine, presented as a virtual device. Clients
attach one with `Control.AttachDevice{rtl_tcp{host, port}}` (see "Remembered devices"); a foreground
run can also name endpoints with `leylined --rtltcp host:port` (repeatable; env `LEYLINE_RTLTCP`,
comma-separated). Both paths go through `DeviceRegistry.attachVirtualDevice`, which identifies a hosted
virtual device by driver and address alone — an endpoint hosted before it responds cannot report
its tuner, and the model string must not make it appear as a second radio.
A server that cannot be reached
at startup is hosted `DISCONNECTED` for the reconnect poll to pick up, never fatal.

This is a supported backend, not a contingency (`docs/decisions/D2-licensing.md` requires this,
because it is the fallback if a proprietary daemon is ever required). Its
coverage: `RTLTCPTests` and `RemoteDeviceTests` against `TestSupport`'s fake server, and
`TestRemoteRadioAgainstRealDaemon` in the e2e, all part of `make check` on both CI hosts.

- Transport: BSD sockets (no Network framework, so it builds and tests on Linux). `open()` connects
  with a 5 s timeout, reads the 12-byte header (`"RTL0"`, u32be tuner type, u32be gain count), sends
  the initial sample rate (`0x02`) and frequency (`0x01`), then starts one reader `Thread`
  (`leyline.rtltcp.<host>:<port>`). Commands are 5-byte `opcode + u32be` frames, never acknowledged;
  they are written from the control plane under the device lock and never contend with the reader.
- Descriptor: driver `"rtltcp"`, model `rtl_tcp <host>:<port> (<tuner>)`, serial `<host>:<port>`
  (the registry identity), empty `usbLocation`. Tuning ranges by tuner code use `RTLSDRDevice`'s
  table; sample rates are `RTLSDRDevice.sampleRates`; native `.cu8`. Gain element `TUNER` carries
  librtlsdr's fixed table for the reported tuner (R820T/R828D 29 entries, E4000 14, FC0012 5,
  FC0013 23, FC2580 and unknown `{0}`); the header's gain count is only cross-checked against it
  (a mismatch is logged — the remote is not stock librtlsdr). Features: `tuner`, `remote` (read-only),
  `bias_tee` (`0x0e`), `direct_sampling` (`0x09`), `ppm_correction` (`0x05`), `rtl_agc` (`0x08`).
  `setGain`: auto → `0x03/0`; dB → snap to the table, `0x03/1` then `0x04` tenths.
- Streaming: the socket flows from the moment of connect (rtl_tcp serves one client and drops one
  that stops reading), so the reader always drains. It recv's straight into one preallocated
  32768-byte `SampleStorage` (exactly 16384 cu8 samples, partial reads accumulated) and, once per
  full block, snapshots `(streaming, deliver, captureID, generation)` under the lock and calls
  `deliver` with the lock released — or discards the block when not streaming. `startStreaming`
  only arms delivery and restarts the sample index at 0; `stopStreaming` disarms it, waits for any
  in-flight `deliver` call to return (the reader raises `inDeliver` in the same critical section
  as the snapshot; the device lock is an `NSCondition`), and the connection stays up. `open()`
  connects and reads the header with the lock released. No allocation and no Swift concurrency on
  the reader.
- Loss: a read that times out (5 s) or a peer close makes the exiting reader close the socket and
  clear the fd/thread slots itself (a concurrent `close()` keeps ownership of the socket and the
  reader only signals the join), then report `.disconnected` through the same state-change hook
  `FilePlaybackDevice` uses, so the registry publishes `changed` and the capture detaches. `close()`
  shuts the socket down and joins the reader without waiting for a read timeout.
- Reconnect: `DefaultDeviceRegistry.poll()` gives every hosted `RTLTCPDevice` in `.disconnected` one
  `open()` attempt per poll (a detached task, so the 5 s connect timeout never blocks the actor; at
  most one attempt in flight per device). On success the entry is `.available` and `arrived` is
  published under the same id, which `SessionStore` handles like any device arrival: a capture left
  detached by the loss rebinds through `deviceRebound`. A failed attempt is retried on the next poll.
- Retune, gain and sample-rate changes are sent live; the sample index does not reset on a rate
  change.

## Daemon

### Client identity and ownership

gRPC has no connection identity, so clients declare one: every RPC carries metadata
`leyline-client-id` (a `cli_` ULID the client generates once per process), `leyline-client-kind`
(`cli` | `app` | `mcp` | `job`) and `leyline-client-label`. A server interceptor parses these into a
task-local `ClientContext.current`; missing metadata gets a fresh id per RPC and kind `"unknown"`.
Every event's `caused_by` is that context.

Presence: a client is *present* while it has at least one open streaming RPC (`WatchEvents`,
`Telemetry.Subscribe`, `Bulk.Stream`, `WriteParams`). Non-persistent channels (and their sinks) owned
by a client are torn down 5 s after its presence ends; clients that only make unary calls are
present for 5 s after each call. `ley tune` holds `WatchEvents` open for its lifetime, which is what
keeps its channel alive; `ley tune --persistent` creates a persistent channel and exits.

### SessionStore

One actor owns the tables: devices (mirrors the registry), captures (`CaptureEngine` per
`CaptureID`), channels, sinks, and the monotonically increasing event sequence. Every mutation goes
through it and emits exactly one event carrying the full new state of the changed object. Subscribers
(`WatchEvents`) get an `AsyncStream` with `bufferingNewest(256)`; a client that observes a `seq` gap
re-fetches `GetState`. The store also retains the last 256 events: `WatchEvents` with `since_seq`
(a `GetState` snapshot's `event_seq`) replays the retained events newer than it, scope-filtered and in
order, before the live subscription — on the actor, so the two cannot interleave — which is how
"GetState then WatchEvents" misses nothing. Go clients pass `leyline.ScopeSince(scope, state.EventSeq)`.

Activity: `last_interactive_write_ns` is updated by any capture/channel write whose client kind is not
`job`; `live_audio_sinks` counts attached system-audio sinks. This is the don't-disturb signal.

### Control service

- `CreateCapture`: one capture per device (`DEVICE_BUSY` otherwise). Validates centre/rate against the
  descriptor. `sample_rate == 0` → device default (2.4 MSPS for RTL-SDR, file rate for playback).
- `CreateChannel`: validates `|offset| + bw/2 ≤ Fs/2` (`OFFSET_OUT_OF_CAPTURE`). `bandwidth_hz == 0` →
  mode default. Owner = calling client.
- `AttachSink`: `system_audio` → `CoreAudioSink` (`PLATFORM_UNSUPPORTED` off macOS); `stream` →
  the sink is the bulk-plane handle (clients use `Bulk.Subscribe` on the channel instead — v0
  returns `UNIMPLEMENTED` for attaching a stream sink directly); `file` → `UNIMPLEMENTED`, and
  stays so: a recording is a job's output (`Jobs.StartJob(RecordConfig)`, "Recording" below), because
  a sink attached to a channel dies with that channel's owner and leaves a file nothing indexes.
- `WriteParams`: `WriteCoalescer` keeps last value per `(target_id, param case)` and applies every
  20 ms. Rejections become `WriteRejected` events with the client tag. `gain` writes target the
  capture's device, and an empty `element` is the first the device lists (`common.proto`); the
  confirmed value comes back in the `Capture.gains` field of the capture event under that name.
  A `mode` write re-decides `subaudible_detect` (on for NFM, the only mode CTCSS is sent under,
  off otherwise), so a channel that started in another mode looks for a tone once it is NFM.
  On a channel that is `OUT_OF_CAPTURE` every non-offset write (`bandwidth_hz`, `mode`, `squelch_db`)
  is stored and used by the rebuild when the capture moves back over the channel — the channel stays
  `OUT_OF_CAPTURE` at its absolute frequency; only an `offset_hz` write is checked against the capture
  right away.
- `AttachDevice`: a `file` source is the `AttachFileDevice` path (ephemeral); an `rtl_tcp` source
  opens an `RTLTCPDevice` with the 5 s connect timeout and hosts it. `AttachFileDevice` and
  `DetachFileDevice` stay as sugar; `DetachFileDevice` only matches file devices, so any other
  device is `DEVICE_NOT_FOUND` there.
- `DetachDevice`: any device a client attached, file or remote radio, closed with its captures. A
  dongle plugged into this machine is `INVALID_ARGUMENT` ("unplug it"), rejected before anything is
  touched (`DeviceRegistry.isDetachableVirtualDevice`).
- Errors: `RPCError(code:message:)` with the `EngineError.code` string in the message and the
  proto `ErrorDetail` serialised into trailing metadata key `leyline-error-bin`.

### Remembered devices

Persistence follows intent (invariant 8): a file a client plays is gone with the daemon, a radio it
attached is part of the station. `AttachDevice{rtl_tcp}` writes `host`/`port` to `devices.json`
beside the socket (`{"rtl_tcp":[{"host":"pi.local","port":1234}]}`), rewritten on every change;
`DetachDevice` takes it out. At startup the daemon opens the `--rtltcp` endpoints and then the
remembered ones, deduplicated on `host:port`, so an endpoint named both ways is opened once. Attach
dedupes the same way before constructing anything: a second attach of a hosted endpoint returns the
existing descriptor, and a second attach of an endpoint whose connect is still in flight waits on
that one rather than opening a second socket. A server that cannot be reached by an attach is
`DEVICE_IO` naming the endpoint with nothing remembered — an endpoint that never connects is usually
a typo.
Detach and attach can overlap, so the order is fixed: detach drops the device from the session table
before it forgets the endpoint, and both attach paths re-check the table after their awaits and take
the line back out if it has gone. Whichever runs last, a detached radio stays detached.

The registry records how each hosted virtual device arrived. A radio named by `--rtltcp` is operator
configuration: `DetachDevice` refuses it with `INVALID_ARGUMENT` naming the flag, because the
daemon's command line would re-attach it at the next start. Attaching that endpoint
over the protocol makes it the client's — the descriptor comes back unchanged, the endpoint is
remembered, and from then on it persists and detaches like any other.

An endpoint that is unreachable at startup, remembered or flagged, is hosted anyway as a
`DISCONNECTED` device, so the registry's reconnect poll — which only retries devices it holds —
brings it in as soon as it responds; the log line says the daemon is waiting for it. One dead remote
never keeps the daemon from serving local dongles. An unreadable `devices.json` is read as an empty
list: losing the remembered remote endpoints is better than refusing to serve local dongles.

### Error codes

Every stable code a daemon puts in `ErrorDetail.code`, and the gRPC status it is served with. This
table is the contract: `ProtoMapping.statusCode(for:)` and `leyline.GRPCCode` each follow it, a test
on each side holds its switch against these rows, and the same tests assert that the two registries —
`EngineError.Code.all` and `leyline.DaemonCodes` — are the same set. A consumer that reads the status
rather than the trailer (a retry interceptor, a mesh policy, a client in a fourth language) then gets
the same answer from `leylined` and from the fake daemon. `FAILED_PRECONDITION` is deliberate where
`RESOURCE_EXHAUSTED` would read as natural: the latter is retriable under default gRPC retry policies,
and a radio someone else is using must not be retried blind.

| Code | gRPC status | Raised when |
| --- | --- | --- |
| `DEVICE_NOT_FOUND` | `NOT_FOUND` | no device with that id |
| `DEVICE_BUSY` | `FAILED_PRECONDITION` | the device already has a capture, or another program holds it |
| `DEVICE_SWEEPING` | `FAILED_PRECONDITION` | a scan job holds the device; it is free when the scan ends |
| `DEVICE_DETACHED` | `UNAVAILABLE` | the dongle went away and may come back |
| `DEVICE_IO` | `UNAVAILABLE` | the driver failed a read or a control transfer |
| `NO_DEVICE` | `FAILED_PRECONDITION` | no radio here can serve the request (job allocation) |
| `FREQ_OUT_OF_RANGE` | `INVALID_ARGUMENT` | the frequency is outside every tuning range |
| `RATE_UNSUPPORTED` | `INVALID_ARGUMENT` | the sample rate is not one the device offers |
| `OFFSET_OUT_OF_CAPTURE` | `INVALID_ARGUMENT` | the channel does not fit inside the capture bandwidth |
| `BLIND_SPOT` | `INVALID_ARGUMENT` | the span lies inside the device's own DC guard (job allocation) |
| `GAIN_ELEMENT_UNKNOWN` | `INVALID_ARGUMENT` | no gain element by that name on this device |
| `CAPTURE_NOT_FOUND` | `NOT_FOUND` | no capture with that id |
| `CHANNEL_NOT_FOUND` | `NOT_FOUND` | no channel with that id |
| `SINK_NOT_FOUND` | `NOT_FOUND` | no sink with that id |
| `STREAM_NOT_FOUND` | `NOT_FOUND` | no bulk stream with that id |
| `JOB_NOT_FOUND` | `NOT_FOUND` | no job with that id, and no recording either: a recording's id is its job's, so `RESOURCE_NOT_FOUND` does not exist |
| `SCAN_NOT_FOUND` | `NOT_FOUND` | no scan result with that id (sixteen are kept) |
| `DECODER_NOT_FOUND` | `NOT_FOUND` | no installed decoder by that name (`ley decoders` lists them) |
| `DECODER_FAILED` | `FAILED_PRECONDITION` | the decoder's program could not be started: missing, not executable, or exited before reading its descriptor |
| `MODE_UNSUPPORTED` | `UNIMPLEMENTED` | the demodulator is not built into this daemon |
| `UNIMPLEMENTED` | `UNIMPLEMENTED` | the RPC or option arrives in a later milestone |
| `PLATFORM_UNSUPPORTED` | `UNIMPLEMENTED` | the feature needs macOS frameworks |
| `FAILED_PRECONDITION` | `FAILED_PRECONDITION` | a precondition the caller can see and fix, where no code above fits |
| `INVALID_ARGUMENT` | `INVALID_ARGUMENT` | an argument the caller can fix, where no code above fits |
| `INTERNAL` | `INTERNAL` | a fault the caller did not cause and cannot act on |

`SOCKET_IN_USE` is daemon-local: `leylined` refuses to start when another one is listening, so no
client ever receives it and it is not in the registries.

### Telemetry service

`Subscribe` merges the per-channel drains and capture activity into one stream with a monotonic
`seq`. Delivery is drop-oldest with visible gaps across all three telemetry buffers: the channel's
telemetry ring (64, `telemetryDropped`), the engine's per-subscriber fan-out buffer (256,
`ChannelTelemetrySubscription.dropped` — `AsyncStream.Continuation.yield` reports the discard), and
the service's merged buffer (64, a discarded item is folded into a counter along with the gap it
carried). Each drain diffs the ring and fan-out counters between records, the consumer diffs the
merged counter before every message, and `seq` advances by `lost + 1`, so every record lost anywhere
between the DSP thread and the wire shows up as a hole in `seq` (a gap accrued behind a filtered-out
type carries over to the next message sent). The RPC ends when the client cancels
(`withRPCCancellationHandler` finishes the merged stream — gRPC cancellation is not task
cancellation) or when the daemon shuts down and finishes the event stream.

`CaptureLevel` is the capture's raw level, and the clipping authority: the loudest FFT bin is a
proxy that reads near full scale on a strong steady carrier at auto gain when nothing is wrong.
`CaptureDSPCore.deliver` counts the rails on the native block before the ring (a block the ring
drops is one the converter still saw): `Kernels.countAtRails{CU8,CS8,CS16,CF32}` walk the block
once and return the complex samples with I or Q at a rail (a cu8 byte at 0 or 255, cs8 at −128
or 127, cs16 at the int16 extremes, a cf32 component at or beyond ±1) and the largest component
magnitude in full-scale units — samples, not components, so a sample with both at a rail is one
clipped sample and the fraction against `total_samples` is a fraction of time. `CaptureLevelMeter`
(`DSP/CaptureLevel.swift`) accumulates them in device-thread scalars and publishes one reading per
`sampleRate / 4` samples (the `BandFloor` cadence) through a seqlock of four atomics, so neither
side allocates or locks (invariant 4); a stream restart drops the interval in progress with the
floor. `TelemetryService` polls the meter every 100 ms per capture-scoped subscription and sends a
reading once, by generation, as `CaptureLevel{clipped_samples, total_samples, peak_dbfs}` with
`time` at the interval's end (invariant 5); a silent interval's `peak_dbfs` is floored at −200
like the meter's audio peak. It rides with `CaptureActivity` on capture and daemon scopes, never on
a channel scope. The clients take the fraction: `ley levels`' OVER and `ley tune`'s failure line
(`clippingFloor`, one in ten thousand) report clipping only when the count shows it,
and fall back to the loudest-bin rule only when no `CaptureLevel` arrives
(an older daemon).

### Bulk service

`Subscribe` answers with an authoritative `StreamDescriptor`. v0 rules: transport is always
`grpc` (SHM_RING requests are downgraded — the ring is a later milestone); `start` must be `live`
(`UNIMPLEMENTED` otherwise); policy defaults to `LATEST_WINS`, `GAP_MARKED` honoured by emitting `Gap`.
FFT: bins/rate via the ladder; bin format `DB_F32` (little-endian f32) or `DB_U8`
(`clamp(round((db + 120) · 2), 0, 255)`). An FFT whose source is a channel is that channel's audio
spectrum instead of the band's (see “The audio spectrum”), and is torn down with the audio streams
rather than with the ladder's. Audio: channel `audioRate`, `S16` or `F32` mono; a
requested `sample_rate` that is neither 0 nor the channel's rate is `INVALID_ARGUMENT` (no
resampling in v0, and the daemon never upgrades). Any write that re-plans a channel at a new audio
rate — a capture-rate write, a retune that brings the channel back into capture, a mode, bandwidth
or offset write — rebuilds that channel's system-audio sinks under their existing ids and ends its
bulk audio streams, both taps. A write that leaves the audio rate alone but moves what the
descriptor answered — a bandwidth write that rescales the NFM detector's `full_scale_deviation_hz`,
or a mode write — ends the bulk audio streams too (the system-audio sinks keep playing at the rate
they have), because a client converting to hertz with the old number would be wrong by the ratio
for as long as it stayed subscribed. A capture-rate write ends every bulk audio stream on the capture even
when no audio rate moved: audio frames scale their sample spans by the capture rate, and two capture
rates can plan to the same audio rate. Re-subscribe for a fresh descriptor. IQ: capture rate only,
`CF32` only (no resampling in v0). `Stream` writes frames until the client cancels; `Unsubscribe`
tears the subscription down; a subscription with no `Stream` reader for 10 s is reaped.

### Jobs service and lease lifecycle

`StartJob(ScanConfig{once})` is implemented (Milestone D.13), and so are `StartJob(DecodeConfig)`
("Decoders" below), `StartJob(MonitorConfig)` and `StartJob(RecordConfig)` ("Recording" below); a
`watch` config and `GetTranscript` still return `UNIMPLEMENTED`. A scan job never touches a capture directly
(invariant 9): it asks `SessionCaptureAllocator` for a range, and the allocator either hands back a
`CaptureLease` or a declined result with a reason. Allocation prefers a device with no capture at all
over borrowing one that has one, because creating and destroying a capture affects no other
client. Borrowing an existing
capture is refused by the don't-disturb check (`inUse`: an owning channel, a live audio sink, or an
interactive write in the last 60 s) unless the caller passed `take_over`; a leased capture is marked
*swept* in `SessionStore`, and `refuseIfSwept` rejects interactive `WriteParams`/`CreateChannel` calls
on it for as long as the lease holds. `SweepPlan.edgeFraction` widens a device's tuning range slightly
when deciding whether it can cover a request, which is how a `FilePlaybackDevice` — whose "range" is
the single frequency its fixture was recorded at — can still serve a sweep. Releasing a lease that
created its capture destroys it; releasing one that borrowed an existing capture retunes and re-gains
it back to what it found and clears swept.

### Decoders

A decoder is an out-of-process plugin the daemon spawns (`docs/design/decoders.md`, "Decisions").
Nothing about it runs on the DSP thread (invariant 4): the channel's existing `AudioFrameSource`
callback is the only hot-path code, and every byte that reaches a plugin is written by a task
draining its ring.

`DecoderRegistry` reads `manifest.json` — the proto3 JSON form of `DecoderManifest` — from every
directory on the search path and executes nothing, so a plugin whose binary is broken still lists
and a manifest that does not parse costs a log line. The search path is `--decoders` (repeatable),
then `LEYLINE_DECODERS` (colon-separated), then the platform default
(`~/Library/Application Support/Leyline/decoders` on macOS, `$XDG_DATA_HOME/leyline/decoders`
elsewhere). Names are unique and the first directory wins. `executable` resolves against the
plugin's directory first and `PATH` second.

`PluginProcess` is one spawned child: stdin carries one varint-delimited `StreamDescriptor` then
varint-delimited `Frame`s (`AUDIO`, `F32`, mono, the channel's rate, `GAP_MARKED`, the tap the
manifest asked for), stdout carries varint-delimited `DecodeRecord`s, and stderr is prose logged
under `leyline.decoder.<name>`. The framing is protobuf's own delimited convention, coded by hand
because `BinaryDelimited` takes Foundation streams and a pipe file descriptor is not one. `stop()`
closes stdin, waits 2 s, then `SIGTERM`, then `SIGKILL`; a write to a dead pipe is an error return,
never a signal.

`JobStore.startDecode` looks the decoder up (`DECODER_NOT_FOUND`), refuses `SLOT_ALIGNED` with
`UNIMPLEMENTED`, and asks `SessionCaptureAllocator` for `AllocationRequest.channel`. That path takes
a capture that already covers the frequency on any device, else a device with no capture (creating
one centred `frequency − Fs/8`, so the channel sits clear of the tuner's DC spike and inside the
flat part of the passband), else a capture the don't-disturb test calls free (retuned), else it
declines with the reason a sweep would give unless `take_over`. The channel is persistent with
`required_hz` set and is owned by the job, not by the client. Releasing the `ChannelLease` destroys
the channel, and the capture too when the lease created it and nothing else is listening on it.

`DecodeRunner` then holds one drain task (ring to plugin, with a `Gap` on every frame that follows a
drop), one reader task (plugin to `RecordHub` and the store writer), a meter subscription and a
channel-state watch. The daemon stamps `record_id` (`rec_<ulid>`), `job_id`, `seq` (1-based and
contiguous per job), `channel_id` and `rssi_dbfs`/`snr_db` from the channel's latest meter; a
plugin's own values for those are overwritten. A plugin that exits is spawned again after 1 s,
doubling to 30 s, with the job in `DEGRADED` and `status_detail` saying so; the drain outlives the
restart, because `AudioFrameSource.poke` has one iterator and a second one would feed the new plugin
nothing. A channel that goes `OUT_OF_CAPTURE` degrades the job and comes back to `RUNNING` with the
capture. `keep` jobs are not cancelled when their client goes; cancel stops the plugin, closes the
writer and releases the lease.

`RecordHub` is the live plane: drop-oldest, 256 deep, scoped to everything, one job or one protocol,
with the last 256 records per job replayed for `since_seq` — replay and live delivery both happen on
the actor, so a subscriber cannot see them interleaved. `RecordStore` is the kept plane: a kept job
writes `<store>/records/<job_id>.records` (varint-delimited records, flushed every 32 records or
second) beside `<job_id>.json` holding the config, the decoder's name and version, every
`CaptureAnchor` that was in force and the count. A query scans the sidecars, skips the files whose
protocol or wall-clock span cannot match, filters the rest in memory, sorts newest first and cuts at
`limit` (default 1000). There is no index, and there will be a SQLite one when a query is measured
to be slow, not before. Retention (`--store-cap`, default 2 GiB; `--store-age`, default 90 days)
runs at daemon start and whenever a kept job starts: age first, then the oldest until the store
fits.

### Recording

A recording is a job's output (`docs/design/recording.md`); `Control.AttachSink(file)` stays
`UNIMPLEMENTED`, because a sink attached to somebody's channel dies with that channel's owner and
leaves a file nothing indexes. `RecordRunner` is built like `DecodeRunner` and is the only runner
for both forms: the audio form borrows or leases a `ChannelLease` and reads it through the same
`AudioFrameSource` (a `CallbackSink` into a `FloatRing`) the bulk audio path uses, and the IQ form
takes a `CaptureIQLease` and an `IQFrameTap` into a `FrameRing` exactly as `IQDecodeRunner` does.
Nothing new runs on the DSP thread: the drain task pops the ring and hands blocks to `PartWriter`,
which converts f32 to S16, accumulates peak and mean, and writes the files.

The channel form borrows: `BorrowedChannelLease.release()` does nothing, so recording what
somebody is listening to leaves their channel and their radio exactly as it found them, and the
runner polls `SessionStore.channelEngine` so that the owner destroying the channel ends the job
`COMPLETED` rather than orphaning a sink. The frequency form takes a real lease from the
allocator, which is what hands the radio back when the job ends.

`RecordGateMachine` is the squelch gate and has no clock and no DSP: it is driven by the channel's
own squelch transitions (through `telemetrySubscription`, never a second reader on the DSP-side
ring) and by the drain's progress along the capture timeline, and it returns actions --
open a part at *this* sample, note an over, close the part at the close transition plus the hang,
end the job on quiet. Deciding at frame granularity sets the accuracy: a cut lands within one
capture block of the transition (16384 samples, 6.8 ms at 2.4 MSPS). Audio arriving while no part
is open goes into a pre-roll ring allocated once at start, so a part can begin before the squelch
did. A gated recording with no squelch on its channel measures one from the channel's own meter
and sits 10 dB above it, which is `ley tune`'s auto squelch done where the channel is.

`duration_ms` is enforced twice, on the samples and on the clock, and whichever comes first ends
the job: the sample check is the accurate one, but a radio that stops delivering -- a file device
at the end of its file, a dongle unplugged -- would otherwise leave a job that asked for five
minutes running for ever.

`PartWriter` owns one open file at a time: a WAV opens with placeholder lengths that are patched
from the file's own size on close, a cf32 is appended raw, and the part's sidecar and the manifest
are written when it closes. The manifest is rewritten atomically on every change, so a client
reading a running recording always sees a consistent file. `RecordingStore` is the directory
(`--recordings`, default beside the record store), its retention (`--recordings-cap`, default
20 GiB; `--recordings-age`, default 0) and the restart repair: at boot, any manifest with no
`ended_by` has its unlisted part files' headers patched from their lengths, those parts joined to
it, and `ended_by = restart` written. A recording is a bounded artefact and does not resume;
whoever wanted a longer one starts another. Retention runs when a recording opens and when one
ends, and never removes a recording whose job is running.

**Playing one back.** `PlaybackEngine` (`Recording/PlaybackEngine.swift`) is the one place the
daemon reads a file for sound. `WAVReader` takes the mono 16-bit PCM `PartWriter` writes and
nothing else -- it walks the chunks rather than assuming the canonical layout, and a `data` chunk
whose length is still the placeholder is read to the end of the file, the same rule the restart
repair follows. A task reads 20 ms blocks, converts S16 to f32 and pushes them into the same
`CoreAudioSink` a channel's audio goes to, pacing against the start so jitter never accumulates;
the sink's ring is the buffer, so a late tick is absorbed without an audible gap. There is no DSP
thread in this path at all. `SessionStore` owns the table, publishes `Event.playback` and reaps a
departing client's playbacks beside its channels, which is what makes Ctrl-C in `ley play` stop
the sound. An IQ part is refused `INVALID_ARGUMENT` (those are tuned), and a host with no
AVFoundation returns `PLATFORM_UNSUPPORTED` exactly as `AttachSink(system_audio)` does.

`Resources` is implemented over these manifests plus the kept-decode store: `ListResources` answers
`RECORDING` and `RECORDS` from disk and `SCAN` from the jobs the daemon still remembers,
`GetResource` the same shapes by URI, and `ResolveLocalPath` the recording's directory
(`ley://recordings/<id>`) or one part's samples file (`ley://recordings/<id>/<part>`). Nothing is
streamed: a client on this machine opens the file (invariant 3).

### Detections on the telemetry plane

A scan's carrier detections (`SpectrumDetect.detect` in `DSP/EnergyDetector.swift`, driven off the
FFT ladder rows the sweep already collects) and a channel's CTCSS measurements (`SubAudibleDetector`
in `DSP/SubAudible.swift`, run over the demod chain's sub-audible tap) both reach clients as
telemetry, not as job results: `JobStore` fans live `Detection` messages out to subscribers
(drop-oldest, 64 deep, optionally filtered to one capture) the moment each is found, and
`TelemetryService` merges that stream into `Subscribe` alongside `SubAudible` and the rest. The
aggregate a finished scan returns from `Jobs.GetScan` is the same detections folded into one summary,
not a second source of truth.

### Persistence stream

`Bulk.Subscribe(persistence)` is the phosphor view: a per-bin amplitude histogram
(`DSP/Persistence.swift`'s `PersistenceAccumulator`) that decays by half over a caller-chosen
half-life instead of showing one row. The caller states the scale — `floor_db` and `range_db` (a
first FFT row supplies both; `range_db` must be positive or the daemon refuses the request rather
than guess one) — because a persistence frame on the wrong scale does not look obviously wrong.
`levels` clamps to 2...256 (default 32); `bins` rounds the way FFT bins do (default 256); accumulation
always runs at the ladder's fastest rate regardless of the requested `rows_per_second`, because the
histogram wants every row and a viewer only needs a couple of redraws a second. The daemon echoes the
resolved values in `PersistenceParams` on the stream descriptor.

### Daemon lifecycle

- Socket: `~/Library/Application Support/Leyline/leyline.sock` on macOS; `$XDG_RUNTIME_DIR/leyline.sock`
  or `/tmp/leyline-<uid>.sock` elsewhere. `--socket` overrides. A stale socket file (no listener) is
  removed at startup; a live one aborts with a clear error.
- Pidfile next to the socket (`leylined.pid` by default; `ley daemon start` passes `--pidfile` named
  after the socket, `leyline.pid` / `/tmp/leyline-<uid>.pid`, so two sockets in one directory never
  share it). `SIGTERM`/`SIGINT` → graceful stop (captures stopped, devices closed, socket unlinked).
- Stop order: the listener stops accepting first, because an RPC admitted during teardown builds
  state the store that owns it is about to drop; then jobs are cancelled (a running sweep gets its
  seconds to hand a capture lease back), streams close, the store shuts down and the registry stops.
  The socket and pidfile are unlinked last, after the devices are closed — while those paths exist a
  replacement daemon takes itself for the live one and races this one for the radios. Teardown runs
  in the process's own task, never in a child that the serve loop's return could cancel.
- Logs to stderr via swift-log; launchd redirects to `~/Library/Logs/Leyline/leylined.log`.
- `ley daemon install` writes `~/Library/LaunchAgents/com.leyline.daemon.plist` (KeepAlive, RunAtLoad)
  pointing at the `leylined` binary and bootstraps it; `start/stop/status/logs` drive launchctl when
  installed and fall back to spawning/killing the binary directly (pidfile) when not.

## Platform posture

The product is Mac-only and uses vDSP, AVFoundation, os_signpost directly (AGENTS.md). Files that
import those frameworks are wrapped in `#if canImport(Accelerate)` / `#if canImport(AVFoundation)` /
`#if canImport(os)` with a portable branch that exists only so the non-DSP core compiles and the
control plane can be exercised on Linux CI and in the moat container. `DSP/Kernels.swift` is the one
place with two implementations of the same primitives; the Accelerate one is the product, the
portable one is the reference the macOS parity tests compare against (`KernelParityTests`). The
demodulators and ladder call kernels only — no `vDSP_*` outside `Kernels.swift` and `FFT.swift`.
