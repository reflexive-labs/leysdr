# Engine review fixes (v0-bootstrap)

Source: the engine-focused code review of branch `v0-bootstrap` at `7df91ae6` (report archived in the review run
directory; findings keep their review numbers `#N` below). Scope: every P1-P3 primary finding. Each work item
lands as one commit with its own tests. Go/CLI changes are limited to what a proto change forces.

Status legend: `[ ]` pending, `[x]` done (commit noted), `[-]` dropped with reason.

## Decisions taken for the two decision gates

- **#26 IQ negotiation.** v0 serves raw IQ as `CF32` at the capture's native rate only. `Bulk.Subscribe(IQ)`
  now validates the request instead of silently overriding it: `format` must be `UNSPECIFIED` or `CF32` and
  `sample_rate` must be `0` or the capture rate; anything else is rejected with `INVALID_ARGUMENT`
  (message names the accepted values). Downsampled or integer IQ formats stay a documented v1 addition.
  Rationale: "downgrade, never upgrade" is honoured by refusing, and no client asks for cs8/cs16 yet.
- **#30 `SystemAudioSink.volume`.** The field becomes `optional double volume` (proto3 presence, same field
  number, wire-compatible). Absent means 1.0; an explicit `0` means muted. Engine, Go fake daemon and the
  Go client are updated together; the sentinel disappears instead of being documented.

## Work items (dependency order)

### WI-1 `[x]` Capture lifecycle unwinding (#4 P1, #2 P2)

- `DefaultCaptureEngine.start()` (DefaultCaptureEngine.swift:46-55): wrap everything after `device.open()`
  in do/catch. On failure: `core.stopThread()` if it was started, `await device.close()`, reset
  `streaming`/`started`, rethrow. Idempotency guard stays.
- `SessionStore.createCapture` (SessionStore.swift:372): `do { try await engine.start() } catch { await engine.stop(); throw error }`
  (engine.stop() must be safe on a half-started engine).
- `DefaultCaptureEngine.setSampleRate()` (:102-115): if `device.setSampleRate` throws after `stopStreaming`,
  try to restart the stream (`try? await beginStreaming()`); if that also fails set `detached = true` so
  the reported state is truthful; rethrow the original error. Same for a failing `beginStreaming` at the end.
- Tests (EngineCoreTests/CaptureTests.swift): a `FailingDevice` (RadioDevice) whose `startStreaming` /
  `setSampleRate` throw on demand. Assert: after a failed `start()`, `core` is not running
  (`engine.isDSPThreadRunning` or equivalent test hook), the device saw `close()`, and a second `start()`
  succeeds once the fault is cleared. After a failed `setSampleRate`, streaming is either restored (device
  saw `startStreaming` again) or `snapshot.detached == true`.
- Daemon test (LeylineDaemonTests/DaemonTests.swift): CreateCapture on a virtual device whose
  `startStreaming` throws returns `DEVICE_IO`, the device is `AVAILABLE` again in GetState, and a retry
  succeeds after the fault clears.

### WI-2 `[x]` Device loss / rebind test coverage (#13 P2)

- LeylineDaemonTests: attach a virtual test device (`registry.attachVirtualDevice`), create a capture,
  drive the device to `.disconnected` through its state-change hook, assert the Capture event shows
  `CAPTURE_DETACHED`; re-attach (arrival with the same identity key), assert `deviceRebound` restores
  streaming (CAPTURE_ACTIVE, samples flow again).
- EngineCoreTests: call `DefaultCaptureEngine.deviceLost()` and `deviceRebound(_:)` directly with a
  test device; assert `snapshot.detached`, `started`, and that the DSP thread is reused (not respawned).
- No production changes expected; if a small test hook is needed it must be additive.

### WI-3 `[ ]` Sample timebase across stream restarts (#3 P1)

- `CaptureDSPCore`: keep an `indexBase: UInt64`; `expectNewAnchor()` records that the next delivered
  block starts a new device epoch; on that block set `indexBase = lastDeliveredEnd &- deviceIndex` so
  committed `SampleTime.sampleIndex` continues monotonically (`deviceIndex &+ indexBase`). Publish the
  anchor from the rebased index. The doc comment at DefaultCaptureEngine.swift:99 becomes true.
- `DefaultSpectrumLadder`: on a new anchor (or whenever `now < nextDue - interval`) clamp
  `nextDue = min(nextDue, now &+ interval)` so a rewound or jumped timeline cannot stall rows.
