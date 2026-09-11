# Review fixes, v1.0 pass

Source: `docs/plans/v1-review-findings.md` (in-repo this time, so the ids below resolve). Scope: every
confirmed or adjudicated finding that is a code or comment change. Design findings that need a
milestone go to `docs/plans/v1-release.md` and are listed under "Deferred" here with the item that
carries them. One commit per work item, verified independently, both suites green after each.

Status legend: `[ ]` pending, `[x]` done, `[-]` dropped with reason.

## Decisions

- **gRPC status per stable code (a-layering-2).** One table, written into `docs/engine-internals.md`
  next to the `leyline-error-bin` paragraph, asserted by a test on each side: `DEVICE_BUSY` and
  `DEVICE_SWEEPING` → `FAILED_PRECONDITION` (`RESOURCE_EXHAUSTED` is retriable under default gRPC
  retry policies, and a busy radio must not be retried blind); `DEVICE_DETACHED` → `UNAVAILABLE`
  (the dongle may come back, so retriable is right); `GAIN_ELEMENT_UNKNOWN` → `INVALID_ARGUMENT`
  (the element name is the caller's argument); `MODE_UNSUPPORTED` → `UNIMPLEMENTED` (a capability
  gap, beside `PLATFORM_UNSUPPORTED`); everything else as both tables already agree.
- **`ley watch` is the watch job, not the dashboard (a-layering-8, a-layering-13).**
  `docs/design-semantic-tier.md` names `watch` as the CLI mirror of the D.15 watch job;
  `docs/interfaces.md` already says the dashboard replaces bare `ley` on a TTY. The `watch` stub's
  text and `ley help roadmap` change to "watch a frequency and log what is heard (Milestone D.15)";
  the dashboard is described under bare `ley`.
- **Auto squelch applies in every mode of `tune` (a-layering-10, PC-11).** `--persistent` and
  `--json` no longer skip the measurement; the decision line goes to stderr like every other
  decision. A script that wants squelch off says `--squelch off`.
- **Capture tombstone (a-invariants-3, a-layering-7).** `DestroyCapture` emits the capture one last
  time with `state` unset, the same convention as `Channel` and `Sink`; the convention is documented
  once, on `Capture.state` in `control.proto`, and referenced from the other two. The fake mirrors,
  the CLI mirror drops the capture.
- **`Job.error` (a-evolution-8).** Additive `ErrorDetail error = 10` on `Job`; `status_detail` stays
  prose. `Job.config` is the request as made; only `Scan.config` carries the daemon's plan
  (a-evolution-13).
- **Persistence accumulator lock (c-swift-core-5, q-swift-dsp-2).** `add` and `snapshot` run on the
  same DSP thread in the only caller, so there is no contention; the exemption is documented on the
  class rather than re-engineered.
- **Dropped as refuted or not worth an edit** — with the reason: a-invariants-2 (the swift-macos CI
  job already regenerates and diffs `LeylineProto`, ci.yml:82-88); q-go-lib-9 (grpc-go finishes the
  stream itself on a non-EOF `Send` error); q-swift-daemon-7 (`StringValues` is a `Sequence`, so
  `.first` does not exist); q-go-render-17 (`spectrum_test.go:156` pins the erase-line writes, so
  the model's limitation has no consequence); a-layering-9 (CI runs `make e2e` on every push; the
  residual is R-3 in the release plan); and the sixteen the verifiers refuted, listed in the record.

## Deferred to the release plan

- a-invariants-7, a-layering-6 (the client mirror and tune lifecycle belong in `go/pkg/leyline`):
  R-13. Both reviewers say "before D.14"; R-13 is sequenced before D.14 and D.16.
- a-invariants-5 (`JobRunner`, `JobContext`, `ResourceStore` unreferenced in `CoreProtocols.swift`):
  they are the D.15 contract; the comment says so (CB-4).
- a-invariants-8 (a `ley://scans/<id>` nothing can resolve): R-15's proto comment states the v0
  contract (resolved by `Jobs.GetScan`, gone after sixteen finished jobs); resolution proper arrives
  with Resources.
- a-invariants-9 (rtl_tcp devices are configuration, not client-detachable): deliberate and
  documented in the registry; only `devices.go:73`'s message is wrong (GO-3).
