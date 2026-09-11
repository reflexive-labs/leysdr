# Engine internals

Status: v0 implementation contract. Companion to `design-control-plane.md` and `design-data-planes.md`;
the wire contract is `proto/leyline/v1`, the engine contract is `engine/Sources/EngineCore/CoreProtocols.swift`.
CLAUDE.md invariants apply throughout; this doc says *how* the engine keeps them.

## Module map

```
engine/                       SwiftPM package (macOS 26+, Swift 6 toolchain, Swift 5 language mode)
├── Sources/LeylineProto      generated leyline.v1 messages + grpc-swift 2 stubs — never hand-edit (`make proto`)
├── Sources/CRTLSDR           system-library shim over librtlsdr (brew install librtlsdr)
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
│   ├── Jobs/                 JobStore (durable job table), ScanRunner (sweep execution), SessionCaptureAllocator
│   │                         (don't-disturb capture leasing for jobs)
│   ├── Services/             Control, Telemetry, Bulk, Jobs (scan implemented; watch/record UNIMPLEMENTED),
│   │                         Resources (UNIMPLEMENTED in v0)
│   ├── Bulk/                 stream registry: FFT/audio/IQ subscriptions -> rings -> gRPC frames
│   ├── WriteCoalescer.swift  ParamWrite coalescing
│   ├── RememberedDevices.swift  devices.json beside the socket: the rtl_tcp endpoints to re-attach
│   └── Mapping/              engine <-> proto conversions
├── Tests/EngineCoreTests     unit tests; fixture round-trips. Most of the target builds and runs on Linux;
│                             `KernelParityTests` and anything under `#if canImport(Accelerate)` or
│                             `#if canImport(AVFoundation)` need macOS and do not compile elsewhere.
└── Tests/TestSupport         fakes both test targets drive (the rtl_tcp server); no product depends on it
```

Go clients live in `go/` (`docs/interfaces.md` for the verb tree). `go/internal/fakedaemon` is an in-memory
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

Blocks are 16384 complex samples. `RTLSDRDevice` asks librtlsdr for `buf_len = 32768` bytes
(`buf_num = 32`), so one USB callback is exactly one slot. The block ring holds 64 slots of cf32
(8 MiB per capture, ~0.44 s at 2.4 MSPS). `FilePlaybackDevice` delivers the same block size.

## Capture pipeline

```
device (cu8/cf32) ──deliver──▶ convert to cf32 ──▶ BlockRing ──▶ DSP thread
                                                                   ├─▶ Channel[n]: NCO mix ▶ FIR↓D1 ▶ FIR↓D2 ▶ demod ▶ squelch ▶ sinks
                                                                   ├─▶ SpectrumLadder: window ▶ FFT(N) ▶ |X|² dB ▶ subscribers (rate-limited)
                                                                   └─▶ CaptureTaps: cf32 blocks (IQ recording / IQ bulk stream)