- `DefaultCaptureEngine.setSampleRate()`: after `stopStreaming()` drain or discard the ring backlog
  (`core.discardPending()` or wait until `ring.available == 0`) before installing the new plan.
- Leave `RTLTCPDevice`'s per-generation `index = 0` alone (RTLTCPTests.swift:279 stays valid).
- Tests: EngineCoreTests: a device that restarts its index at 0 on every `startStreaming`; after
  `setSampleRate` and after `deviceRebound`, the delivered SampleTime is strictly increasing and a live
  spectrum subscription keeps producing rows. DaemonTests: capture_sample_rate write while an FFT bulk
  stream is open; assert rows keep arriving after the write.
- docs/engine-internals.md: one paragraph on the capture-owned index base.

### WI-4 `[ ]` Malformed-input hardening (#14, #11, #10, #24, all P2)

- #14 SessionStore.swift:487 `fits()`: use `offsetHz.magnitude` (or `Channelizer.checkOffset`). Also
  guard NaN/inf in the `.db` gain write (SessionStore.swift:618): `guard db.isFinite else { throw invalidArgument }`.
- #11 SpectrumLadder.swift: `roundRate` clamps to `[0.1, maxRowsPerSecond]`; the interval computation
  saturates (`min(x, Double(UInt64.max / 2))`) before converting.
- #10 IQSidecar.load / FilePlaybackDevice.init: reject `sample_rate` outside `1_000...100_000_000` with
  `INVALID_ARGUMENT`; `ChannelPlan.plan` throws when `captureRate` exceeds a documented
  `maxCaptureRate` (100 MSPS).
- #24 IQFileReader.init: `stat` samples and sidecar paths, require regular files (`S_IFREG`) else
  `INVALID_ARGUMENT`; cap sidecar size at 1 MiB before `Data(contentsOf:)`; open the samples file with
  `O_NONBLOCK` then clear the flag.
- Tests (DaemonTests + EngineCoreTests): offset_hz = Int64.min -> INVALID_ARGUMENT/OFFSET_OUT_OF_CAPTURE
  without a crash; rows_per_second = 1e-300 -> subscription succeeds at the clamped rate and rows arrive;
  NaN gain -> INVALID_ARGUMENT; sidecar with sample_rate 0 and 1e15 -> INVALID_ARGUMENT; AttachFileDevice
  on a FIFO (mkfifo) and on a directory -> INVALID_ARGUMENT within 2 s (no hang).

### WI-5 `[ ]` Channel state across retune and rate change (#21, #28, both P2)

- #21 DefaultChannelEngine: `absoluteHz` is the source of truth. `captureMoved` updates
  `currentConfig.offsetHz` even when the channel no longer fits. `update()` with a nil slot and a
  non-structural change stores squelch/agc into `currentConfig` and stays `.outOfCapture`. Only a changed
  `offsetHz` moves `absoluteHz`; other structural rebuilds use `offsetHz: absoluteHz - Int64(centerHz)`.
- #28 SessionStore `.centerHz` write branch: snapshot audio rates before the retune and call
  `audioRateChanged(chanID, by:)` for every channel whose `audioRate` differs afterwards (share a
  `reconcileAudioRates(captureID:by:)` helper with the `.captureSampleRate` branch).
- Tests: ChannelTests: retune pushes a channel out of capture; a squelch write keeps it `.outOfCapture`
  with the original absolute frequency; retune back -> `.active` at the original frequency. DaemonTests:
  rate change -> OUT_OF_CAPTURE -> retune back; assert the channel's reported audio rate and the bulk
  audio descriptor follow the new rate (and an attached CallbackSink is rebuilt).

### WI-6 `[ ]` DetachFileDevice validates before mutating (#18 P2)

- `DefaultDeviceRegistry.isDetachableFileDevice(id:) -> Bool` (non-mutating: entry exists, `rtlIndex == nil`,
  driver is `file`). `SessionStore.detachFileDevice` throws `INVALID_ARGUMENT` (hardware / rtl_tcp ids) or
  `DEVICE_NOT_FOUND` before touching any capture. Decision: operator-configured rtl_tcp devices are not
  client-detachable.
- Tests (DaemonTests): DetachFileDevice with a virtual non-file device id and with an unknown id is
  rejected and an existing capture on that device survives (still CAPTURE_ACTIVE in GetState).

### WI-7 `[ ]` rtl_tcp link-loss recovery (#9 P2)

- `RTLTCPDevice.readLoop`: on link loss close the socket, clear `fd`/`thread` (join is already done by
  the exiting thread), then transition to `.disconnected`, so a later `open()` reconnects.
