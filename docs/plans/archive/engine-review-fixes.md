# Engine review fixes (v0-bootstrap)

Source: the engine-focused code review of branch `v0-bootstrap` at `9417fb96`. The review's report lived in an
ephemeral run directory that no longer exists; findings below keep their review numbers `#N` only because the
commit messages that closed them cite those numbers. Scope: every P1-P3 primary finding. Each work item
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

### WI-3 `[x]` Sample timebase across stream restarts (#3 P1)

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
- docs/dev/engine-internals.md: one paragraph on the capture-owned index base.

### WI-4 `[x]` Malformed-input hardening (#14, #11, #10, #24, all P2)

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

### WI-5 `[x]` Channel state across retune and rate change (#21, #28, both P2)

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

### WI-6 `[x]` DetachFileDevice validates before mutating (#18 P2)

- `DefaultDeviceRegistry.isDetachableFileDevice(id:) -> Bool` (non-mutating: entry exists, `rtlIndex == nil`,
  driver is `file`). `SessionStore.detachFileDevice` throws `INVALID_ARGUMENT` (hardware / rtl_tcp ids) or
  `DEVICE_NOT_FOUND` before touching any capture. Decision: operator-configured rtl_tcp devices are not
  client-detachable.
- Tests (DaemonTests): DetachFileDevice with a virtual non-file device id and with an unknown id is
  rejected and an existing capture on that device survives (still CAPTURE_ACTIVE in GetState).

### WI-7 `[x]` rtl_tcp link-loss recovery (#9 P2)

- `RTLTCPDevice.readLoop`: on link loss close the socket, clear `fd`/`thread` (join is already done by
  the exiting thread), then transition to `.disconnected`, so a later `open()` reconnects.
- `DefaultDeviceRegistry.poll()`: for hosted rtl_tcp entries in `.disconnected`, attempt `open()` (bounded
  by the existing 5 s connect timeout, off the actor via the WI-9 helper or a detached Task); on success
  mark `.available` and publish `.arrived` (same id) so `SessionStore` rebinds captures through the existing
  path. Back off to once per poll interval.
- Tests (RTLTCPTests with `FakeRTLTCPServer`): server closes the connection -> device `.disconnected`,
  `fd` cleared; restart the fake server on the same port -> `open()` succeeds and streams again. Registry
  test: disconnected rtl_tcp entry becomes `.available` after a poll with the server back.
- docs/dev/setup.md + docs/dev/engine-internals.md: rtl_tcp reconnects on the next poll after the server returns.

### WI-8 `[x]` Telemetry ring is latest-wins with visible gaps (#20 P2)

- `ChannelTelemetryQueue`: per-slot seqlock versions (`Atomic<UInt64>` array, preallocated). Producer on
  full: CAS `head` forward (evict oldest) and count it dropped, then write the slot under an odd/even
  version. Consumer: read version, copy slot, re-check version, CAS `head`; retry on mismatch. Still
  allocation-free and lock-free on the DSP thread.
- `TelemetryService`: the per-channel drain reports the dropped delta since its previous record; the
  merged stream advances `seq` by `dropped + 1` so subscribers see a gap for every evicted record.
- Tests: ChannelTests: push `capacity + 10` records, pop all -> the last pushed record is present, the
  oldest were evicted, `dropped == 10`. DaemonTests (or a service-level test): a slow subscriber observes a
  `seq` gap after the queue overflowed.
- docs/dev/engine-internals.md + docs/design/data-planes.md: telemetry queue policy is drop-oldest with seq gaps.

### WI-9 `[x]` Device open off the cooperative pool (#5 P3, plus the adjacent #16 one-liner)

- `EngineCore/BlockingWork.swift`: `static func run<T>(_ body: @escaping () throws -> T) async throws -> T`
  that runs `body` on a fresh `Thread` and resumes a `CheckedContinuation`.
