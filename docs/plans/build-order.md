# Leyline — Build Order

Agent-sized tasks with acceptance criteria. V0 user stories in `docs/plans/user-stories.md` are the acceptance tests of record; tasks reference them. Sequence matters: each task's dependencies are the tasks above it. "Closing the core" below is the gate between the engine milestones and the app.

## Spikes (gate everything)

**S1 — Latency chain.** RTL-SDR → daemon → shm ring → minimal Metal waterfall. Measure antenna-to-pixels with os_signpost. Pass: p95 under 50 ms, no dropped ring slots at 2.4 MSPS over 10 minutes. Artifact: an Instruments trace and a one-page findings note.

**S2 — Throughput.** Synthetic 20 MSPS cf32 source → channelizer → one NFM demod → null sink, allocation-free. Pass: sustained 10 min, zero allocations in the sample path (verified with Instruments allocations track), CPU headroom ≥ 50% on a base M-series. Fail = stop; revisit the all-Swift decision explicitly.

**S3 — USB posture.** IOUSBHost vs libusb for RTL-SDR and HackRF, sandboxed and not, current macOS. Artifact: a decision note updating the CLAUDE.md licensing/driver line if needed.

## Milestone A — skeleton that talks

1. Repo scaffold: SwiftPM workspace (EngineCore, Daemon, App) + Go module (`ley` CLI/TUI, McpAdapter, shared client lib); proto codegen wired for both languages (protoc-gen-swift, protoc-gen-go/go-grpc); CI running protoc validation + both test suites.
2. Daemon lifecycle: launchd plist, UDS listener, `ley daemon start|stop|status`, `ley state` returning an empty GetState.
3. Fixtures: IQ signal generator producing `fixtures/` (NFM tone, AM, USB, CW, calibrated noise); FilePlaybackDevice implementing RadioDevice. *(V0 story: playback through the same pipeline.)*

## Milestone B — samples flow