- `DefaultDeviceRegistry.poll()`: for hosted rtl_tcp entries in `.disconnected`, attempt `open()` (bounded
  by the existing 5 s connect timeout, off the actor via the WI-9 helper or a detached Task); on success
  mark `.available` and publish `.arrived` (same id) so `SessionStore` rebinds captures through the existing
  path. Back off to once per poll interval.
- Tests (RTLTCPTests with `FakeRTLTCPServer`): server closes the connection -> device `.disconnected`,
  `fd` cleared; restart the fake server on the same port -> `open()` succeeds and streams again. Registry
  test: disconnected rtl_tcp entry becomes `.available` after a poll with the server back.
- docs/dev-setup.md + engine-internals.md: rtl_tcp reconnects on the next poll after the server returns.

### WI-8 `[ ]` Telemetry ring is latest-wins with visible gaps (#20 P2)

- `ChannelTelemetryQueue`: per-slot seqlock versions (`Atomic<UInt64>` array, preallocated). Producer on
  full: CAS `head` forward (evict oldest) and count it dropped, then write the slot under an odd/even
  version. Consumer: read version, copy slot, re-check version, CAS `head`; retry on mismatch. Still
  allocation-free and lock-free on the DSP thread.
- `TelemetryService`: the per-channel drain reports the dropped delta since its previous record; the
  merged stream advances `seq` by `dropped + 1` so subscribers see a gap for every evicted record.
- Tests: ChannelTests: push `capacity + 10` records, pop all -> the last pushed record is present, the
  oldest were evicted, `dropped == 10`. DaemonTests (or a service-level test): a slow subscriber observes a
  `seq` gap after the queue overflowed.
- docs/engine-internals.md + design-data-planes.md: telemetry queue policy is drop-oldest with seq gaps.

### WI-9 `[ ]` Device open off the cooperative pool (#5 P3, plus the adjacent #16 one-liner)

- `EngineCore/BlockingWork.swift`: `static func run<T>(_ body: @escaping () throws -> T) async throws -> T`
  that runs `body` on a fresh `Thread` and resumes a `CheckedContinuation`.
- `RTLSDRDevice.open()`: run the rtlsdr_open/retry/config sequence through `BlockingWork.run`; wrap the
  three reapplied config calls in `try check(...)` (#16) so a reopen failure surfaces as `DEVICE_IO`.
- Tests: a unit test for `BlockingWork.run` (value, thrown error, runs off the caller's thread). Existing
  device tests stay green; the stub librtlsdr path still throws `DEVICE_IO` from `open()`.

### WI-10 `[ ]` Bulk IQ contract and coverage (#26 P2, #25 P2)

- `StreamRegistry.subscribe` `.iq` case: validate `req.iq.format` and `req.iq.sampleRate` per the decision
  above; reject with `INVALID_ARGUMENT`. Answer `cf32` at the capture rate as today.
- proto/leyline/v1/bulk.proto: document the v0 IQ contract on `IqParams` (comment only) and regenerate with
  `scripts/gen-proto.sh`. docs/design-data-planes.md: same note next to the IQ stream description.
- Tests (DaemonTests `checkIQ`): subscribe kind=IQ with default params -> descriptor is cf32 at the capture
  rate; stream frames and assert `payload.count == frames * 8` bytes per cf32 sample block; unsubscribe;
  a second unsubscribe/stream returns `STREAM_NOT_FOUND`. Requests with `CS16` or a foreign sample rate
  return `INVALID_ARGUMENT`.

### WI-11 `[ ]` `SystemAudioSink.volume` presence (#30 P3)

- proto/leyline/v1/control.proto: `optional double volume = 2;` (comment: absent = 1.0, 0 = muted).
  Regenerate Go + Swift.
- Engine `SessionStore.attachSink`: `let volume = sa.hasVolume ? sa.volume : 1.0`; keep the 0...1 range check.
- Go: fakedaemon `AttachSink` mirrors it; `go/internal/cli/session.go:534` sets `Volume: proto.Float64(o.volume)`
  (and any other constructor). `go test ./...` green.
- Tests: DaemonTests attach with no volume -> 1.0 in the Sink event; explicit 0 -> 0; 1.5 -> INVALID_ARGUMENT.
  Go fakedaemon test for the same.

## Closing

- Run the full gate: `go build ./... && go test ./...`, `swift build && swift test`, and the e2e suite with
  scratch-built binaries (never `make go` in the container: `go/bin` holds the user's macOS binaries).
- Update this file's status boxes and commit it.
