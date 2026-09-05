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
ley
├── devices [detach <id>]            # list; --watch for hot-plug events; detach removes a file device
├── tune <freq> [--mode nfm] [--bw N] [--device ID]
│                                    # capture+channel+system-audio sink in one verb
├── set <param> <value>              # live adjust: gain, squelch, bw, mode (streams WriteParams)
├── fft [--bins N] [--rate N] [--format json|bin]
├── scan <range> [--step N] [--dwell N]   # ad-hoc, inline results
├── record [--iq|--audio] [--duration N]  # FileSink; prints ley:// URI
├── play <file|ley://uri>            # FilePlaybackDevice through the same pipeline
├── watch <freq> [--mode M] [--clips] [--until T]   # starts a watch job
├── jobs [list|show <id>|cancel <id>]
├── transcript <job-id> [--follow]
├── recordings [list|show <uri>|path <uri>]
├── daemon [start|stop|status|logs]
└── state                            # GetState snapshot, the debugging entry point
```

Global flags: `--json` everywhere; `--socket PATH` (default the user daemon's UDS).

`--json` is the canonical proto3 JSON mapping (lowerCamelCase keys, e.g. `captureId`, `centerHz`; 64-bit integers as strings). Exit status: 0 on success, 1 on error, 130 when interrupted by Ctrl-C before the verb's live phase (a Ctrl-C that ends a live `tune`/`play`/`fft` session is the normal exit and returns 0), 3 from `daemon status` when no daemon answers. `daemon status --json` always prints a `DaemonInfo`; when the daemon is not running it carries only `socketPath` (no `pid`) and the status is 3. `daemon stop` exits 0 once the socket has stopped answering; under launchd the LaunchAgent uses `KeepAlive.SuccessfulExit=false`, so a clean stop stays stopped while a crash is relaunched.

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
