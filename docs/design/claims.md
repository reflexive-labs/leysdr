# Design: Capture claims

Status: proposed 2026-11-02; CL-1 (the ledger) implemented 2026-11-02, the rest not yet. The
work is `../plans/claims.md`. Companion to `control-plane.md` ("Arbitration"), whose rules this
keeps, and to `scan.md`, `recording.md` and `decoders.md`, whose don't-disturb sections it
replaces with one rule.

A **claim** is a consumer's statement of what it needs from a capture's tuning: a frequency in
span, or an exact centre and rate. Every channel, IQ reader, spectrum view and sweep holds one.
The daemon keeps every claim in one ledger and decides placement, retunes and their consequences
with one function. A claim is not a lock: a person is still never blocked by a job.

## Why

A capture is tuned to one centre at one rate, and on a one-dongle Mac everything shares it. Five
kinds of consumer depend on that tuning today. Each registers in its own way, and only two are
visible to the don't-disturb check (inventory of 2026-11-02, from the code):

| consumer | registered as | seen by `inUse` | when the capture moves |
|---|---|---|---|
| a person's channel (app, `ley tune`, MCP) | channel with an owner | yes | `OUT_OF_CAPTURE`, back when it fits |
| a job's channel (decode, record, watch) | persistent channel, owner `job:<id>` | yes | job DEGRADED, gap logged |
| an IQ reader (IQ decode, `ley record --iq`) | an allocator lease, nothing in the store | no | IQ decode DEGRADED (DA-4); IQ record **silently shifted** |
| a spectrum or waterfall stream, `ley snapshot` | a bulk tap | no | **descriptor stays at the old centre** |
| a sweep or monitor | private `leased` set and store `swept` flag | no (sweeps refuse writes) | not applicable: exclusive |

The consequences:

- **The check misses consumers.** A dedicated decoder could retune a capture another IQ job was
  reading (found in review on 2026-11-02, fixed narrowly in `inUse`). An IQ recording records a
  retune as the same file at a new frequency.
- **Each client re-implements the check.** `ley tune` refuses without `--retune` when channels are
  active and when record jobs would be moved. The app asks only about record jobs, so it moves a
  kept decoder without a word. MCP waives its own writes for 3 s. The app's decoder placement
  (`decoders-app.md`, DA-7) is a copy of the allocator. Four copies of one rule already disagree.
- **Restore is partial.** A channel lease restores the centre on release if no other channel is
  left, but never the rate. An IQ lease restores nothing.
- **Nobody can ask first.** There is no dry run, so a client learns where a job landed, or what it
  displaced, only afterwards.
- **Shared IQ captures cannot be counted** (DEC-19): the lease that created a capture destroys it
  on release, even if another reader still taps it.

## What does not change

- **A person is never blocked by a job** (`control-plane.md`). A person's retune is applied. The
  only refusal stays the sweep's `DEVICE_SWEEPING`, which lasts seconds.
- **Last write wins among people, with attribution.** Claims add no lock between two windows.
- **Jobs degrade rather than fail.** A displaced job is DEGRADED, marks its gap and resumes.
- **Never queue.** A job that cannot be placed is declined with the reason.
- **`take_over` keeps its meaning:** a job may displace claims it would otherwise not.

`control-plane.md` rejected leases because they protect the rarest case, two people tuning at
once, and anticipated that "attribution and the activity signal are the primitives a lease would
need". Claims are those primitives made explicit, used for the common cases: person against job,
and job against job.

## The claim

```
message Claim {
  string claim_id = 1;           // clm_<ulid>
  ClientInfo holder = 2;         // the client, or job:<id>
  ClaimKind kind = 3;            // LISTEN, CHANNEL, IQ, SPECTRUM, SWEEP
  oneof need {
    Span covers = 4;             // frequency and bandwidth inside the capture
    Centre centred = 5;          // centre within tolerance_hz (a dedicated decoder)
  }
  uint64 sample_rate_hz = 6;     // 0 = any rate
  ClaimPriority priority = 7;    // PERSON, JOB, VIEW
  ClaimState state = 8;          // SATISFIED or DISPLACED
  ClientInfo displaced_by = 9;   // who moved the capture, while DISPLACED
  int64 displaced_since_ns = 10;
}
```

`Capture.claims` lists them in `GetState`, and claim changes are capture events like any other.
Clients never create a claim directly: creating a channel, starting a job, opening a bulk stream or
starting a sweep creates it, and ending that thing releases it. No client code changes to keep
working.

**Priority** is set by what the holder is, not by the holder:

