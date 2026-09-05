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
├── devices                          # list; --watch for hot-plug events
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

Deliberate omissions at v0: no remote flags (UDS-only), no TX verbs, no decode verbs (arrive with digital modes).
