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

### CB-7 `[ ]` The documents (R-1 of the release plan)

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

### GO-3 `[ ]` Verb defects and the `watch` stub

q-go-verbs-3 (`parseNegativeSafe` must not hand a marker to a flag: only substitute for positionals,
or restore the flag's value), -5, -6, -7 (`fileSidecar.SampleRate`: delete it, R-6 will bring its
own), -9, -10 (replace the sleep with a synchronisation and stop the runner on failure);
a-layering-8 and -13 (the `watch` stub per the decision above, and the matching line in
`docs/interfaces.md`); a-layering-11 (`scanIDOf` returns an error when no `ley://scans/` URI is
present, and the caller reports it); a-invariants-9 (`devices.go:73`: the refusal for an `rtltcp`
device says it is configured on the daemon's command line and how to remove it); a-layering-10 and
PC-11 (auto squelch in `--persistent` and `--json` modes per the decision; tick PC-11 in
`docs/plans/cli-papercuts.md`).

### GO-4 `[ ]` The client library carries what every client needs

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

### GO-5 `[ ]` `leyfix` rate check

q-go-lib-3: `fits()` considers the built sources, so `scan_band` is refused at a rate its carriers
alias in; `TestCheckReducedGeneration` adjusts accordingly.

### GO-6 `[ ]` The fake tells the daemon's story, part one

q-go-fake-1 … q-go-fake-18, in file order. The verifiers downgraded -3 and -7 to P3 but both stay:
they are cheap and the point of the fake is parity. For each behavioural change add the CLI test
that could not exist before (a bandwidth the daemon refuses; Ctrl-C then `GetScan` seeing the
partial scan; a write refused with `DEVICE_SWEEPING` during a scan; no fabricated squelch edge;
`CreateChannel` stamping activity so `busyReason` reports a recent write).

### GO-7 `[ ]` The fake tells the daemon's story, part two (R-14 of the release plan)

The ten divergences listed under "The wire contract" in `docs/plans/v1-release.md`, each with its
CLI test. Check `RTLSDRDevice.swift` for the feature keys the real driver emits and fix
`docs/engine-internals.md` if it disagrees.

### GO-8 `[ ]` Every verb answers `--json` or refuses it (R-5 of the release plan)

`docs/plans/v1-release.md` section R-5 in full, plus q-go-render-4's package-doc and help-topic
claims made true.

### GO-9 `[ ]` One version, stamped at build time (R-2 of the release plan)

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

### SW-3 `[ ]` Jobs: presence, the cancel window, and what a sweep protects

a-layering-1 / a-invariants-1 (`JobsService` touches presence on every unary; daemon test that
starts a scan and polls `GetJob` with no stream open for longer than the grace), a-evolution-1
(create the sweep task before the first suspension, and have `run` re-check the entry's state after
`publishJob` and after `allocate`, releasing the lease at once when it is no longer running),
a-evolution-2 (`destroyCaptureChecked` calls `refuseIfSwept`), q-swift-daemon-5 (`.gain` writes
refused while swept, tested beside `testTheSweepPinsGainAndRestoresIt`), a-evolution-16 (the
allocator closes a freshly created capture on both error paths), c-swift-daemon-2 (the recurring-
scan refusal names no milestone), a-evolution-17 (`ScanRunner` becomes an enum of static functions,
or gains the state that justifies the actor).

### SW-4 `[ ]` Bulk registry and telemetry honesty

a-evolution-3 (register the subscription before the first await, or re-check the capture exists
before storing and close the half-built source), c-swift-daemon-1 (the audio branch drains after
its `for await`, like the ring branch), q-swift-daemon-6 (the IQ tap reports the count it wrote),
q-swift-daemon-4 (count dropped detections per sink and carry them as the `gap` of `yieldMerged`),
q-swift-daemon-3 (`WriteCoalescer.run` leaves its loop when `Task.sleep` throws).

### SW-5 `[ ]` Registry and shutdown ordering

a-evolution-4 (`beginGracefulShutdown` first, then jobs, streams, store, registry), a-evolution-9
(enumeration through `BlockingWork`, `applyProbes` on the actor), q-swift-control-2 (refresh
`rtlIndex` for a dongle one of our captures holds), q-swift-control-3 (a duplicate virtual device is
closed, not leaked; or attach before open), q-swift-control-10 (`DeviceEventHub.finishAll` is called
from `stop()` or deleted).

### SW-6 `[ ]` `FilePlaybackDevice` error and stop paths

q-swift-control-4 (a mid-file read error is logged and takes the disconnect path), q-swift-control-5
(the join runs through `BlockingWork` and the pacing sleep wakes on cancel).

### SW-7 `[ ]` DSP correctness and dead paths

q-swift-dsp-1 (`precondition(decimation <= taps.count)` in both initialisers, or the explicit skip
carry), -3 (`ChannelDSPCore.reset()`: call it on stream restart, or delete it and say why stale
state is harmless), -7 (an `.f32` buffer is refused at `deliver` rather than committed as an empty
block), -12 (`maxNarrowBandwidthHz` derives from `plan()`), -13 (row remap rounds to nearest, as
documented), -15 (a single-bin believe window is either handled or rejected consistently by
`detect` and `windowFloorDBFS`); q-swift-control-11 (`settledGainDB` distinguishes 0 dB from
unknown), -12 (ULID comparison without a heap array), -13 and -14 (the S2 harness: a valid
`timespec`, `EINTR` handled, a negative `--seconds` refused).

### SW-8 `[ ]` Sub-audible detector: reset, first window, confidence

q-swift-dsp-4 (the sub-audible task reads the core's squelch state and calls `detector.reset()` on
every close edge), -5 (no `detected` and no `recent.append` before a phase reference exists), -11
(`confidence` uses the tone's own neighbour gap), -9 (`testResetForgetsHistory` fails when `reset()`
does nothing), q-swift-control-8 (the task stops polling a core that is gone).

### SW-9 `[ ]` Engine tests that cannot hang or pass by accident

q-swift-control-7 (`next` races the iterator against the sleep and throws on timeout; used in
`RegistryProbeTests` too), q-swift-dsp-14 (the producer gives up when the consumer does), -16
(unused local), q-swift-daemon-8 (`withPromptShutdown` composes `withDaemon`), -9 (the readiness
handshake replaces the sleep), a-layering-12 (`ChannelEngine.telemetry()` removed, tests use
`telemetrySubscription()`), and R-4 of the release plan (the flaky `RTLTCPDeviceTests` reconnect:
diagnose, fix, prove with ten full runs).

## Code work items — cross-language (Opus, sequential, after both lanes)

### X-1 `[ ]` Capture tombstone

a-invariants-3 and a-layering-7 per the decision: daemon, proto comments (Capture, Channel, Sink),
fake, `session.fold` (`withoutCapture`), tests on all three.

### X-2 `[ ]` One error registry

a-layering-3 (`EngineError.deviceSweeping`, `.streamNotFound`, `.internalError`; the six literal
throw sites use them), a-layering-2 (the status table per the decision, written into
`docs/engine-internals.md`, with a test on each side asserting its switch matches the table entry
for entry), and R-15's first bullet from the release plan (Go constants for `BLIND_SPOT`,
`NO_DEVICE`, `FAILED_PRECONDITION`, `INTERNAL`; `scan.go` uses them; a test that the Go list and the
engine's registry are the same set).

### X-3 `[ ]` `Job.error`, and the request stays the request

a-evolution-8 and a-evolution-13 per the decision: `make proto`, daemon `finish` sets `error`,
`status_detail` becomes prose only, the fake mirrors, `scan.go` reads `error.code` (falling back to
the prefix for older daemons is not needed: nothing is released). R-15's remaining proto comments
(`step_hz`, `required_hz`, `SHM_RING`, `AttachFileDeviceRequest.path`, `Sink.stream`, the
`SubAudible` DCS fields) land in the same proto edit.

### X-4 `[ ]` `ley jobs`

R-15's last bullet: client wrappers for `ListJobs` and `DetachSink`, and `ley jobs [cancel <id>]`
with `--json`, against the fake and in the e2e.
