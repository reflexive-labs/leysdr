# Plan: ley scan (Milestone D.13)

Design: `docs/design-scan.md`. Every number in the detector was measured before it was written down;
the design doc carries the tables. This file is the work list and the record of what each step
actually found.

Order matters: 1–5 are pure and testable with no RPC, 6 is the wire, 7–12 are the daemon, 13–15 the
client, 16–17 the harness and the docs.

## Engine foundations

- [ ] **SC-1 `SweepPlan`.** Step geometry as a pure function: quarter-band windows 5%–45% either
      side of centre, advance by half a window so step *k+1* covers step *k*'s DC hole, two extra
      steps outside the range so its first and last hertz sit inside a window. Clamp to the device's
      tuning range and report when the request was wider.
- [ ] **SC-2 `SpectrumSink.write` carries the look count.** The ladder knows M and throws it away;
      the detector's threshold is wrong by up to 4 dB without it. Touches `CoreProtocols.swift`,
      `SpectrumLadder`, `FFTFrameSink`, `PersistenceFrameSink`.
- [ ] **SC-3 `RadioDevice.inFlightSamples`.** How many samples the driver has already asked the
      hardware for and not yet delivered. RTL-SDR answers 32 × 16384 from its `rtlsdr_read_async`
      geometry; a file device answers 0. This is the settle window, and it is arithmetic rather than
      a guess about wall-clock timing.
- [ ] **SC-4 `EnergyDetector`.** CFAR local floor (96 guard, 96 reference), Wilson–Hilferty
      threshold from the row's actual M and the whole-sweep false-alarm budget, grouping with a
      two-bin join, linear-power centroid, equivalent rectangular width, mirror rejection at 20 dB.
      Conforms to the `Detector` protocol that has been declared and unimplemented since the protos
      were written.
- [ ] **SC-5 Detector tests.** Synthetic rows: the false-alarm rate against pure noise, sensitivity
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

Recorded as the work lands.