```

### Conversion

`.cu8 → .cf32`: `(u − 127.5) / 127.5`, done in one vDSP pass (`vDSP_vfltu8` with stride, then
`vDSP_vsmsa`). Portable kernel does the same loop. `.cs16 → .cf32`: `/32768`.

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
channel's `ChannelDSPCore`: filter history, NCO phase, demodulator, the meter's noise floor and the
transmission in progress all go. The samples either side of the gap are not continuous, so filtering
the first blocks against pre-gap history, judging them against a floor measured on the old stream,
or reporting an open duration that spans the dead air would all describe air that was never heard.
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
  scaled so ±5 kHz deviation ≈ ±1.0 (full scale); a 300 Hz two-pole high-pass pushes CTCSS/PL tones under the voice (about 20 dB at 100 Hz, of which the make-up gain below returns some 6 dB), then 6 dB/octave de-emphasis above 300 Hz (τ ≈ 530 µs, matching transmitter pre-emphasis) with ×2 make-up gain, then a 1-pole LPF ≈ 4 kHz; output hard-limited
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
and CW; nothing for raw IQ. Both FM stages are scaled so full-scale deviation reads ±1.0 — 5 kHz
for NFM, 75 kHz for WFM — which makes the block's mean the tuning error in hertz. The callee sets
`rawOut.count`, because WFM decimates the tap through a filter of its own and answers for its own
alignment; every buffer either needs is sized in `configure`, so a block nobody is tapping costs a
nil check.

`AudioSink` carries an `AudioTap`, and `ChannelDSPCore` keeps its sink table split by it: the
conditioned block goes to `.audio` sinks, the raw block to `.demod` sinks, and the demodulator is
handed a raw buffer only while the second list is non-empty. The squelch's zeroing is part of what
a listener hears, so it applies to `.audio` sinks alone; the demod tap keeps flowing through a
closed squelch, which is what makes "what is this transmitter sending between words" answerable.
Meter, squelch and telemetry read the conditioned block. A raw-IQ channel has no
detector, so attaching a `.demod` sink to one is `INVALID_ARGUMENT`, and so is a `TAP_DEMOD`
subscription over the bulk plane.

### Squelch and meters

Per block the channel computes mean power of the post-filter IQ in dBFS (`10·log10(mean|x|²)`).
Squelch opens when power > threshold, closes when power < threshold − 2 dB (hysteresis). While
closed the channel writes zeros to sinks so audio timing stays continuous. Meter cadence: every
100 ms of samples, emit `.meter`; on state change emit `.squelch` with the exact block start time.
SNR estimate: power − running minimum of block power (5 s window). Reported as NaN until 1 s of data.

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

### FilePlaybackDevice

Reads the IQ file format in `docs/fixtures.md` (`<name>.cf32` + `<name>.json`). Descriptor: driver
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
virtual device by driver and address alone — an endpoint hosted before it answers cannot name its
tuner, and the model it would carry must not make it a second radio. A server that cannot be reached
at startup is hosted `DISCONNECTED` for the reconnect poll to pick up, never fatal.

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
  returns `UNIMPLEMENTED` for attaching a stream sink directly); `file` → `UNIMPLEMENTED` in v0.
- `WriteParams`: `WriteCoalescer` keeps last value per `(target_id, param case)` and applies every
  20 ms. Rejections become `WriteRejected` events with the client tag. `gain` writes target the
  capture's device; the confirmed value comes back in the `Capture.gains` field of the capture event.
  On a channel that is `OUT_OF_CAPTURE` every non-offset write (`bandwidth_hz`, `mode`, `squelch_db`)
  is stored and used by the rebuild when the capture moves back over the channel — the channel stays
  `OUT_OF_CAPTURE` at its absolute frequency; only an `offset_hz` write is checked against the capture
  right away.
- `AttachDevice`: a `file` source is the `AttachFileDevice` path (ephemeral); an `rtl_tcp` source
  opens an `RTLTCPDevice` with the 5 s connect timeout and hosts it. `AttachFileDevice` and
  `DetachFileDevice` stay as sugar; `DetachFileDevice` names a file and gets one, so any other device
  is `DEVICE_NOT_FOUND` there.
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
`DEVICE_IO` naming the endpoint with nothing remembered — a radio never reached is usually a typo.
Detach and attach can overlap, so the order is fixed: detach drops the device from the session table
before it forgets the endpoint, and both attach paths re-check the table after their awaits and take
the line back out if it has gone. Whichever runs last, a radio somebody let go stays gone.

The registry records how each hosted virtual device arrived. A radio named by `--rtltcp` is operator
configuration: `DetachDevice` refuses it with `INVALID_ARGUMENT` naming the flag, because a detach
the daemon's own command line would undo at the next start is not a detach. Attaching that endpoint
over the protocol makes it the client's — the descriptor comes back unchanged, the endpoint is
remembered, and from then on it persists and detaches like any other.

An endpoint that is unreachable at startup, remembered or flagged, is hosted anyway as a
`DISCONNECTED` device, so the registry's reconnect poll — which only retries devices it holds —
brings it in the moment it answers; the log line says the daemon is waiting for it. One dead remote
never keeps the daemon from serving local dongles. An unreadable `devices.json` is an empty list: a
daemon that will not serve local dongles because it cannot parse a list of remote ones is worse than
one that forgets a Pi.

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
| `JOB_NOT_FOUND` | `NOT_FOUND` | no job with that id |
| `SCAN_NOT_FOUND` | `NOT_FOUND` | no scan result with that id (sixteen are kept) |
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

### Bulk service

`Subscribe` answers with an authoritative `StreamDescriptor`. v0 rules: transport is always
`grpc` (SHM_RING requests are downgraded — the ring is a later milestone); `start` must be `live`
(`UNIMPLEMENTED` otherwise); policy defaults to `LATEST_WINS`, `GAP_MARKED` honoured by emitting `Gap`.
FFT: bins/rate via the ladder; bin format `DB_F32` (little-endian f32) or `DB_U8`
(`clamp(round((db + 120) · 2), 0, 255)`). Audio: channel `audioRate`, `S16` or `F32` mono; a
requested `sample_rate` that is neither 0 nor the channel's rate is `INVALID_ARGUMENT` (no
resampling in v0, and the daemon never upgrades). A capture-rate write that re-plans a channel at a
new audio rate rebuilds its system-audio sinks under their existing ids and ends its bulk audio
streams (re-subscribe for a fresh descriptor). IQ: capture rate only, `CF32` only (no resampling in v0). `Stream` writes frames until the client
cancels; `Unsubscribe` tears the subscription down; a subscription with no `Stream` reader for 10 s
is reaped.

### Jobs service and lease lifecycle

`StartJob(ScanConfig{once})` is implemented (Milestone D.13); `watch` and `record` configs, and the
whole Resources service, still return `UNIMPLEMENTED`. A scan job never touches a capture directly
(invariant 9): it asks `SessionCaptureAllocator` for a range, and the allocator either hands back a
`CaptureLease` or a declined result with a reason. Allocation prefers a device with no capture at all
over borrowing one that has one — creating and destroying disturbs nobody. Borrowing an existing
capture is refused by the don't-disturb check (`inUse`: an owning channel, a live audio sink, or an
interactive write in the last 60 s) unless the caller passed `take_over`; a leased capture is marked
*swept* in `SessionStore`, and `refuseIfSwept` rejects interactive `WriteParams`/`CreateChannel` calls
on it for as long as the lease holds. `SweepPlan.edgeFraction` widens a device's tuning range slightly
when deciding whether it can hear a request, which is how a `FilePlaybackDevice` — whose "range" is
the single frequency its fixture was recorded at — can still serve a sweep. Releasing a lease that
created its capture destroys it; releasing one that borrowed an existing capture retunes and re-gains
it back to what it found and clears swept.

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

The product is Mac-only and uses vDSP, AVFoundation, os_signpost directly (CLAUDE.md). Files that
import those frameworks are wrapped in `#if canImport(Accelerate)` / `#if canImport(AVFoundation)` /
`#if canImport(os)` with a portable branch that exists only so the non-DSP core compiles and the
control plane can be exercised on Linux CI and in the moat container. `DSP/Kernels.swift` is the one
place with two implementations of the same primitives; the Accelerate one is the product, the
portable one is the reference the macOS parity tests compare against (`KernelParityTests`). The
demodulators and ladder call kernels only — no `vDSP_*` outside `Kernels.swift` and `FFT.swift`.
