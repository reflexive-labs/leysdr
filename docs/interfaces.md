# Leyline — MCP Surface & CLI Tree

Both are renderings of the leyline.v1 protos. The CLI is the reference client; `--json` output is the standard proto3 JSON mapping. The MCP adapter adds presentation only (PNG rendering, band-plan labels, compact summaries) — never capability.

## MCP tools

| Tool | Maps to | Notes |
|---|---|---|
| `list_devices` | Control.ListDevices | descriptors with capability detail |
| `get_state` | Control.GetState | orientation: captures, channels, activity |
| `tune` | CreateCapture/CreateChannel/WriteParams | refuses to retune active captures (don't-disturb) unless `override: true`; returns refusal reason |
| `listen_summary` | Telemetry.Subscribe (bounded) | subscribes for `duration_s`, returns activity segments observed |
| `scan` | ad-hoc sweep via Jobs machinery | inline results, ephemeral; suggests `start_job` for persistence |
| `snapshot` | Bulk.Subscribe(FFT, one row) | returns PNG (adapter-rendered) + binned data |
| `start_job` / `list_jobs` / `get_job` / `cancel_job` | Jobs service | watch, scan, record configs as typed payloads |
| `get_transcript` | Jobs.GetTranscript | segments + coverage gaps; adapter adds waterfall thumbnails |
| `find_recordings` | Resources.ListResources | metadata-filtered; returns `ley://` URIs |

MCP resources = `ley://` URIs one-to-one. Enforcement of don't-disturb is daemon-side policy; the adapter's refusal-with-reason is the polite layer on top.

## CLI tree

```
ley                                  # bare: orientation screen on a TTY (see below); the verb list when piped
├── tune <freq|preset> [--mode M] [--bw N] [--squelch L|auto|off] [--volume V] [--gain dB|auto] [--rate N] [--device SEL] [--persistent] [--no-audio] [--retune]
│                                    # capture+channel+system-audio sink in one verb; prints every decision it made;
│                                    # refuses to retune a capture other active channels ride on unless --retune
├── set [param value] [--channel SEL] [--capture SEL] [--element E]
│                                    # live adjust: freq (frequency), mode, bw (filter), squelch, gain, volume (streams WriteParams); no args = show
├── stop [channel|all] [--all] [--device SEL]
│                                    # DestroyChannel for one channel (set's target rule); all/--all destroys every channel and the capture, freeing the radio
├── spectrum [freq] [--span N] [--bins N] [--watch] [--rate N] [--count N] [--device SEL] [--width N] [--retune]
│                                    # one FFT row drawn as a bar chart + the loudest bins (>= floor + 6 dB, else "nothing above the floor"); the human view of fft
├── fft [--freq F] [--bins N] [--rate N] [--count N] [--format json|bin] [--u8] [--device SEL]
├── listen <freq|preset|chan_ID> [--format json|bin] [--count N] [--mode M] [--bw N] [--squelch L] [--gain dB|auto] [--device SEL] [--rate N] [--retune]
│                                    # the channel's decoded audio on stdout (SubscribeAudio), no system-audio sink; a channel id taps one already running
├── presets | bands                  # the client-local tables (no RPC); `ley help presets` is the same data in prose
├── play <file.cf32> [--freq F] [--mode M] [--bw N] [--squelch L] [--volume V] [--gain dB|auto] [--loop] [--persistent] [--no-audio]
│                                    # FilePlaybackDevice through the same pipeline
├── devices [--watch] | devices detach <SEL>
├── state                            # GetState snapshot, the debugging entry point
├── daemon [install|uninstall|start|stop|status|logs]
├── version
├── help [command|topic]             # topics: squelch, frequencies, modes, gain, presets, glossary, scripting, roadmap
├── record | scan | watch            # hidden stubs: exit 2 "not implemented yet (Milestone …)"; listed by `ley help roadmap`
└── (planned) jobs, transcript, recordings   # arrive with the Jobs/Resources services (Milestones C.12, D)
```

Global flags: `--json` everywhere; `--socket PATH` (default the user daemon's UDS, `$LEYLINE_SOCKET`).

**Input conventions** (`go/pkg/leyline`, shared by every verb): a bare frequency number is MHz
(`146.52`, `1010`); units `k`, `M`, `G`, `Hz`, `e6` are exact; commas are refused with a hint.
Squelch levels are dBFS (`-40`, `-40dB`, `off`, `auto`); a positive number is an error that
explains the scale. Bandwidth: a bare number is kHz. Volume: `0..1` or `50%`. Modes by alias
(`fm` → WFM on 87.5–108 MHz else NFM; `ssb` → USB at and above 10 MHz else LSB). **Selectors**:
`--channel`, `--capture`, `--device` and `devices detach` accept a full id, an id prefix, the
1-based row number from the printed list, or a frequency. **Presets** (`noaa`, `noaa1..7`,
`calling`, `marine16`, `guard`, with aliases) and **bands** (name, default mode, default
bandwidth) are pure client-side tables, rendered as tables by `ley presets` and `ley bands` and in
prose by `ley help presets`; resolution is number/unit form first, then preset name, never probing. These are presentation over the same RPCs: the CLI
adds no capability the protocol lacks.

**`--json`** is the canonical proto3 JSON mapping (lowerCamelCase keys, e.g. `captureId`,
`centerHz`; 64-bit integers as strings; NDJSON for streams). Everything meant for a person goes
to stderr, so stdout is parseable. **Three documented exceptions.** The first sits beside the
shm-ring bypass in the design docs: bulk rows have no proto message, so `ley fft --format json`
and `ley spectrum --json` emit `{seq, sample_index, center_hz, span_hz, bins}` (snake_case, numbers
as numbers), spectrum adding `peaks: [{center_hz, db}]` — the N loudest local maxima of the row,
presentation only, never called signals. `ley listen --format json` is the audio member of the same
exception: `{seq, sample_index, sample_rate, format, pcm}`, `pcm` being the frame's PCM bytes
base64-encoded and `format` the `AudioSampleFormat` the daemon settled on (`S16` in v0); every row
repeats the rate and format so a consumer needs no header. `--format bin` writes those same frames
raw, back to back and nothing else. `ley fft` subscribes GAP_MARKED (audio and IQ stay
LATEST_WINS), so a drop shows up as a `{"gap":{"from_sample":A,"to_sample":B}}` line before the
next row — never silently; gap lines do not count toward `--count`. The second is `ley version --json`: a client-local value
with no proto message, emitted through encoding/json as exactly `{"version","go","os","arch"}` in
that order (pinned by a golden test). The third is the client-local tables: `ley presets --json`
prints one array of `{name, aliases, hz, mode, description}` and `ley bands --json` one array of
`{name, min_hz, max_hz, mode, bandwidth_hz, note}` (`mode` is `usb/lsb` where the sideband follows
the frequency). Neither verb dials the daemon; `ley help presets` is the same data in prose, and
`ley presets` (the verb) owns the bare name.

Destructive verbs echo nothing stale: `ley stop`, `ley stop --all` and `ley devices detach` print
the daemon's `Empty` answer (`{}`) under `--json` — one line for the whole action — and the exit
status carries success; when `stop --all` finds nothing running it prints nothing (the sentence is
stderr prose without `--json`) and exits 0. `ley set --json` prints the confirming or rejecting
Event and exits 1 on a `WriteRejected` with nothing on stderr. `ley devices --watch --json` prints
the `ListDevicesResponse` first (the same line `devices --json` prints), then one `Event` per plug
or unplug carrying the full `DeviceDescriptor`. `ley daemon start --json` and `daemon stop --json`
print the same `DaemonInfo` as `daemon status --json` (start from a fresh `GetState` after the
action; stop the last info the daemon reported, pid included, or only `socketPath` when nothing was
running); `daemon install`, `uninstall` and `logs` have no JSON shape and reject `--json` as a
usage error (exit 2).

**Exit status** (also `ley help scripting`): 0 on success, including a Ctrl-C that ends a live
`tune`/`play`/`spectrum --watch`/`fft`/`listen`/`devices --watch` session; 1 when the daemon refused or
failed (the line reads `ley: <message> [CODE]`, keeping the daemon's stable `ErrorDetail.code`,
unless `ley` has a plainer sentence for that code); 2 usage error — bad flag or argument,
unknown verb (with Cobra's "did you mean"), unknown setting, unparseable value or unknown
preset — nothing was sent to the daemon (selector misses such as `--channel 9` depend on daemon
state and exit 1); 3 the daemon is not running, from any verb (`ley: the Leyline daemon is not
running (socket …). Start it with: ley daemon start`, or the stale-socket variant); 130
interrupted by Ctrl-C before the verb's live phase. Error lines read `ley: <plain sentence>.
<next command>`. `daemon status --json` always prints a `DaemonInfo`; when the daemon is not
running it carries only `socketPath` (no `pid`) and the status is 3. `daemon stop` exits 0 once
the socket has stopped answering and removes a stale socket file; under launchd the LaunchAgent
uses `KeepAlive.SuccessfulExit=false`, so a clean stop stays stopped while a crash is relaunched.

**Bare `ley` (decision, 2026-09-05).** On a TTY it prints an orientation screen — daemon status,
devices, what is playing, and the next commands chosen from the state; exit 0 in every state,
300 ms dial timeout. Piped it prints the verb list; `--json` points at `ley state --json`. This
screen is the placeholder the V0.5 TUI dashboard replaces on a TTY (`docs/sdr-user-stories.md`);
its renderer (`renderOrientation` in `go/internal/cli`) is the one function the dashboard reuses
for its no-daemon and no-device states, so the words stay the same.

**Auto squelch and the daemon-side follow-up.** `tune --squelch auto` (the interactive default
for NFM and AM) and `set squelch auto` subscribe one FFT row of the capture, take the median bin
as the floor, scale it to the channel bandwidth (`+10·log10(bw / bin width)`) and write
`floor + 10 dB` with `WriteParams`. The measurement is the daemon's own spectrum and a median is
presentation, so no DSP moves client-side (CLAUDE.md invariant 2); but the threshold is a
snapshot, and every client would have to repeat it. The recorded follow-up is an additive
daemon-side relative squelch — `ParamWrite.squelch_relative_db`, "mute at noise floor + N dB"
tracked by the daemon — after which `auto` becomes a one-field write. Not in v0.

**Roadmap stubs.** `record` (Milestone C.12), `scan` (Milestone D) and `watch` (the V0.5
dashboard) exist as hidden verbs so a newcomer who types them learns what is coming and what to
use today (`ley play`, `ley spectrum`, bare `ley`); they exit 2 and never reach the daemon.

Deliberate omissions at v0: no remote flags (UDS-only), no TX verbs, no decode verbs (arrive with digital modes).

## Client requirements

The daemon's HTTP/2 stack (swift-nio-http2) drops a connection with `GOAWAY ENHANCE_YOUR_CALM` when
a client sends more than 200 control frames (PING, SETTINGS, PRIORITY) in 30 s, and the gRPC
transport does not expose that limit. Clients that ping for bandwidth estimation on every data frame
(grpc-go's default dynamic windows, grpc-python's BDP probing) therefore lose every busy bulk stream
after about a second. Use fixed flow-control windows instead: the Go client library dials with 1 MiB
initial stream and connection windows, which disables grpc-go's estimator. Other clients must do
the equivalent (grpc-go: `WithInitialWindowSize`/`WithInitialConnWindowSize` above 64 KiB;
grpc-core: `grpc.http2.bdp_probe=0`).
