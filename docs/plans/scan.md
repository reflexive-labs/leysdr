# Plan: ley scan (Milestone D.13)

Design: `docs/design-scan.md`. Every number in the detector was measured before it was written down;
the design doc carries the tables. This file is the work list and the record of what each step
actually found.

Order matters: 1–5 are pure and testable with no RPC, 6 is the wire, 7–12 are the daemon, 13–15 the
client, 16–17 the harness and the docs.

## Engine foundations

- [x] **SC-1 `SweepPlan`.** Step geometry as a pure function: quarter-band windows 5%–45% either
      side of centre, advance by half a window so step *k+1* covers step *k*'s DC hole, two extra
      steps outside the range so its first and last hertz sit inside a window. Clamp to the device's
      tuning range and report when the request was wider.
- [x] **SC-2 `SpectrumSink.write` carries the look count.** The ladder knows M and throws it away;
      the detector's threshold is wrong by up to 4 dB without it. Touches `CoreProtocols.swift`,
      `SpectrumLadder`, `FFTFrameSink`, `PersistenceFrameSink`.
- [x] **SC-3 `RadioDevice.inFlightSamples`.** How many samples the driver has already asked the
      hardware for and not yet delivered. RTL-SDR answers 32 × 16384 from its `rtlsdr_read_async`
      geometry; a file device answers 0. This is the settle window, and it is arithmetic rather than
      a guess about wall-clock timing.
- [x] **SC-4 `EnergyDetector`.** CFAR local floor (96 guard, 96 reference), Wilson–Hilferty
      threshold from the row's actual M and the whole-sweep false-alarm budget, grouping with a
      two-bin join, linear-power centroid, equivalent rectangular width, mirror rejection at 20 dB.
      Conforms to the `Detector` protocol that has been declared and unimplemented since the protos
      were written.
- [x] **SC-5 Detector tests.** Synthetic rows: the false-alarm rate against pure noise, sensitivity
      at the design point, floor tracking across a tilt, width independent of SNR, a tone reported
      as under the resolution, an image rejected and its source kept.

## The wire

- [x] **SC-6 Additive proto fields.** `Event.job = 9`, `GetStateResponse.jobs = 7`,
      `Detection.looks = 10 / looks_possible = 11 / floor_dbfs = 12`, `Scan.gains = 7`,
      `ScanConfig.take_over = 6`. Regenerate both languages with `make proto`; never hand-edit.

## Daemon

- [x] **SC-7 `ScanID`.** A `scan_` prefixed ULID beside `JobID`.
- [x] **SC-8 `CaptureAllocator` and `CaptureLease`.** The declared protocol returns a `ChannelID`,
      which cannot express what a sweep needs. Add `exclusiveCapture` and a lease with `retune` and
      an idempotent `release`. Policy: idle device, else an untouched capture, else decline with a
      reason naming who has it. Restores centre and gain on release.
- [x] **SC-9 `JobStore`.** An actor holding the jobs and their scans in memory, last sixteen kept.
      Job state transitions emit full-state `Job` events through the session store's seq.
- [x] **SC-10 `ScanRunner`.** The sweep: pin gain, walk the plan, discard the settle window from
      each step by sample index, feed rows to the detector, merge across steps, emit detections on
      telemetry as they are found, accumulate the `Scan`.
- [x] **SC-11 `JobsService`.** `StartJob(scan)`, `GetJob`, `ListJobs`, `CancelJob`, `GetScan`.
      `recurring` rejected with a stable code. Everything else stays UNIMPLEMENTED.
- [x] **SC-12 Detection on telemetry.** A detection hub the telemetry service drains, gated on
      `TelemetryType.DETECTION` and the capture filter.

## Client

- [x] **SC-13 fakedaemon jobs.** A scan the Go tests can run without the Swift daemon.
- [x] **SC-14 `ley scan`.** Range positional or `--band`, live progress on stderr, table on stdout,
      `--json` as the proto3 `Scan`. Un-hide the verb.
