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

- [ ] **SC-6 Additive proto fields.** `Event.job = 9`, `GetStateResponse.jobs = 7`,
      `Detection.looks = 10 / looks_possible = 11 / floor_dbfs = 12`, `Scan.gains = 7`,
      `ScanConfig.take_over = 6`. Regenerate both languages with `make proto`; never hand-edit.

## Daemon

- [ ] **SC-7 `ScanID`.** A `scan_` prefixed ULID beside `JobID`.
- [ ] **SC-8 `CaptureAllocator` and `CaptureLease`.** The declared protocol returns a `ChannelID`,
      which cannot express what a sweep needs. Add `exclusiveCapture` and a lease with `retune` and
      an idempotent `release`. Policy: idle device, else an untouched capture, else decline with a
      reason naming who has it. Restores centre and gain on release.
- [ ] **SC-9 `JobStore`.** An actor holding the jobs and their scans in memory, last sixteen kept.
      Job state transitions emit full-state `Job` events through the session store's seq.
- [ ] **SC-10 `ScanRunner`.** The sweep: pin gain, walk the plan, discard the settle window from
      each step by sample index, feed rows to the detector, merge across steps, emit detections on
      telemetry as they are found, accumulate the `Scan`.
- [ ] **SC-11 `JobsService`.** `StartJob(scan)`, `GetJob`, `ListJobs`, `CancelJob`, `GetScan`.
      `recurring` rejected with a stable code. Everything else stays UNIMPLEMENTED.
- [ ] **SC-12 Detection on telemetry.** A detection hub the telemetry service drains, gated on
      `TelemetryType.DETECTION` and the capture filter.

## Client

- [ ] **SC-13 fakedaemon jobs.** A scan the Go tests can run without the Swift daemon.
- [ ] **SC-14 `ley scan`.** Range positional or `--band`, live progress on stderr, table on stdout,
      `--json` as the proto3 `Scan`. Un-hide the verb.
- [ ] **SC-15 CLI tests.** Range parsing, the conflict, the table, the empty case, the clipped case,
      strip-to-plain, `--json`.

## Harness and docs

- [ ] **SC-16 Fixtures and a synthetic retunable device.** A multi-carrier fixture with carriers at
      known offsets and levels for the one-step detector test; a test-only device in the daemon
      tests that changes its content late after `tune`, for the multi-step loop.
- [ ] **SC-17 Docs.** `interfaces.md` (the CLI tree, the JSON shape, the additive fields),
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