- a-invariants-4 (engine-internals predates Jobs): R-1, extended with the three sections the
  reviewer asks for (Jobs service and lease lifecycle, detections on telemetry, the persistence
  stream's parameters).
- a-evolution-14, a-evolution-15 (`sdr://` in design docs; the claim that protos reserve auth
  fields): R-1.
- q-go-render-4 (`waterfall`/`phosphor` ignore `--json`): R-5, done here as GO-8.

## Comment batches (Sonnet, in parallel, one commit each)

Each batch fixes every listed finding in its files and nothing else; a finding that turns out to be
wrong is left alone and reported. House style: say why, in the present tense, with no project
history — no plan ids, review numbers, dates, "used to", "no longer", "the fix".

### CB-1 `[x]` `go/internal/cli` sources

c-go-cli-a-2, c-go-cli-a-3, c-go-cli-b-1 … c-go-cli-b-9 (b-9 names the wrong constant: fix the
comment, the code is GO-2's). Files: `go/internal/cli/*.go` except `*_test.go`.

### CB-2 `[x]` `go/pkg`, `go/cmd`, `go/internal/{ui,fakedaemon}` sources

c-go-lib-1 … c-go-lib-6, c-go-lib-8, and q-go-lib-1 (the same misattached doc comment). Files: the
non-test `.go` files under those directories.

### CB-3 `[x]` Go tests

c-go-tests-1 … c-go-tests-22, c-go-tests-24 … c-go-tests-26. Files: every `*_test.go` under `go/`.
Test names stay; only comments and message strings change.

### CB-4 `[x]` `EngineCore` sources

c-swift-core-1, c-swift-core-2, c-swift-core-6, c-swift-core-7, c-swift-core-5 (write the
exemption: the accumulator's only caller adds and snapshots on the DSP thread, so the lock never
contends — say that on the class), q-swift-dsp-10 (`neighbourGap` returns the full gap), and
a-invariants-5 (say on `JobRunner`/`JobContext`/`ResourceStore` that they are the Milestone D.15
contract with no implementation yet). Files: `engine/Sources/EngineCore/**/*.swift`.

### CB-5 `[x]` `LeylineDaemon` sources

c-swift-daemon-6, and a-layering-5 (rewrite the `ProtoMapping.swift` header and the matching
sentence in `engine/Package.swift` to say what is true: `ProtoMapping` renders engine values to
proto; the session and job stores hold proto messages as their record type; `EngineCore` stays
proto-free). Files: `engine/Sources/LeylineDaemon/**/*.swift`, `engine/Package.swift`.

### CB-6 `[x]` Engine tests

c-swift-tests-1 … c-swift-tests-9 (c-swift-tests-9 and q-swift-dsp-8 are the same escaped
interpolations: fix the strings). Files: `engine/Tests/**/*.swift`.

### CB-7 `[x]` The documents (R-1 of the release plan)

`docs/plans/v1-release.md` section R-1, in full, including the three engine-internals sections
a-invariants-4 asks for and the two design-doc corrections (a-evolution-14, a-evolution-15). Files:
`docs/**`, `CLAUDE.md`, `engine/launchd/` (delete).

## Code work items — Go lane (Opus, sequential)

### GO-1 `[x]` `ley listen`: the race and the last row

q-go-verbs-1 (compute the note before the drain starts; add `go test -race ./internal/cli/` to
`make go-test` or a separate `make race` target run by CI), q-go-verbs-2 (flush on every return
path with the error checked).

### GO-2 `[x]` Rendering defects

q-go-render-1 (meter block that shrinks), -2 (orphan order in `ley state`), -3 (`floorOf` in
spectrum's JSON row), -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15, -16, -18. Each is small;
the meter one gets a test that shrinks the block and asserts the residue is erased.

### GO-3 `[x]` Verb defects and the `watch` stub

q-go-verbs-3 (`parseNegativeSafe` must not hand a marker to a flag: only substitute for positionals,
or restore the flag's value), -5, -6, -7 (`fileSidecar.SampleRate`: delete it, R-6 will bring its
own), -9, -10 (replace the sleep with a synchronisation and stop the runner on failure);
a-layering-8 and -13 (the `watch` stub per the decision above, and the matching line in
`docs/interfaces.md`); a-layering-11 (`scanIDOf` returns an error when no `ley://scans/` URI is
present, and the caller reports it); a-invariants-9 (`devices.go:73`: the refusal for an `rtltcp`
device says it is configured on the daemon's command line and how to remove it); a-layering-10 and
PC-11 (auto squelch in `--persistent` and `--json` modes per the decision; tick PC-11 in
`docs/plans/cli-papercuts.md`).

### GO-4 `[x]` The client library carries what every client needs

q-go-lib-2 (`Subscription.Err` memoises), -4 (clone the request), -5 (`Reader.Read` with an empty
`dst`), -6 (marine band bound and its comment), -7 (`FormatFrequency` at the GHz boundary), -8
(`GRPCCode` case for `CodeUnavailable`), -10 (keep `ctx` in `Dial`, replace `_ = ctx` with the
sentence that says the connection is lazy and the parameter is kept for the eager-connect option),
-11 (use `strings` in the test); a-layering-4 (`snapGain` moves to `go/pkg/leyline` beside
`CheckGain`, honours `step_db`, and both the CLI and the fake call it; table test mirroring the
Swift `GainElement.snapped` cases); a-invariants-6 (the bulk payload codec — `DecodeFFTBins`,
persistence and audio equivalents — exported from `go/pkg/leyline`, the CLI sites call it with the
descriptor's bin format, and an e2e case checks a DB_U8 row against a DB_F32 row of the same
fixture within the quantisation step).

### GO-5 `[x]` `leyfix` rate check

q-go-lib-3: `fits()` considers the built sources, so `scan_band` is refused at a rate its carriers
alias in; `TestCheckReducedGeneration` adjusts accordingly.

### GO-6 `[x]` The fake tells the daemon's story, part one

q-go-fake-1 … q-go-fake-18, in file order. The verifiers downgraded -3 and -7 to P3 but both stay:
they are cheap and the point of the fake is parity. For each behavioural change add the CLI test
that could not exist before (a bandwidth the daemon refuses; Ctrl-C then `GetScan` seeing the
partial scan; a write refused with `DEVICE_SWEEPING` during a scan; no fabricated squelch edge;
`CreateChannel` stamping activity so `busyReason` reports a recent write).

### GO-7 `[x]` The fake tells the daemon's story, part two (R-14 of the release plan)

The ten divergences listed under "The wire contract" in `docs/plans/v1-release.md`, each with its
CLI test. Check `RTLSDRDevice.swift` for the feature keys the real driver emits and fix
`docs/engine-internals.md` if it disagrees.

### GO-8 `[x]` Every verb answers `--json` or refuses it (R-5 of the release plan)

`docs/plans/v1-release.md` section R-5 in full, plus q-go-render-4's package-doc and help-topic
claims made true.

### GO-9 `[x]` One version, stamped at build time (R-2 of the release plan)

`docs/plans/v1-release.md` section R-2 in full.

## Code work items — Swift lane (Opus, sequential)

### SW-1 `[x]` Two RPCs that kill the daemon

q-swift-daemon-1 and -2: validate `persistence.rows_per_second` and `half_life_seconds` as finite
and within stated ranges (reject with `INVALID_ARGUMENT` naming the range, or clamp the way the FFT
path does), saturate before converting, and add both hostile values to `MalformedInputTests` for
kind `PERSISTENCE`.

### SW-2 `[x]` `RTLSDRDevice` locking and the device index contract

q-swift-control-1 (snapshot the id before the lock; a test that walks the leaked-thread path with a
fake handle if one can be arranged, else a comment on the critical section listing what it must not
touch), q-swift-control-6 (private storage, locked read, private setter from inside the existing
critical sections), c-swift-core-4 (reset `runningIndex` on every `startStreaming` in
`RTLSDRDevice` and `FilePlaybackDevice`, so the contract `CaptureDSPCore` documents is true for all
three devices).

### SW-3 `[x]` Jobs: presence, the cancel window, and what a sweep protects

a-layering-1 / a-invariants-1 (`JobsService` touches presence on every unary; daemon test that
starts a scan and polls `GetJob` with no stream open for longer than the grace), a-evolution-1
(create the sweep task before the first suspension, and have `run` re-check the entry's state after
`publishJob` and after `allocate`, releasing the lease at once when it is no longer running),
a-evolution-2 (`destroyCaptureChecked` calls `refuseIfSwept`), q-swift-daemon-5 (`.gain` writes
refused while swept, tested beside `testTheSweepPinsGainAndRestoresIt`), a-evolution-16 (the
allocator closes a freshly created capture on both error paths), c-swift-daemon-2 (the recurring-
scan refusal names no milestone), a-evolution-17 (`ScanRunner` becomes an enum of static functions,
or gains the state that justifies the actor).

### SW-4 `[x]` Bulk registry and telemetry honesty

a-evolution-3 (register the subscription before the first await, or re-check the capture exists
before storing and close the half-built source), c-swift-daemon-1 (the audio branch drains after
its `for await`, like the ring branch), q-swift-daemon-6 (the IQ tap reports the count it wrote),
q-swift-daemon-4 (count dropped detections per sink and carry them as the `gap` of `yieldMerged`),
q-swift-daemon-3 (`WriteCoalescer.run` leaves its loop when `Task.sleep` throws).

### SW-5 `[x]` Registry and shutdown ordering

a-evolution-4 (`beginGracefulShutdown` first, then jobs, streams, store, registry), a-evolution-9
(enumeration through `BlockingWork`, `applyProbes` on the actor), q-swift-control-2 (refresh
`rtlIndex` for a dongle one of our captures holds), q-swift-control-3 (a duplicate virtual device is
closed, not leaked; or attach before open), q-swift-control-10 (`DeviceEventHub.finishAll` is called
from `stop()` or deleted).

### SW-6 `[x]` `FilePlaybackDevice` error and stop paths

q-swift-control-4 (a mid-file read error is logged and takes the disconnect path), q-swift-control-5
(the join runs through `BlockingWork` and the pacing sleep wakes on cancel).

### SW-7 `[x]` DSP correctness and dead paths

q-swift-dsp-1 (`precondition(decimation <= taps.count)` in both initialisers, or the explicit skip
carry), -3 (`ChannelDSPCore.reset()`: call it on stream restart, or delete it and say why stale
state is harmless), -7 (an `.f32` buffer is refused at `deliver` rather than committed as an empty
block), -12 (`maxNarrowBandwidthHz` derives from `plan()`), -13 (row remap rounds to nearest, as
documented), -15 (a single-bin believe window is either handled or rejected consistently by
`detect` and `windowFloorDBFS`); q-swift-control-11 (`settledGainDB` distinguishes 0 dB from
unknown), -12 (ULID comparison without a heap array), -13 and -14 (the S2 harness: a valid
`timespec`, `EINTR` handled, a negative `--seconds` refused).

### SW-8 `[x]` Sub-audible detector: reset, first window, confidence

q-swift-dsp-4 (the sub-audible task reads the core's squelch state and calls `detector.reset()` on
every close edge), -5 (no `detected` and no `recent.append` before a phase reference exists), -11
(`confidence` uses the tone's own neighbour gap), -9 (`testResetForgetsHistory` fails when `reset()`
does nothing), q-swift-control-8 (the task stops polling a core that is gone).

### SW-9 `[x]` Engine tests that cannot hang or pass by accident

q-swift-control-7 (`next` races the iterator against the sleep and throws on timeout; used in
`RegistryProbeTests` too), q-swift-dsp-14 (the producer gives up when the consumer does), -16
(unused local), q-swift-daemon-8 (`withPromptShutdown` composes `withDaemon`), -9 (the readiness
handshake replaces the sleep), a-layering-12 (`ChannelEngine.telemetry()` removed, tests use
`telemetrySubscription()`), and R-4 of the release plan (the flaky `RTLTCPDeviceTests` reconnect:
diagnose, fix, prove with ten full runs).

## Code work items — cross-language (Opus, sequential, after both lanes)

### X-1 `[x]` Capture tombstone

a-invariants-3 and a-layering-7 per the decision: daemon, proto comments (Capture, Channel, Sink),
fake, `session.fold` (`withoutCapture`), tests on all three.

### X-2 `[x]` One error registry

a-layering-3 (`EngineError.deviceSweeping`, `.streamNotFound`, `.internalError`; the six literal
throw sites use them), a-layering-2 (the status table per the decision, written into
`docs/engine-internals.md`, with a test on each side asserting its switch matches the table entry
for entry), and R-15's first bullet from the release plan (Go constants for `BLIND_SPOT`,
`NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL`; `scan.go` uses them; a test that the Go list and the
engine's registry are the same set).

### X-3 `[x]` `Job.error`, and the request stays the request

a-evolution-8 and a-evolution-13 per the decision: `make proto`, daemon `finish` sets `error`,
`status_detail` becomes prose only, the fake mirrors, `scan.go` reads `error.code` (falling back to
the prefix for older daemons is not needed: nothing is released). R-15's remaining proto comments
(`step_hz`, `required_hz`, `SHM_RING`, `AttachFileDeviceRequest.path`, `Sink.stream`, the
`SubAudible` DCS fields) land in the same proto edit.

### X-4 `[x]` `ley jobs`

R-15's last bullet: client wrappers for `ListJobs` and `DetachSink`, and `ley jobs [cancel <id>]`
with `--json`, against the fake and in the e2e.

## Second look (Opus, sequential, after the lanes)

### SW-10 `[x]` What the audit of the engine lanes found

An independent read of commits `6044fcb..HEAD` on the engine side, made after the per-item
verifiers, which each saw one item in isolation. Line numbers are as of `c25b12d`.

1. `ChannelDSPCore.reset()` (`Channels/ChannelDSPCore.swift:~332`) swaps in a fresh, closed
   squelch without an edge. If the squelch was open, push a `.squelch(open: false)` telemetry
   record for the last processed block's time and bump `squelchCloses`, so
   `DefaultChannelEngine`'s sub-audible reset fires across the discontinuity; also clear
   `subAudibleTap`'s ring. Test: an open channel, `captureStreamRestarted()`, one close record and
   `squelchCloses` incremented.
2. `DefaultCaptureEngine.beginStreaming` (`Capture/DefaultCaptureEngine.swift:~97`) discards
   `drainPending()`'s result. When the DSP thread is running and the drain timed out, skip the
   channel resets and log a warning that says why (a block is still in flight and `reset()` must
   not race it); when no thread is running there is nothing in flight and the resets proceed.
3. `beginStreaming` now has two suspension points before `streaming = true`. After each `await`,
   re-check that the engine is still started and not already streaming (a `stop()` or
   `setSampleRate` can interleave) and return without touching the device otherwise. A test that
   interleaves `stop()` during the drain if a seam allows it; otherwise the guard and a comment.
4. `DefaultDeviceRegistry.poll()` (`Devices/DeviceRegistry.swift:~283`): the table can change
   while enumeration runs off the actor. Keep a mutation generation counter on the registry,
   snapshot it before the suspension, and discard the pass when it moved (the next poll is a
   second away). `BlockingWork.run`'s doc comment says it is for open/close-class calls only; the
   poll now uses it once a second — say so and why a thread per call is acceptable, or reuse one.
5. `CoreProtocols.swift` `RadioDevice.setSampleRate` doc: a device may refuse the call while
   streaming with `DEVICE_BUSY` (`RTLSDRDevice` does); the capture engine always stops streaming
   first; `RTLTCPDevice` and `FilePlaybackDevice` accept a live change.
6. `FilePlaybackDevice.stopStreaming` (`Devices/FilePlaybackDevice.swift:~184`): the second
   caller's `while streaming { lock.wait() }` has no deadline; bound it (3 s, like
   `RTLSDRDevice`'s join) and log when it expires.
7. `DaemonTestHarness.swift:~65` `withPromptShutdown`: the watchdog awaits the shutdown child, so
   it cannot fire before the hang it exists for. Run the shutdown as an unstructured `Task`, race
   its value against a sleeper, `XCTFail` on the timeout, and make the comment at `:~37` true.
8. `Server.swift:~161`: a duplicate `--rtltcp` endpoint logs "attached" twice for one device;
   have `attachVirtualDevice` report whether the device was already hosted and log "already
   attached" instead.
9. `SessionStore.swift:325, 444, 448` compare `e.code` against the string literals
   `"DEVICE_BUSY"` and `"DEVICE_IO"`; use the `EngineError.Code` constants (a-layering-3's last
   three sites).
10. Comments that overclaim: `CaptureDSPCore.swift:~183` (the `.f32` refusal commits a zero-count
    block; say what happens), `RTLSDRDevice.swift:~352` (the `idString` line uses the locking
    accessor outside the lock on purpose; say so), `DefaultCaptureEngine.swift:~95` (the wait is
    bounded and can fail), `DaemonTestHarness.swift:~37` (true once item 7 lands),
    `Persistence.swift:~13` (state the fact; drop the hypothetical future subscriber).

The suite stays green; run it twice at the end.

## Closing out (the release-plan items that were decided)

### X-5 `[x]` Remote radios as daemon state: the contract, the fake, the client wrappers

R-20 of the release plan, first third. Additive proto in `control.proto`:

```
message FileSource   { string path = 1; bool loop = 2; }
message RtlTcpSource { string host = 1; uint32 port = 2; }
message DeviceSource { oneof source { FileSource file = 1; RtlTcpSource rtl_tcp = 2; } }
message AttachDeviceRequest { DeviceSource source = 1; }
message DetachDeviceRequest { string device_id = 1; }
rpc AttachDevice(AttachDeviceRequest) returns (DeviceDescriptor);
rpc DetachDevice(DetachDeviceRequest) returns (Empty);
```

Comments state the contract: a file source is ephemeral (as `AttachFileDevice`, which stays and is
documented as sugar over `AttachDevice{file}`); an `rtl_tcp` source is remembered by the daemon
across restarts until detached; attach connects once and fails with `DEVICE_IO` naming `host:port`
when the server cannot be reached, remembering nothing; a second attach of the same `host:port`
returns the existing descriptor; `DetachDevice` accepts any device a client attached (file or
rtl_tcp), closes it, forgets it, and refuses a USB radio with `INVALID_ARGUMENT` ("unplug it").
`make proto`. The fake (`go/internal/fakedaemon`) implements both: an `rtl_tcp` source becomes a
descriptor with driver `rtltcp`, model `rtl_tcp <host>:<port> (R820T)`, serial `<host>:<port>`,
feature `remote`, the R820T gain table; a host ending in `.invalid` is refused with `DEVICE_IO`; a
duplicate returns the existing device; detach removes it and its capture, emitting the device
event. `go/pkg/leyline` gains `AttachDevice`/`DetachDevice` wrappers beside the existing ones.
Tests in the fake's own suite.

### SW-11 `[ ]` Remote radios as daemon state: the daemon

R-20, second third. `ControlService` implements `AttachDevice` and `DetachDevice` over the
`SessionStore` and `DefaultDeviceRegistry`. Attach `rtl_tcp`: dedupe on `host:port` against the
hosted devices before constructing anything (returns the existing descriptor); construct an
`RTLTCPDevice`, `open()` with the existing 5 s timeout, on failure throw `DEVICE_IO` naming the
endpoint and host nothing; on success `attachVirtualDevice`, then remember the endpoint. Attach
`file`: the existing `attachFileDevice` path. Detach: any hosted virtual device (the registry's
`isDetachableFileDevice` guard widens to "hosted by a client or the remembered list"; USB dongles
refused with `INVALID_ARGUMENT`); an rtl_tcp detach also forgets the endpoint. The remembered list
lives in `devices.json` beside the socket (`{"rtl_tcp":[{"host":"…","port":1234}]}`), written on
every change, read at startup and attached after the `--rtltcp` flags with the same dedupe; an
unreachable remembered endpoint is logged and kept (the reconnect-on-poll path brings it back),
exactly like an unreachable flag today. `--rtltcp` stays for foreground runs and is documented
as such. Tests in `LeylineDaemonTests` with the engine tests' `FakeRTLTCPServer`: attach, duplicate,
unreachable (`.invalid` host or a closed port), detach, and the round trip through `devices.json`
(attach, tear the daemon down, bring a new one up on the same directory, the device is present).
`docs/engine-internals.md` gets the paragraph.

### GO-10 `[ ]` Remote radios as daemon state: `ley devices attach`

R-20, last third, against the fake. `ley devices attach rtltcp <host:port>` (the kind is a literal
so later sources slot in) calls `AttachDevice`, prints one line in the `ley play` style ("attached
rtl_tcp pi.local:1234 (R820T) as dev_…; the daemon remembers it. Forget it with: ley devices detach
<n>") on stderr with the id on stdout, `--json` prints the `DeviceDescriptor`; an unreachable host
exits 1 with the daemon's sentence; a duplicate says so and exits 0. `ley devices detach` uses
`DetachDevice` for any driver, so an rtl_tcp device detaches, and the USB refusal keeps its current
sentence. Docs: `docs/interfaces.md` tree and the `--json` paragraph; `docs/cli-guide.md` section 1
("a radio on another machine"); `docs/dev-setup.md`'s rtl_tcp section says `ley devices attach` is
the way and `--rtltcp` is for foreground runs; README's "What works today" mentions it. Tests
fake-backed, including the exit codes.

### X-6 `[ ]` Remote radios end to end

After SW-11 and GO-10: `go/internal/e2e` gains a minimal `rtl_tcp` server in Go (the 12-byte
`RTL0` header with tuner 5 and 29 gains, then a stream of zero samples, commands read and ignored),
and a test that attaches it through `ley devices attach rtltcp 127.0.0.1:<port>` against the real
daemon, sees it in `ley devices --json`, tunes it with `--no-audio`, detaches it, and confirms
`devices.json` in the daemon's directory went from one entry to none.

### SW-12 `[ ]` Signposts on the sample-path code added since Milestone B

R-19 of the release plan. Add names to `Signposts.swift` and intervals around `AudioSink.write`
(`CoreAudioSink`, `CallbackSink`), the daemon's `FrameRing` writes, `PersistenceAccumulator.add`,
and the sweep's row collection in `ScanRunner`, so the S1/S2 Instruments runs see the whole path.
The wrappers are allocation-free and compile to nothing off macOS; keep it that way (no string
formatting on the hot path). A test that each new name is distinct and stable is enough.

### GO-11 `[ ]` What the audit of the Go lanes found

An independent read of commits `6044fcb..42a84a3` on the Go side, made after the per-item
verifiers. Line numbers are as of `42a84a3`.

1. q-go-fake-5 landed without its test: add one where a telemetry subscriber arriving during an
   open transmission receives no fabricated `SquelchTransition` (a revert of
   `telemetry.go:122-124` must fail it).
2. Bare `ley --json` prints prose on stderr and exits 0 with empty stdout (`root.go:683-686`),
   which is neither of the two answers R-5 allows. Decision: bare `ley --json` prints exactly what
   `ley state --json` prints; `json_verbs_test.go:194-197` stops excluding the root; the
   `docs/interfaces.md` sentence about bare `ley` says so.
3. `root.go:357`: `usageErrorf`'s doc comment was orphaned above the inserted `compCmdName`; move
   it back onto `usageErrorf`.
4. `daemon_test.go:501`: replace the 20 ms sleep with `leyline.ScopeSince(nil, st.EventSeq)`, as the
   rest of that file now does.
5. `state.go:226-231`: presence-drop `reap` emits the terminal CANCELLED event before the sweep
   stores its partial results (q-go-fake-2 on a second path). Route it through the same stop path
   `CancelJob` uses so the results land first and the detail reads
   `stopped in step X of Y, N found` like `JobStore.clientGone`.
6. `jobs.go:143, 145, 191`: `failScan` calls with bare `"NO_DEVICE"` and `"DEVICE_BUSY"` literals;
   use the `leyline.Code*` constants.
7. Fake parity, each with the CLI assertion it protects where one exists:
   `bulk.go:174` drop the `DEVICE_DETACHED` refusal (the daemon's `StreamRegistry.subscribe` has
   no capture-state check); `writes.go:272-281` a nil `GainWrite.value` is `INVALID_ARGUMENT`
   "gain value is required"; `writes.go:273-278` `auto:false` restores the last manual level, else
   a mid-range default, as `SessionStore.swift:798-808`; `jobs.go:538` completed detail is
   `N found in X steps` with the daemon's clipped and short-rows variants (`JobStore.swift:238-250`);
   `jobs.go:84` the detail passes through `sweeping N steps` before `step 1/N`; `jobs.go:517-523`
   `failScan` stamps `CompletedAtNs`; `jobs.go:93, 96` `step_hz` and `resolution_hz` are stamped
   only once allocation succeeds, from the plan; `control.go:197-200` the narrow-bandwidth refusal
   uses the daemon's exact sentence (`Channelizer.swift:61`); `bulk.go:195-233` and `control.go:199`
   `INVALID_ARGUMENT` details carry no `target`, as the daemon's do; `jobs.go:584-586` `CancelJob`
   on a terminal job leaves it untouched.
8. Docs: one sentence in `docs/cli-guide.md`'s waterfall section that each row is the loudest of
   the looks across its interval (the ROW_MAX accumulation GO-8 made the default), matching the
   stderr note.

Dropped from the audit with reason: `SnapGain` clamping a descriptor with no table, no step and no
range to 0 dB is exact parity with `GainElement.snapped` and unreachable behind `CheckGain`;
`phosphor.go`'s drain reorder and `scan.go`'s reading of `Job.error` are the intended shapes;
`bulk_stream.go`'s render under the fake's lock is a fake-only cost.