- [x] **SC-15 CLI tests.** Range parsing, the conflict, the table, the empty case, the clipped case,
      strip-to-plain, `--json`.

## Harness and docs

- [x] **SC-16 Fixtures and a synthetic retunable device.** A multi-carrier fixture with carriers at
      known offsets and levels for the one-step detector test; a test-only device in the daemon
      tests that changes its content late after `tune`, for the multi-step loop.
- [x] **SC-17 Docs.** `interfaces.md` (the CLI tree, the JSON shape, the additive fields),
      `cli-guide.md` (a section), `build-order.md` (D.13 done), `fixtures.md` (the new fixture).

## Notes

**SC-1 through SC-5 landed together**, and three things came out of building them that the design
did not have:

- The **row-edge reference window**. A CFAR estimator near the end of a row has reference bins on
  one side only. Shrinking the sample there would raise the false-alarm rate exactly where the
  roll-off already makes the floor hardest to read, so the shortfall is taken from the other side
  and the count stays fixed. The estimate is still biased toward the row's middle in the outermost
  ~190 bins -- and that is covered by the sweep geometry rather than by the estimator, because one
  step's window edge is the next step's interior.
- **Wilson-Hilferty errs in both directions**, not always high. It is within 0.45 dB of the exact
  exponential answer across the tail, above it in the deep tail (the safe direction) and about
  0.05 dB below it at p = 1e-2. The test pins the magnitude, not a direction.
- The tilt test asserts a **relationship, not a number**: the local floor must leave less than half
  the tilt a single median leaves. Absolute residuals move with the synthetic tilt shape; the claim
  that matters does not.

**SC-6 needed a file move.** `Event.body` has to be able to name a `Job`, and `jobs.proto` already
imported `control.proto` -- a cycle protoc refuses. `DemodMode` and `GainState` moved down into
`common.proto`, which is free: everything is in package `leyline.v1`, so the fully-qualified names,
the wire and every generated type name are unchanged, and both languages rebuilt without a source
edit.

**SC-10's settle window is arithmetic on the sample timeline, not a timer.** The runner keeps the
newest sample index any row has reported; at each hop that index plus the lease's `settleSamples`
is the first index the new frequency can have produced. The timeline is monotonic across a retune,
so this is exact. The wall clock appears only as a backstop deadline in case a device is slower
than its own arithmetic says.

**The threshold is fixed for a whole step, not recomputed per row.** It spends a sweep-wide
false-alarm budget, so a budget that moved as rows arrived would make a step's first row stricter
than its last -- a detector whose sensitivity depends on when in the dwell a signal appeared.

**Three bugs the fixture run found that no unit test would have.**

- `SweepPlan` refused a **point tuning range** (`guard r.maxHz > r.minHz`), which is exactly what a
  file device has -- so the one-step fixture sweep the design calls for could not run at all. The
  guard is now `>=`.
- A narrow request reported **signals from outside it**: a step's analysis window is what the radio
  can see from that tuner position, and the answer is what was asked for. The window is now clamped
  to the plan's covered range before anything is reported.
- Back-to-back scans failed every other time. The lease was released in a detached task after the
  job reached its terminal state, so the next scan found the capture still leased and was declined.
  The release is now awaited before the job finishes -- safe in a cancelled task, because nothing
  in the release path checks cancellation.

**A request entirely inside the DC guard is a failure, not an empty result.** On a radio with one
tuning point there is no neighbouring step to cover the hole, so `ley scan 145.95M..146.05M` over a
recording centred at 146 MHz can see nothing at all. Reporting "nothing found" there would be a lie;
it names the blind spot and points at `ley spectrum`.

**The floor is reported even when nothing is found.** It was originally taken from the detections'
own floor readings, so an empty band had no floor to report -- which is the one case where a reader
most wants it.

