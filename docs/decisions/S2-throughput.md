# S2 — Throughput: 20 MSPS through the Swift engine, on one fifth of a core

Status: pass (2026-09-18) on all three criteria. One caveat, on the CPU number: it was taken on an
M4 Max where the criterion names a base part. Recorded below with what it does and does not
establish.

## Decision

**The all-Swift engine stands.** S2 is the spike that gates it (`docs/plans/build-order.md`:
"Fail = stop; revisit the all-Swift decision explicitly"), and the sample path sustained the full
20 MSPS for longer than the criterion asks, on a fifth of one core, allocating nothing per block.
All three thresholds are cleared by a wide margin. Milestone E may commit the Mac app to Swift on
top of this engine.

The risk this spike tested was whether Swift can hold a DSP loop without ARC traffic, a
copy-on-write firing inside a kernel, or an existential box in something that reads as a plain
loop. It can, in this engine as written: ten times the DSP work costs eleven
more allocations across a whole run.

## What was measured

Apple M4 Max, 128 GB, macOS Tahoe 26.6.2, 2026-09-18.

`swift build -c release && swift run -c release s2-throughput --seconds 600` — the harness in
`engine/Sources/S2Throughput`: a synthetic 20 MSPS cf32 source into `DefaultCaptureEngine`, one
NFM channel, `NullSink`.

| | measured | criterion |
|---|---|---|
| Duration | 639.56 s (10.7 min) | sustained 10 min |
| Offered / achieved | 20 000 000 / 20 000 006 sps (100.0%) | — |
| Blocks received / processed | 780 719 / 780 719 | — |
| Ring overruns | **0** | no overruns |
| CPU | 123.91 core-seconds = **19.4% of one core** | headroom ≥ 50% on a base M-series (this is an M4 Max; see below) |
| Kernels | Accelerate | (the vDSP path is the gate; portable kernels are not) |
| Allocations in the sample path | **zero** (0.0004 per block at ten times the block rate) | zero, on the Instruments allocations track |

12 791 300 096 samples through the channelizer and demodulator in ten and a half minutes, and the
NFM channel produced 48 193 audio frames a second throughout — the 48 kHz the 20 MSPS capture
decimates to, so the chain ran end to end rather than the source spinning against a stalled DSP
thread. Received equals processed, so no block was dropped; `overruns: 0` shows the same from the
ring's side.

**Headroom.** 19.4% of one core leaves 80.6% of that core, and about 2% of the machine. The run is
real time by construction (12.79 G samples at 20 MSPS is 639.6 s, which is the wall clock it took),
so this is the true cost of the rate rather than a throughput figure from a source running flat out.

**The criterion names a base M-series and this is an M4 Max**, which is the part the criterion was
written to exclude: it is the top of the line, and a base M1 or M4 has slower cores. The margin is
wide enough that the conclusion is not in doubt -- the gate is 50% headroom on one core and this
used 19.4%, so a base part would have to be more than two and a half times slower per core to fail,
which no M-series generation is against another -- but that is an inference from a measurement on a
fast machine, not a measurement on the machine the criterion names. If a base part is ever to hand,
the run is ten minutes and closes the gap properly.

## Allocations

**Measured: zero per block.** `scripts/hot-path-allocations.sh`, two phases.

```
     5s run :         2027 allocations,       6477 blocks
    25s run :         2457 allocations,      32469 blocks
  scaling  :          430 allocations over 25992 more blocks = 0.0165 per block

    25s at full rate :         2457 allocations,      32484 blocks
    25s at a tenth   :         2446 allocations,       3185 blocks
  same wall clock, 29299 more blocks, +11 allocations = 0.0004 per block
```

The first phase differences two run lengths, so one-off startup work cancels and only what scales
with blocks survives: 0.0165 per block, one per sixty. The absolute numbers show the same thing:
a path allocating once per block would have put about 32 000 allocations into the longer run on its
own, and the whole process made 2 457.

The second phase asks whether even that residual is the sample path, by running the same wall clock
at a tenth of the rate: identical time, a tenth of the blocks. **Ten times the blocks cost eleven
more allocations**, one per 2 664 blocks, which is the same size as the noise between two runs of
the identical measurement (2027 against 2028).

**Every allocation the process makes is accounted for without reference to blocks at all.** A model
of startup plus elapsed time -- 1 920 allocations at launch, 21.5 a second thereafter -- reproduces
both runs of the first phase exactly:

| | model | measured |
|---|---|---|
| 5 s at 20 MSPS | 2 027 | 2 027 |
| 25 s at 20 MSPS | 2 457 | 2 457 |
| 25 s at 2 MSPS | 2 457 | 2 446 |

The 21.5 a second is timers and runtime housekeeping; it does not move when the DSP does ten times
the work. The sample path allocates nothing.

**What this does not establish.** The count is process-wide rather than attributed to a thread or a
symbol. With no residual left to explain, attribution is not needed. If the screen ever fails, use
Instruments' allocations track to find the call tree. The screen takes half a minute and runs on
every change; an Instruments pass does not.

## What is still open

**Nothing that blocks the gate.** One thing would tighten it, and it is about the CPU number rather
than the allocations: this was measured on an M4 Max where the criterion names a base M-series (see
"Headroom" above). If a base part is ever to hand, the run is ten minutes.

The Instruments route is kept below because it is the criterion's named tool and the only one that
attributes allocations to a call site. It is not needed to close the gate.

