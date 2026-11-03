# Plan: capture claims

Status: queued 2026-11-02, after batch 2 of `decoders-app.md`. Implements
`../design/claims.md`. Legend as in `app.md`.

Each step lands with its `ley` mirror and keeps every existing test green; behaviour changes only
where the step says so.

- [x] **CL-1 The ledger.** `Claim` and `Capture.claims` in `control.proto`; every consumer in the
  design's table creates and releases its claim through `SessionStore` (channels, job channels,
  IQ leases, bulk IQ and FFT streams, sweep and monitor leases, sinks and the 60 s write window as
  the PERSON claim). `inUse` is computed from the ledger. No placement changes. `ley state` and
  the app's inspector list a capture's claims. Test: each consumer kind appears and disappears.
  Done 2026-11-02 in the engine and `ley state` (`ClaimsLedgerTests`; engine-internals.md,
  "Claims"). The allocator's `leased` set, its IQ-reader table and the store's `swept` set are
  now claims. A claim's `state` is computed (DISPLACED when the capture no longer gives it what
  it needs); `displaced_by` waits for CL-3. A sweep lease now releases its claim after putting
  the capture back, so a write in that moment is refused rather than overwritten. The app's
  inspector is not done: it is app work, left for the next app batch.
- [x] **CL-2 `plan` and `Control.Plan`.** The allocator's three steps become one pure function over
  the ledger, with the priority rule; the allocator carries out its result; `Control.Plan` returns
  it read-only. `--dry-run` on `ley decode`, `ley record` and `ley scan`; MCP tools describe
  what they would displace. The app's `DecoderPlacement` (DA-7) is replaced by a call to it.
  Tests: a table of requests against ledgers, the current allocator tests unchanged.
  Done 2026-11-02 in the engine, `ley` and `ley mcp` (`CapturePlanner`, `CapturePlannerTests`,
  `ControlPlanTests`; engine-internals.md, "Claims" and "Control service"). The allocator walks
  `CapturePlanner.walk`, so every reason and code is as before. The don't-disturb test is kept
  as it was rather than the design's priority rule; the three places they differ are listed in
  engine-internals.md, "Claims", for CL-3 and CL-5. A recording of somebody's channel now holds a
  JOB claim of its own. The `dry_run` tool argument has the `ask-before-starting` eval scenario,
  not yet run. Not done: the app's `DecoderPlacement`, left for the next app batch.
- [ ] **CL-3 Uniform displacement.** `tuning_generation` on `Capture` and bulk frames; IQ
  recordings start a new part when displaced and resumed; views carry the centre per row; the
  DEGRADED detail names who moved the radio; displaced claims on capture events.
  From the CL-1 review: a VIEW claim's arrival or release does not publish a capture event on
  its own (it rides the next one, or one coalesced per second), so a client opening and closing
  waterfall streams cannot push real events out of the 256-event replay window; and a sink
  attached by a job never makes a PERSON presence (`notePresence` checks `isInteractive`).
  From CL-2, the three places today's behaviour kept differs from the design, now changed here:
  a retune that leaves a claim satisfied does not count it as displaced, so it does not decline a
  job; a radio held by a sweep declines with DEVICE_BUSY naming the sweep, not a silent NO_DEVICE;
  and "cannot reach this frequency" is NO_DEVICE however it arises, "in use" is DEVICE_BUSY.
- [ ] **CL-4 Return and sharing.** Automatic return after a job's or sweep's displacement, rate
  included, replacing `restoreCenterHz` and the sweep restore; a capture lives while any claim
  holds it (DEC-19).
- [ ] **CL-5 One confirmation in the clients.** `ley tune --retune` and the app's retune and
  Start confirmations read `Control.Plan`'s displaced list; the app asks about any job, not only
  recordings; MCP's 3 s own-write waiver is replaced by the same rule.
- [ ] **CL-6 Later:** a displaced kept job asks `plan` for another radio.