4. DeviceRegistry + RTLSDRDevice (per S3's decision); hot-plug events; stable IDs across replug. *(Story: devices list; unplug/replug.)*
5. CaptureEngine: device stream → fan-out, CaptureAnchor, detached/rebind states.
6. FFT ladder + shm ring + gRPC FFT stream. `ley fft` works against fixtures. *(Story: fft stream.)*
7. NFM demod + CoreAudioSink: `ley tune 146.52M` produces audio. Fixture round-trip test. *(Story: tune and hear.)*

## Milestone C — the contract proves out

8. WriteParams coalescing; `ley set` live adjust; events with attribution. *(Story: live adjust.)*
9. Second client concurrency: two CLIs, one device; state sync verified. *(Story: no device-busy.)*
10. Remaining demods (AM, WFM, SSB, CW) — one task each, fixture-gated.
11. Dual channels in one capture. *(Story: two NFM channels.)*
12. Recording + Resources + `ley record` / `ley play` / `ley recordings`. *(Story: record/playback.)*
    **Done** (2026-09-18): `docs/design/recording.md` as specified -- a recording is a job whose
    output is a resource, the squelch gate writes one file per exchange, the manifest states the
    gaps, and `Resources` answers `RECORDING`, `RECORDS` and `SCAN`. `Control.AttachSink(file)`
    stays refused; the MCP adapter gained `record`, `find_recordings` and `get_recording`; the
    `nfm_keyed` fixture states its own keying and grades the cuts. The last engine work before
    Milestone E; see "Closing the core".

## Milestone D — semantic tier

13. **Done.** Detector (energy detection, noise floor, persistence tracking); telemetry plane; `ley scan`. *(Story: scan with detections.)* Design and measured numbers: `docs/design/scan.md`.
14. TUI dashboard: bare `ley` opens a Bubble Tea dashboard — shaded-cell waterfall from a negotiated low-rate FFT stream, tuning controls, channel list, meters from telemetry. First real exercise of stream negotiation by a constrained consumer.
    Layout, decided 2026-09-13 with the design-system handoff so it is not re-argued when this starts:
    the dashboard owns its viewport, so its waterfall puts the newest row directly under the spectrum
    with the frequency axis between them, and time flows down the screen. That is the opposite of
    `ley waterfall`, which prints to a scrolling terminal, where newest-at-bottom is the only order
    that does not fight the scrollback and the axis is reprinted every 20 rows (`waterfallAxisEvery`)
    because the top of the screen is gone by the time a reader wants it. Two surfaces, two rules;
    neither is a precedent for the other. Everything else in `docs/dev/cli-style.md` holds here as it
    does in the scrolling views: the four-step `Shade` ramp rather than half-blocks (a half-block map
    is a blank rectangle with colour off), the six ink roles, and the level ramp, which since
    2026-09-14 is the brand's terminal palette (teal to salmon red, tuned for a dark ground) and is
    the same five stops the scrolling views draw with.
15. Jobs: store, JobRunner respawn, CaptureAllocator with don't-disturb; watch job → ActivitySegments → transcript.
16. MCP adapter (Go, sharing the `ley` client library); tools from `docs/reference/cli.md`; snapshot PNG rendering.
    The plan, with the where-the-server-lives decision and the tool order: `docs/plans/mcp.md`.
17. Decoders: the out-of-process plugin contract, the record envelope and store, decode jobs, and
    APRS as the first decoder (`ley decoders`, `ley decode aprs`, `ley records`, `ley track aprs`).
    Design and the build plan: `docs/design/decoders.md`, `docs/plans/decoders.md`. Started ahead
    of D.14 to D.16 because the contract it proves (plugins, records, the store) is what the MCP
    adapter's highest-value tools read.

## Closing the core (decided 2026-09-17)

The core is good enough when the app's stories have a contract behind them, and they do except for
two items. Everything else still open in `docs/plans/` is breadth over a contract that has held its
shape since D.13, and it waits behind the app rather than in front of it.

**The gate, before E.1 starts:**

- ~~C.12 recording, as `docs/design/recording.md` specifies it: the V0 story that was in every cut,
  the app's "start/stop recording from the UI", and the MCP `find_recordings` tool in one.~~
  **Done, 2026-09-18.**
- ~~S2 measured on the owner's Mac under Instruments against its criteria above, recorded as
  `docs/decisions/S2-throughput.md`.~~ **Measured 2026-09-18 and passed on throughput and CPU:**
  20 MSPS sustained 10.7 minutes, 0 overruns, 19.4% of one core, Accelerate kernels. The
  all-Swift decision stands. The allocations criterion passed too, at **zero per block**: ten times
  the DSP work in the same wall clock cost eleven more allocations, and a model of startup plus
  elapsed time accounts for every allocation the process makes
  (`scripts/hot-path-allocations.sh`). **The gate is closed; Milestone E may start.**

**Decided not to gate on:**

- **The shm ring.** The daemon answers a ring request with gRPC by design, and a 2048-bin
  waterfall at 30 rows a second is about 60 KB/s over the socket. The app draws over gRPC first and
  measures S1; the ring is built if the measurement says so, not before.
- **Bookmarks, presets, scan lists and CHIRP import.** Interpretation state, client-side, in a
  shared file both `ley` and the app read, on the pattern `go/pkg/labels` set for transmitter
  names (`docs/design/decoders.md`, "The state boundary"). Not daemon state, so not engine work;
  it is E.4, with a `ley bookmarks` mirror so nothing works only from Swift.
- **A smaller IQ recording format** (`iq_format`, the device's native format rather than cf32:
  4x, and lossless for an RTL-SDR -- measured 2026-09-18, `docs/design/recording.md`,
  "Deliberately not in v1"). The first thing to reopen when the recordings store hurts, and
  ahead of anything about the audio format. Backlogged behind the app, not forgotten.
- **D.14, D.15, MCP-8 to MCP-11, DEC-12/13/14/15/19, SV-7, SV-9, BW-2, BW-3, R-21, R-22.**
  Deferred behind Milestone E. D.14's stated purpose, a constrained consumer negotiating streams,
  the three terminal live views already prove.

## Milestone E — the Mac app

The SwiftUI app as a peer client (V1a stories in `docs/plans/user-stories.md`). It links
`LeylineProto` and never `EngineCore`, so it stays a separate Apache-2.0 work beside the GPL engine
(`docs/decisions/D2-licensing.md`). Its tests run against the real daemon with `--no-hardware` and a
file device, which is what that harness exists for. Every contract addition the app needs ships with
its `ley` mirror.

1. App target and the Swift client façade: dial, `GetState` plus `WatchEvents` folded into an
   observable mirror, a client-side coalescer feeding `WriteParams` at display rate, stream
   helpers for FFT and telemetry. *(Story: the CLI changes the tuning and the UI reflects it.)*
2. Layer 0 and spike S1: launch, spectrum and Metal waterfall over the gRPC FFT stream, click to
   hear on the opinionated defaults. Antenna-to-pixels measured with signposts on both ends; the
   ring decision is made from the numbers. *(Story: live spectrum the moment I launch.)*
3. Layer 1 controls: frequency, mode, squelch, volume, drag-to-tune, keyboard shortcuts, and the
   named failure states from telemetry (flat floor, zero gain, no antenna).
4. Bookmarks, presets and CHIRP import over a shared `bookmarks.json`, with `ley bookmarks`;
   the built-in preset table becomes the seed layer of the same list and gains the newcomer
   presets the V1a story names.
5. Recording from the UI and reveal in Finder, over C.12.
6. Lifecycle: daemon not running, unplug and replug, and the layer 2 inspector last.
7. Distribution (D4): a notarized bundle carrying `leylined`, `ley` and the decoders, installing
   the launchd job as `ley daemon install` does; the trademark check (D3) gates the first public
   build.

Each task lands with: tests (fixture-based where DSP), os_signpost instrumentation on any new sample-path code, and no invariant violations (CLAUDE.md is the review checklist).