**An Instruments pass for attribution.** The harness cannot check this itself, and its output
states that.

**The throughput run above cannot stand in for it, and the arithmetic says why.** A block is 16 384
samples, which is 819 us of wall clock at 20 MSPS; the DSP thread spent 159 us of that (the 19.4%
above), leaving 660 us of slack. A malloc costs on the order of 80 ns, so *a thousand allocations
per block* would take 80 us -- under 10% of the budget -- and produce no overrun, no dropped block
and no shortfall against the offered rate. The large margin would hide that failure.
Nothing else in the tree covers it either: the hot-path rule is stated in about ten source
comments and verified by no test.

This is also the main criterion for the spike. That vDSP can carry 20 MSPS was never much in doubt.
The risk in a Swift engine is ARC retain/release traffic, a copy-on-write that fires inside a loop,
or an existential box in something that reads as a plain kernel.
The allocations track is what shows those, and it is the evidence the all-Swift decision
rests on.

**Read the call tree, not a generation.** Generation analysis ("mark generation", the heapshot
button in the Allocations detail pane) answers *what is still alive since I last marked*, which
finds growth and leaks. That is not this criterion. A sample path that allocated and freed a
buffer every block would leave a generation diff empty and still be violating invariant 4, because
the cost forbidden there is the allocator call itself -- it takes a lock and it can block -- not
the bytes surviving it. What answers the criterion is the count of allocation *events* attributed
to the sample path, transient ones included.

**The quick check first**: `scripts/hot-path-allocations.sh` answers the criterion in a terminal in
about half a minute, and needs no Instruments at all. It interposes the allocator, runs the harness
twice at two durations, and differences the counts: whatever a process allocates at startup and in
its control plane cancels, and what is left is the allocation that *scales with blocks processed*,
which is what invariant 4 forbids. It prints allocations per block and a verdict. Use it as the
screen on every change; when the screen fails, use Instruments to find where the allocation is.

**Instruments cannot attach to a SwiftPM binary as built.** SwiftPM ad-hoc signs without
`com.apple.security.get-task-allow`, so profiling fails to attach to the process. Re-sign it first:

```sh
cat > /tmp/dbg.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>com.apple.security.get-task-allow</key><true/></dict>
</plist>
PLIST
codesign -s - -f --entitlements /tmp/dbg.entitlements \
  "$(cd engine && swift build -c release --show-bin-path)/s2-throughput"
```

Then:

1. Record, for **seconds, not ten minutes**. Ten minutes is the *sustained throughput* criterion
   and has been met; an allocation on a per-block path appears at once, and the harness's own
   default of ten seconds is about 12 200 blocks at 20 MSPS, which is enough. The run needs **no
   arguments**, so launching it from Instruments takes three clicks.

   ```sh
   cd engine && echo "$(swift build -c release --show-bin-path)/s2-throughput"
   ```

   Open Instruments, pick the **Allocations** template, *Choose Target…* that path, record. It
   runs, exits, and the trace is in front of you.

   Headless works too, but **`xctrace record` does not stop when the launched program exits** --
   it records until interrupted -- so it needs a time limit and somewhere to put the trace, or it
   sits there after the run has finished:

   ```sh
   xcrun xctrace record --template Allocations --time-limit 40s \
     --output ~/Desktop/s2-alloc.trace \
     --launch -- "$(swift build -c release --show-bin-path)/s2-throughput"
   ```

   (Headless is fine here precisely because no generation marks are needed. Marking one is a
   click in the GUI while recording and has no `xctrace` equivalent.)
2. Select the Allocations track and switch the detail pane to **Call Trees**, with **Separate by
   Thread** on. Find the DSP thread -- the one carrying `CaptureDSPCore.process` and
   `ChannelDSPCore` -- and expand it.
3. A pass is **no allocation attributed to anything under it**: `CaptureDSPCore`, `ChannelDSPCore`,
   `DSP/Demodulators`, `DSP/Channelizer`, `DSP/FIR`, `Rings`. The **Statistics** view's *Transient*
   column is the one to read, not *Persistent*: transient is the churn a generation diff hides.
4. Allocation elsewhere -- the control plane, the actor hops, logging, the device thread's setup --
   is expected and is not what invariant 4 is about.

Generations are still worth two clicks as a secondary check: mark one about 30 s in, once the run
is steady, and another near the end. Nothing should be growing between them either.

**The host.** The machine and macOS version this ran on are not recorded here yet; the release
checklist records them, and a throughput number without the chip it was measured on
cannot be compared with the next one.

## What this costs, and what would reopen it

- The number is for **one** NFM channel. `--channels N` runs more, and the per-channel cost is the
  channelizer stage rather than the capture, so a station running eight channels is a different
  measurement that nobody has taken. It is not what S2 gates, and it is the obvious follow-up when
  the app puts several channels on one radio.
- 20 MSPS is above anything the v0 hardware delivers: an RTL-SDR tops out at 2.4 MSPS (and 3.2 with
  dropped samples). This is headroom for the HackRF and Airspy class of radio on the roadmap, not a
  rate the shipped daemon reaches. At 2.4 MSPS the same path costs roughly a tenth of this.
- What would reopen it: a demodulator or a stage added to the sample path, a move off Accelerate,
  or the allocations pass above failing. A failure there still stops the all-Swift decision; it is
not fixed by tuning.