- **PERSON:** an interactive client's channel, a live audio sink, or a write in the last 60 s.
  This is the current don't-disturb signal, now held as a claim that lapses after 60 s without a
  write while the person has no channel or sink.
- **JOB:** any job's channel or IQ reader, kept or not.
- **VIEW:** a spectrum or waterfall stream. Displacing a view is never a reason to decline, and
  the view follows the capture: its next rows carry the new centre.
- **SWEEP** is not a priority but an exclusive kind: while a sweep holds a capture, nothing else
  can be placed on it, and writes are refused as now.

## One decision: `plan`

One pure function in the engine answers every placement question:

```
plan(request, state) -> Plan
  request: a new claim (a job's channel or IQ need) or a retune (a person's or a job's write)
  Plan:    SHARE capture        -- satisfied with nothing moved
           CREATE on device     -- an idle radio
           RETUNE capture to centre/rate, displacing [claims]
           DECLINE reason, blocking [claims]
```

The order is the allocator's today: share, then an idle device, then a retune. The rule for a
retune is one sentence: **a request may displace only claims of lower priority, unless it carries
`take_over`, which lets it displace any claim except a sweep.** A person's write is PERSON and is
never declined (it may displace jobs and views); a job's request is JOB and displaces only views
without `take_over`.

The allocator, `WriteParams` and a new read-only RPC all call it:

- **The allocator** carries out the plan for jobs. The 60 s window, the live-sink rule and the
  "another job" rule stop being separate checks.
- **`WriteParams`** applies a person's retune as before, and the resulting capture event names the
  claims it displaced, with `caused_by` as now.
- **`Control.Plan`** returns the plan without carrying it out. `ley decode`, `ley record` and `ley
  scan` gain `--dry-run`; `ley tune` uses it instead of counting channels itself; the app's
  decoder placement and its retune confirmation both call it; the MCP tools say what a call would
  displace before making it. One rule, four surfaces, no copies.

## Displacement, uniformly

When a plan displaces a claim:

- **The holder is told:** the claim goes DISPLACED with `displaced_by`, and a job goes DEGRADED
  with a detail naming who moved the radio and where ("paused: the app tuned to 146.520 MHz").
- **Nothing reads the wrong spectrum.** A channel withholds audio and the gap is marked (as now);
  an IQ decoder withholds IQ and marks the gap (DA-4); an IQ recording closes its part and starts
  a new one when it is satisfied again, never writing two tunings into one file; a view gets the
  new centre on its next row.
- **Every capture carries a `tuning_generation`** that increments on each centre or rate change,
  in `Capture` and in each bulk frame. A consumer compares generations, so a retune away and back
  between two polls is still seen.
- **Returning is automatic when a job did the displacing.** When a claim that displaced others is
  released (a `take_over` job ends, a sweep finishes), the daemon retunes to satisfy the
  highest-priority displaced claims, rate included. This replaces `restoreCenterHz` and the
  sweep's restore. When a *person* displaced a job, nothing returns automatically: the person is
  at the controls, and the job waits.
- **A shared capture lives while any claim holds it.** It is destroyed when its last claim is
  released, so several IQ decoders share a capture without its creator tearing it down (DEC-19).

## In the clients

- **A person is asked before displacing a job, once.** `ley tune` keeps `--retune`; the app shows
  one confirmation naming what pauses ("This pauses ADS-B and the 2 m recording"). Both read the
  list from `Control.Plan`, so they agree. Views are never asked about.
- **A decoder's page shows the plan, then the claim.** Before Start: the plan's answer. After: the
  claim's state, DISPLACED with who and when, which is the same fact the job's DEGRADED detail says.

## Not in this design

- **Locks against people,** and two-operator arbitration: still gated as in `control-plane.md`.
- **Moving a displaced job to another radio.** `plan` can answer it once claims exist (a displaced
  kept job asks for a new placement on another device), but it is a later step, not the first.
- **Priorities between jobs,** such as a kept job outranking a session one. Jobs are equal; a
  job displaces another only with `take_over`.

## Decisions

- Claims, not leases: declarations of need, used to decide and to explain, never to refuse a
  person.
- One `plan` function in the engine, exposed read-only as `Control.Plan`; clients never
  re-implement placement.
- Priority from the holder's kind: PERSON over JOB over VIEW; sweeps exclusive.
- Automatic return only after a job or sweep displaced others; never after a person did.
- Additive wire changes only: `Claim`, `Capture.claims`, `Capture.tuning_generation`, the
  generation on bulk frames, displaced claims on capture events, `Control.Plan`. `take_over` fields
  stay as they are.