**`--json` is one `Scan` and nothing else.** Job events under `--json` were an NDJSON stream with the
answer on the last line; a consumer wants the answer.

**Verified against the daemon**, sweeping `fixtures/scan_band.cf32`: four of four carriers found at
the right frequencies, widths within a bin of the truth, SNRs matching the synthesis, and one 4 dB
false positive marked `1/4` in three runs out of four.

**The synthetic-device test found the bug it was built for, immediately.** Its radio changes what it
emits six blocks *after* `tune` returns, the way real hardware keeps USB buffers queued. The first
run put phantom carriers at 146.363 and 146.603 MHz -- a real signal at 145.400 MHz, seen in blocks
captured at one centre and labelled with the next one. Two things were wrong with the settle
arithmetic:

- The hop position came from the newest row seen, and rows arrive at the row rate, so it could be a
  whole row interval behind the radio. The lease now reports the capture's own sample position and
  the hop is taken from whichever is later.
- A row is stamped with the block that completed it and reaches back a whole interval, so a row
  whose stamp clears the settle window can still contain samples from inside it. The window is one
  row interval longer than the queue depth for that reason.

That is precisely the class of error the whole design exists to prevent -- energy attributed to a
frequency the radio was not listening to -- and no unit test would have produced it.

## Review findings, and what came of them

An adversarial review over six dimensions found nine defects. Seven were real and are fixed here;
the two most valuable were things no test had reached.

- **A daemon crash.** `SweepPlan` built its low window as `UInt64(Double(hz) - edgeHz)`, and
  `UInt64(_: Double)` traps on a negative value in Swift rather than saturating. An HF recording at
  1 MHz played at 2.4 MSPS has a half-span of 1.08 MHz, so `ley scan 0.5M..1.9M` over
  `fixtures/am_tone.cf32` killed the daemon. Frequencies clamp at DC now, and the same scan finds
  the carrier at 750 kHz with the daemon still up.
- **Every reported frequency was half a bin high.** The bin-to-Hz mapping added 0.5 of a bin,
  treating a bin as an interval when the ladder's rows are point samples. It was visible in the
  fixture run all along -- carriers at 145.201 where the generator put 145.200 -- and read as
  centroid noise. All four now land exactly, and the e2e test asserts to within one bin so it
  cannot creep back.
- **Two scans could lease the same capture.** The allocator checked `leased` before three
  suspension points and inserted after them; an actor is re-entrant at a suspension, so both
  callers passed the check. The claim happens before any await now.
- **`CancelJob` could wait forever.** Waiting on the sweep task is what makes an interrupted scan
  return its partial answer, but the teardown path is uncancellable USB work -- `device.open`,
  `stopStreaming` -- so a Ctrl-C in the first second could block the RPC and a daemon shutdown
  behind it. Bounded to three seconds; past that the job is answered as cancelled and finishes on
  its own.
- **A sweep that failed mid-way discarded what it had found**, including detections already
  published on telemetry -- a subscriber would have held readings the Scan denied. The runner no
  longer throws: it returns the partial result with the failure attached.
- **The lease was invisible to the control plane.** Invariant 9 puts jobs behind the allocator;
  nothing stopped a *client* joining a capture a sweep was walking, and its channel would have been
  dragged across megahertz with no explanation. `CreateChannel` and centre/rate writes on a swept
  capture now refuse with a reason.
- **A copy-on-write allocation on the DSP thread.** `RowCollector.drain` handed out the slot's
  Swift Array, making its storage shared, so the next write to that slot allocated a fresh copy --
  on the hot path, which invariant 4 forbids. The slots are raw buffers now, which cannot be shared
  by accident.

Two more, smaller: the `localFloor` fallback for a row narrower than the guard band wrote past the
scratch buffer its own contract specifies (unreachable from the sweep, but it is a public function),
and `reap` did not re-guard `stillAbsent` across the new client-gone hook's await.
