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
  inspector's Claims group followed on 2026-11-02 (`ClaimWords`, `ClaimWordsTests`; the
  radio-decoding scene checks a `ley decode aprs --job` among them).
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
  not yet run. The app's `DecoderPlacement` was replaced by a call to `Control.Plan` on
  2026-11-02 (`DecoderPlacementTests` words each plan kind; docs/dev/app.md, "The Decoders
  place"); its copy of the allocator and those tests are gone.
- [x] **CL-3 Uniform displacement.** `tuning_generation` on `Capture` and bulk frames; IQ
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
  Done 2026-11-02 in the engine, `ley` and the Go fake (`DisplacementTests`,
  `RecordingJobTests+Retune`, `CapturePlannerTests`; engine-internals.md, "Claims" and "Bulk
  service"). `Capture.tuning_generation` and `Frame.center_hz`, `span_hz` and `tuning_generation`
  are new; `ley spectrum`, `waterfall`, `phosphor`, `fft` and MCP's spectrum label each row from
  its frame. The first event that sees a move records the mover (named before the engine is
  touched, so the allocator's and a sweep's moves name the job), and a job's DEGRADED detail says
  it once published: "paused: the app tuned NESDR SMArt v5 to 146.520 MHz; resumes when …". An IQ
  decoder's claim is now the centre it was handed, exactly, at its rate, because its runner holds
  the plugin to that tuning; an IQ recording's is its frequency in span at its rate, so a dedicated
  decoder may centre a capture under a recording, which goes on in a new part. A view's claim
  rides the next capture event or one a second later: 50 streams opened and closed in 0.1 s made
  one capture event. Not done: the app's inspector showing `displaced_by` (app work), and the
  design's priority rule beyond these three changes (CL-4, CL-5).
- [x] **CL-4 Return and sharing.** Automatic return after a job's or sweep's displacement, rate
  included, replacing `restoreCenterHz` and the sweep restore; a capture lives while any claim
  holds it (DEC-19).
  Done 2026-11-02 in the engine and the Go fake (`CaptureReturnTests`; engine-internals.md,
  "Claims", "Returning and sharing"). A job's move notes where it found the capture (centre,
  rate, and the gains when it set its own); when the job lets go the capture goes back there,
  unless a person has moved it since (nothing returns), a claim made since on the new tuning
  would be displaced, or, when somebody else moved it since, any claim would be left
  unsatisfied. A return that cannot happen yet waits for the next release on the capture, so a
  capture another job joined goes back when that one ends too. The target is the tuning the job
  found rather than one chosen for the highest-priority displaced claim: it is where every claim
  the job displaced was satisfied. A take_over IQ decoder now puts the centre and rate back, which
  it did not before. A capture the allocator made goes with its last CHANNEL, IQ or SWEEP claim,
  a person's channel included; views and presences do not hold it. The Go fake keeps a capture
  made for a job while any job's channel is on it.
- [x] **CL-5 One confirmation in the clients.** `ley tune --retune` and the app's retune and
  Start confirmations read `Control.Plan`'s displaced list; the app asks about any job, not only
  recordings; MCP's 3 s own-write waiver is replaced by the same rule.
  Done 2026-11-02 in `ley`, `ley mcp` and the app, with no engine change. Every `ley` verb that
  moves an existing capture asks the plan and refuses with its list, views and its own claims
  never among them: "retuning to 150.000 MHz would pause the aprs decoder on 144.390 MHz; --retune
  moves it anyway" (`refuseDisplacing`); the channel counting and `refuseRetuneOverRecording`
  are gone, and a decoder now stops a retune too. The MCP tools refuse through the same code
  with "Call again with take_over: true"; a job the daemon would decline only for this server's
  own claims (compared by holder with its client id) goes ahead without `take_over` and says so.
  The app asks "This pauses the APRS decoder on 144.390 MHz." before any person's move that
  pauses a JOB claim, clicks and typed frequencies included; whether to ask is read from the
  capture's job claims and the words from the plan (`RetuneAsk`), and a drag asks once and
  keeps the answer for the drag (`RetuneDrag`). The Claims group says "paused by the app at
  14:05". The Go fake's plan now names a job's channel claim by the job. Not covered: a file
  radio tunes only its own centre, so no eval and no check scene can reach a retune refusal; the
  `retune-asks` scene checks Scan band's question, `RetuneAskTests` the click and drag rules,
  and `dont-disturb` and `tune-over-decoder` grade the agent's path rather than the refusal's
  words.
- [ ] **CL-6 Later:** a displaced kept job asks `plan` for another radio.

## Verification

On the Mac, 2026-11-03, after CL-5 (`d73bfc0` and the scene fix after it): `make app-check
JOBS=3` 1145 checked, 1145 ok; `make app-test` and `make app-lint` clean. The one failure on the
way was the assistant-conversation scene reading its last tree before the app had reconnected
to the restarted daemon (Claims 2 or 3 by timing); it now waits and expects the settled three.

- [x] CL-1: the Claims group's count and rows match in every scene that shows the inspector.
- [x] CL-2: the Decoders place's placement words from `Control.Plan` match in the decoder scenes.
- [x] CL-3: no picture or tree changed; the sweep and record scenes pass.
- [x] CL-4: the sweep-lifecycle and transport scenes pass with the engine's return.
- [x] CL-5: retune-asks, the "Move the radio?" question and the Claims group's wording pass.