- `RTLSDRDevice.open()`: run the rtlsdr_open/retry/config sequence through `BlockingWork.run`; wrap the
  three reapplied config calls in `try check(...)` (#16) so a reopen failure surfaces as `DEVICE_IO`.
- Tests: a unit test for `BlockingWork.run` (value, thrown error, runs off the caller's thread). Existing
  device tests stay green; the stub librtlsdr path still throws `DEVICE_IO` from `open()`.

### WI-10 `[x]` Bulk IQ contract and coverage (#26 P2, #25 P2)

- `StreamRegistry.subscribe` `.iq` case: validate `req.iq.format` and `req.iq.sampleRate` per the decision
  above; reject with `INVALID_ARGUMENT`. Answer `cf32` at the capture rate as today.
- proto/leyline/v1/bulk.proto: document the v0 IQ contract on `IqParams` (comment only) and regenerate with
  `scripts/gen-proto.sh`. docs/design/data-planes.md: same note next to the IQ stream description.
- Tests (DaemonTests `checkIQ`): subscribe kind=IQ with default params -> descriptor is cf32 at the capture
  rate; stream frames and assert `payload.count == frames * 8` bytes per cf32 sample block; unsubscribe;
  a second unsubscribe/stream returns `STREAM_NOT_FOUND`. Requests with `CS16` or a foreign sample rate
  return `INVALID_ARGUMENT`.

### WI-11 `[x]` `SystemAudioSink.volume` presence (#30 P3)

- proto/leyline/v1/control.proto: `optional double volume = 2;` (comment: absent = 1.0, 0 = muted).
  Regenerate Go + Swift.
- Engine `SessionStore.attachSink`: `let volume = sa.hasVolume ? sa.volume : 1.0`; keep the 0...1 range check.
- Go: fakedaemon `AttachSink` mirrors it; `go/internal/cli/session.go:534` sets `Volume: proto.Float64(o.volume)`
  (and any other constructor). `go test ./...` green.
- Tests: DaemonTests attach with no volume -> 1.0 in the Sink event; explicit 0 -> 0; 1.5 -> INVALID_ARGUMENT.
  Go fakedaemon test for the same.

## Closing

Done on 2026-09-06, commits cbe4bf3..3685c36 (one per work item, each verified by an independent reviewer
before landing). Gate at 3685c36:

- Swift: `swift build` clean; `swift test` 121 tests, 0 failures (79 before this plan).
- Go: `go build ./... && go vet ./... && go test ./...` green; `gofumpt` clean; `golangci-lint` unchanged at
  42 pre-existing findings (errcheck/staticcheck in the CLI, none introduced here).
- Generated code: `scripts/gen-proto.sh` produces no drift.
- e2e (`go/internal/e2e`, real `leylined` + Linux `ley` built into a scratch dir): 2/2 pass.

## Follow-ups noted while implementing (not in the review's primary set)

- `SessionStore` rethrows a failed `capture_sample_rate` write without emitting the capture event, so a
  `detached=true` (or a rate that did take effect on the retry) is visible only on the next event/GetState.
  Emit the capture (and channels) on that error path.
- Structural writes (mode/bandwidth) on an OUT_OF_CAPTURE channel are still rejected with
  `OFFSET_OUT_OF_CAPTURE`; only squelch/AGC are stored for the eventual rebuild. Decide whether to store them.
- `Telemetry.Subscribe` needed `withRPCCancellationHandler` to end when a client cancels with no traffic;
  audit `WatchEvents` and `Bulk.Stream` for the same lingering-handler shape.
- Downstream telemetry buffers (`TelemetryHub` per-subscriber `bufferingNewest(256)`, merged
  `bufferingNewest(64)`) still drop without seq gaps; only the DSP-side ring is gap-marked.
- The rtl_tcp reconnect runs `open()` on `Task.detached`; switch it to `BlockingWork.run` now that WI-9 exists.
  `reconnectFinished` could also require `.available` before publishing `.arrived`.
- The Go fake daemon still answers cf32 for any IQ request; mirror the daemon's `INVALID_ARGUMENT` for parity.
- The reopen-config error branch in `RTLSDRDevice.open()` (#16) and the macOS branch of the volume-presence
  test only run with hardware / AVFoundation; cover them in the hardware-in-the-loop suite.
- The registry's probe gate is keyed by identity base, so with a serial-collision pair a held sibling
  can stay `held_externally` while the other sibling is ours or probed; a replug or one of our own
  captures clears it. Pre-existing hole in the degraded-probe refresh, now visible.
- `CaptureAnchor.hostTimeNsAtSampleZero` is recomputed at each rate change from the rebased index at the new
  rate (documented); a rate-invariant sample-zero time would need a per-epoch base.

## Follow-up work items (from the list above, plus the two CLI issues seen on the Mac)

Same loop as WI-1..WI-11: one commit each, verified independently, `make check` green on both hosts.

### FU-1 `[x]` A failed rate write re-emits capture and channel state (#2 follow-up)

- `SessionStore.applyWrite` `.captureSampleRate` branch: when `entry.engine.setSampleRate` throws, the
  engine may now be detached (failed restore) or may have applied the new rate on its retry. Before
  rethrowing: `touchActivity`, `await emitCapture(id, by: by)`, run the same audio-rate reconcile as the
  success path against the engine's actual `snapshot.sampleRate`, and emit every channel of the capture.
- Tests (LeylineDaemonTests): a VirtualDevice whose `setSampleRate` throws and whose `startStreaming`
  then fails once -> WriteParams `capture_sample_rate` gives a rejected write AND a Capture event with
  `CAPTURE_DETACHED` arrives on the watch stream without a GetState; a second variant where the retry
  succeeds asserts the capture event shows the unchanged rate and the channels are re-emitted.

### FU-2 `[x]` Structural writes on an OUT_OF_CAPTURE channel are stored, not rejected (#21 follow-up)

- `DefaultChannelEngine.update()`: with a nil slot (out of capture) a `mode` or `bandwidthHz` change is
  stored in `currentConfig` and the channel stays `.outOfCapture`; the eventual rebuild on re-entry uses
  the stored config. Only an `offsetHz` change recomputes `absoluteHz` (existing behaviour).
- `SessionStore` pre-checks: for a channel currently OUT_OF_CAPTURE, `bandwidth_hz` and `mode` writes skip
  the `fits(offset, bw, rate)` check (the offset is already outside); keep bandwidth-vs-mode validation
  that does not involve the offset. Offset writes keep the existing check.
- Tests: ChannelTests (out-of-capture channel accepts mode+bandwidth, stays out, retune back -> `.active`
  with the new mode/bandwidth) and a DaemonTests case over WriteParams asserting the Channel event shows
  the new bandwidth with state OUT_OF_CAPTURE, then ACTIVE after `center_hz` moves back.
- docs/dev/engine-internals.md: one sentence on the rule (all non-offset writes are stored while out of capture).

### FU-3 `[x]` WatchEvents and Bulk.Stream end on client cancel (#20 follow-up)

- Audit `ControlService.watchEvents` and `BulkService.stream` for the shape fixed in
  `Telemetry.Subscribe`: a `for await` over an AsyncStream that only wakes on traffic keeps the handler
  alive after the client cancels the RPC. Wrap the streaming section in `withRPCCancellationHandler` and
  finish/cancel the source (event stream subscription, frame drain task) in `onCancelRPC`; also end when
  the store's event stream finishes on shutdown.
- Tests (LeylineDaemonTests): open WatchEvents with no traffic, cancel the RPC task, assert
  `daemon.shutdown()` completes within 2 s; same for Bulk.Stream on an FFT subscription at
  `rows_per_second` 0.1 (no row arrives inside the test window).

### FU-4 `[x]` Hub and merge-buffer drops count toward telemetry seq gaps (#20 follow-up)

- `AsyncStream.Continuation.yield` returns `.dropped` when a `bufferingNewest` buffer overflows.
  `TelemetryHub` (DefaultChannelEngine.swift:188, per-subscriber 256) and the merged stream in
  `TelemetryService` (64) count those drops per subscriber (atomics, no allocation on the DSP thread)
  and the service adds the delta to the same `gap` it already derives from ring evictions, so every
  lost record is a visible seq hole regardless of which buffer lost it.
- Tests: a hub subscriber that does not read sees `dropped` grow past capacity; the existing
  `testTelemetrySeqGapsAfterQueueOverflow` gains a variant that stalls the gRPC reader instead of the
  ring and still observes a seq gap equal to the records lost.
- docs/dev/engine-internals.md: note that all three telemetry buffers are gap-marked.

### FU-5 `[x]` rtl_tcp connect runs off the cooperative pool; reconnect publishes only when available (#9 follow-up)

- `RTLTCPDevice.open()`: run `connect` + header read through `BlockingWork.run` (as `RTLSDRDevice.open`
  does) so neither the startup attach nor the registry's reconnect parks a cooperative-pool thread for
  the 5 s timeout. The registry's reconnect can then use a plain `Task` instead of `Task.detached`.
- `DefaultDeviceRegistry.reconnectFinished`: publish `.arrived` only when `device.descriptor.state ==
  .available`; otherwise leave the entry `.disconnected` for the next poll.
- Tests: existing RTLTCPTests stay green; add a registry-level test that a device whose link died
  between `open()` returning and `reconnectFinished` (simulate by transitioning the device to
  `.disconnected` before calling the internal hook) publishes nothing and stays disconnected.

### FU-6 `[x]` Go fake daemon enforces the v0 IQ contract (#26/#25 follow-up)

- `go/internal/fakedaemon/bulk.go` kind=IQ: accept `format` UNSPECIFIED/CF32 and `sample_rate` 0 or the
  capture rate; reject anything else with `INVALID_ARGUMENT` and the same message shape as the daemon
  (`StreamRegistry.subscribe`). Add a fakedaemon test for the accept and reject cases; `go test ./...` green.

### FU-7 `[x]` Probe gate keyed by USB index for serial-collision pairs (registry follow-up)

- `DefaultDeviceRegistry.advanceTickAndProbeGate`: the skip set is keyed by identity base, so with two
  dongles sharing a serial a held sibling stays skipped while the other is ours or probed. Decide per
  probe: find the entry whose `rtlIndex == probe.index` (same base); skip only on that entry's own state
  (ours, probed OK, held inside backoff); a probe with no matching entry (new device) may open.
- Tests (RegistryProbeTests): two probes with the same serial at index 0 and 1; index 0 marked in use by
  us, index 1 held (openError) -> after its backoff the gate opens for index 1 only; a successful probe
  for index 1 frees it while index 0 stays ours.

### FU-8 `[x]` `ley devices` shows unknown gain tables and external holds honestly (CLI)

- `go/internal/cli/format.go:59`: when a gain element's `valid_db` is empty and min == max == 0, render
  `TUNER unknown` (the daemon could not open the dongle to read its table) instead of `0..0dB`.
- STATE column (devices table and the devices block of `ley state`): `IN_USE (other program)` when
  `features.held_externally` is true; `--json` unchanged (proto3 JSON mapping).
- Tests: extend `TestDevicesTableAndJSON` (fake daemon can hand out a device with the flag and an empty
  gain table) and update any golden files the change touches.
