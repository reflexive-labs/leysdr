# Plan: capture claims

Status: queued 2026-11-02, after batch 2 of `decoders-app.md`. Implements
`../design/claims.md`. Legend as in `app.md`.

Each step lands with its `ley` mirror and keeps every existing test green; behaviour changes only
where the step says so.

- [ ] **CL-1 The ledger.** `Claim` and `Capture.claims` in `control.proto`; every consumer in the
  design's table creates and releases its claim through `SessionStore` (channels, job channels,
  IQ leases, bulk IQ and FFT streams, sweep and monitor leases, sinks and the 60 s write window as
  the PERSON claim). `inUse` is computed from the ledger. No placement changes. `ley state` and
  the app's inspector list a capture's claims. Test: each consumer kind appears and disappears.
- [ ] **CL-2 `plan` and `Control.Plan`.** The allocator's three steps become one pure function over
  the ledger, with the priority rule; the allocator carries out its result; `Control.Plan` returns
  it read-only. `--dry-run` on `ley decode`, `ley record` and `ley scan`; MCP tools describe
  what they would displace. The app's `DecoderPlacement` (DA-7) is replaced by a call to it.
  Tests: a table of requests against ledgers, the current allocator tests unchanged.
- [ ] **CL-3 Uniform displacement.** `tuning_generation` on `Capture` and bulk frames; IQ
  recordings start a new part when displaced and resumed; views carry the centre per row; the
  DEGRADED detail names who moved the radio; displaced claims on capture events.
- [ ] **CL-4 Return and sharing.** Automatic return after a job's or sweep's displacement, rate
  included, replacing `restoreCenterHz` and the sweep restore; a capture lives while any claim
  holds it (DEC-19).
- [ ] **CL-5 One confirmation in the clients.** `ley tune --retune` and the app's retune and
  Start confirmations read `Control.Plan`'s displaced list; the app asks about any job, not only
  recordings; MCP's 3 s own-write waiver is replaced by the same rule.
- [ ] **CL-6 Later:** a displaced kept job asks `plan` for another radio.
