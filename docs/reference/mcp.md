# MCP adapter reference

`ley mcp` is the Model Context Protocol server: a coding agent or an assistant starts it as a
subprocess, speaks MCP on its stdin and stdout, and through it drives the daemon the way `ley`
does. This page is every tool, what each one takes and returns, the resource, the trust it hands
an agent, and how to configure a client. The design is the [semantic tier](../design/semantic-tier.md)
and the build plan, with where the server lives and why, is
[`docs/plans/mcp.md`](../plans/mcp.md). `ley mcp --help` carries the short version at the prompt.

Transcripts on this page were recorded against the real daemon with the `scan_band.cf32` fixture
attached as a radio (`ley play fixtures/scan_band.cf32 --no-audio --loop --persistent`, then
`ley stop --all`). Ids, model names and levels differ on your machine.

## Running it

An MCP client runs the command `ley` with the argument `mcp`, and `--socket PATH` when the daemon is
not on the default socket. A daemon started by hand logs where it was told, not where `ley daemon
start` writes, so `mcp --log PATH` names that file for `daemon_logs`; without it the tool reads the
default log, which may belong to another daemon. The server exits 3 with the usual sentence when the daemon is not
running, so a client shows that line rather than failing one tool at a time.

```sh
claude mcp add leyline -- ley mcp                      # Claude Code
```

```json
{"mcpServers": {"leyline": {"command": "ley", "args": ["mcp"]}}}
```

The second form is what Claude Desktop, Cursor and most other clients read. Typed at a prompt,
`ley mcp` says on stderr that it is waiting for an MCP client on stdin; Ctrl-C stops it. `--json`
is refused with exit 2: the whole conversation is JSON already.

## What an agent can do, and the trust that implies

The socket has no authentication ([SECURITY.md](../../SECURITY.md), "What the daemon trusts"), and
`ley mcp` hands that surface to whatever started it: an agent can tune, take a radio over, cancel
another client's job. Over stdin and stdout this is the trust a local shell already has, because
anything that can start `ley mcp` could run `ley`. There is no network transport, and none is
planned without a bearer token at minimum; a remote agent waits on the remote-access milestone
(`docs/design/control-plane.md`, "Auth for TCP remote access").

Two guards carry over from the designs. The don't-disturb default is enforced twice: the adapter
refuses to move a radio somebody is listening on and names who, before anything is written, and
the daemon refuses again with its own picture if the adapter's was stale; `take_over: true` is the
only way past either. And nothing here transmits: there is no TX in the contract, and when there
is, an emission lease gates it, never a tool (CLAUDE.md, invariant 11).

Whatever an agent starts without `keep` ends with its conversation. The server holds one event
stream open for its lifetime, which is what makes this process *present* on the daemon
(`docs/dev/engine-internals.md`, "Presence"); a channel `tune` made, or a decode job started without
`keep`, belongs to that presence and is torn down by the daemon five seconds after the server
exits, the way a `ley tune` channel ends at Ctrl-C. `keep: true` makes the channel persistent or
the job kept, and it outlives the agent.

## The shapes

Every tool's result is two text blocks. The first is what the verb would have said on a
terminal: the decisions a tune made, the scan table, one line per record, the squelch that never
opened. The second is the proto3 JSON mapping of the `leyline.v1` messages, the same shape
`ley <verb> --json` prints for the mirror verb (lowerCamelCase keys, 64-bit integers as strings),
and the compatibility test of every tool is that mirror: the fake-daemon tests hold `list_devices`
against `ley devices --json` message for message. An agent reasons over the text and parses the
JSON. Nothing is sent as `structuredContent`, on purpose: the server began by putting the JSON
there with the text beside it, the way the MCP specification suggests, and the first agent evals
showed that Claude Code hands the model only `structuredContent` when there is one and drops the
content blocks ([anthropics/claude-code#55677](https://github.com/anthropics/claude-code/issues/55677)),
so no sentence the tools said had ever reached an agent. Content is what every client shows.

Three results are composites, one message under each key, each still its message's proto3 JSON:
`tune` returns `{capture, channel, sink}` (`sink` is `null` unless `audio` was asked for),
`listen_summary` returns `{channel, transcript, meter, tone}` (`tone` is `null` when no sub-audible
report arrived), and `snapshot` returns the `ley spectrum --json` row, which is the documented
bulk-row exception of the [`ley` reference](cli.md). `listen_summary`'s `meter` is a client-side
statistic over the daemon's `Meter` telemetry with no proto message of its own: `{samples,
min_power_dbfs, max_power_dbfs, mean_power_dbfs, squelch_open_fraction, squelch_db, open_at_end,
open_at_start}`
(snake_case; a level never measured and a squelch that is off are `null`, since JSON has no NaN
and 0 dBFS is a real level; with the squelch off `squelch_open_fraction` is `null` too and the
`open_at_*` flags are false, because a gate that is off is open on every block and "open all the
time" at the noise floor is not traffic). `list_entities` returns the `{"entities": [...]}` object `ley track
--json` prints, described under "Decoders" in the `ley` reference.

A failed call is a tool error whose text is the sentence `ley` would print, with the daemon's
stable code in brackets when there is one (`... [DEVICE_BUSY]`), minus the `ley:` prefix.

## Tools

Frequencies are written as `ley` accepts them: a bare number is MHz (`146.52`), a unit is exact
(`1010k`, `146520000`), and a preset name (`noaa`, `calling`, `ch1`) works where a frequency does.
Device selectors are an id, an id prefix or a row number from `list_devices`. Optional arguments
are optional in the schema; the defaults are the mirror verb's.

| tool | mirror | maps to | arguments | returns |
|---|---|---|---|---|
| `list_devices` | `ley devices` | `Control.ListDevices` | none | `ListDevicesResponse` |
| `get_state` | `ley state` | `Control.GetState` | none | `GetStateResponse` |
| `daemon_logs` | `ley daemon logs` | the log file on the host | `lines` (default 50, at most 500), `include_driver` | `{daemon: DaemonInfo, path, lines: […]}` |
| `tune` | `ley tune` | `CreateCapture`, `CreateChannel`, `WriteParams` | `frequency`; `mode`, `bandwidth`, `squelch`, `gain`, `device`, `audio`, `keep`, `take_over` | `{capture, channel, sink}` |
| `scan` | `ley scan` | `Jobs.StartJob(ScanConfig{once})`, `Jobs.GetScan` | `range` (`144M..148M` or a band name); `dwell_ms`, `min_snr`, `gain`, `device`, `take_over` | `Scan` |
| `listen_summary` | `ley tune`, `ley listen` | `Telemetry.Subscribe`, bounded | `target` (frequency, preset or `chan_…`); `duration_s` (default 10, at most 300), `mode`, `bandwidth`, `squelch`, `gain`, `device`, `take_over` | `{channel, transcript, meter, tone}` |
| `snapshot` | `ley spectrum --json` | `Bulk.Subscribe(FFT)`, one row | `frequency` or `band`; `span`, `bins` (default 1024), `device`, `take_over`, `no_image`, `include_bins` | the spectrum row (`bins` null unless `include_bins`), plus a PNG |
| `list_decoders` | `ley decoders` | `Decoders.ListDecoders` | none | `ListDecodersResponse` |
| `query_records` | `ley records` | `Decoders.QueryRecords` | `protocol`, `job_id`, `device_id`, `kind`, `since_s`, `near` + `radius`, `in_effect`, `limit` | `RecordPage` |
| `list_entities` | `ley track --json` | `Decoders.SubscribeRecords` + the `records.Table` fold | `protocol`; `duration_s` (default 5, at most 300), `since_s`, `device`, `take_over` | `{entities: […]}` |
| `start_decode_job` | `ley decode`, `ley decode --job` | `Jobs.StartJob(DecodeConfig)` | `decoder`; `frequency`, `device`, `take_over`, `keep` | `Job` |
| `record` | `ley record` | `Jobs.StartJob(RecordConfig)` | `target` (frequency, preset or `chan_…`), `duration_s` (**required**, 1 to 3600); `iq`, `gate`, `pre_roll_ms`, `hang_ms`, `mode`, `bandwidth`, `squelch`, `gain`, `device`, `take_over` | the finished `Job` |
| `find_recordings` | `ley recordings` | `Resources.ListResources(RECORDING)` | `kind`, `frequency`, `mode`, `since_s`, `limit` | `ListResourcesResponse` |
| `get_recording` | `ley recordings show`, `ley recordings path` | `Resources.GetResource` + `ResolveLocalPath` | `id` (job id or `ley://recordings/` uri) | `{manifest, directory, parts: [{part, path, samples}]}` |
| `list_jobs` | `ley jobs` | `Jobs.ListJobs` | none | `ListJobsResponse` |
| `get_job` | `ley jobs` | `Jobs.GetJob` | `job` (id, prefix or row) | `Job` |
| `cancel_job` | `ley jobs cancel` | `Jobs.CancelJob` | `job` | `Job` |

Notes a table cell cannot hold:

- **`daemon_logs`** is the one tool that reads the host rather than the daemon: the last lines of
  the log file `ley daemon logs` prints, headed by the daemon's pid and start time from
  `get_state`. Nothing on the socket says why a daemon went away; the log does. A restart also
  shows in `get_state` on its own: `DaemonInfo.pid` and `startedAtNs` change and the event
  sequence starts over. A job started before the restart is gone with it unless it was a decode
  job started with `keep`, which the next daemon brings back as the same job (DEC-11); the rest
  of the durable job store is Milestone D.15. The path is the default log unless `ley daemon start` was given
  `--log`, in which case the tool says which file it read and the agent can tell they differ.
  The radio driver writes to the same file: librtlsdr prints its tuner banner and `PLL not
  locked!` on every device open, and a dozen tunes push every daemon line out of a short tail.
  By default the tool returns the daemon's own lines (the ones in swift-log's shape) and says
  how many driver lines it left out; `include_driver: true` returns everything.

- **`tune`** makes the same decisions `ley tune` makes and lists them in the text: the mode from
  the band unless `mode` is given, the squelch measured from the noise floor for NFM and AM unless
  `squelch` is given (`off` opts out), the gain left alone unless `gain` is given. It plays no
  audio unless `audio: true`, which attaches a system-audio sink on the machine the daemon runs on.
  It refuses to move a radio other channels are listening on: the text names the channels, their
  frequencies and their owners, and ends with the remedy (`take_over: true`, or stop what is
  listening). The refusal is made before any RPC that writes, so a refused call leaves the daemon
  as it found it.
- **`scan`** takes the seconds a sweep takes, owns the radio meanwhile, and declines a radio somebody
  is using with the daemon's sentence and the remedy (`take_over: true`). A detection is a carrier
  that stood above the measured noise floor with the looks that saw it (`looks`/`looksPossible`);
  it is never a protocol or a station, and the text says so, and names the detections fewer than
  half the looks saw, so a one-look blip is not re-swept to find out what the column meant. The text is `ley scan`'s table
  and summary line, band-plan labels included. `min_snr` trims the returned `Scan`'s detections
  the way `ley scan --min-snr` trims its rows, because a 20 MHz sweep is hundreds of detections
  and more JSON than a result budget holds; the whole sweep stays readable as `ley://scans/<id>`
  (below), and the text says how many it left out. A radio with no gain stage (a file device) is
  refused a `gain` in a sentence that names it. The daemon's minute of grace after an interactive
  write ("somebody was tuning this radio 39 s ago") is skipped when the write was this server's
  own earlier tune, listen or snapshot and nobody is listening on the capture: the sweep goes
  ahead, and the text says so, since a take-over that silences nobody is not one. `gain` (a level, or `auto` for where the radio's AGC settles) is where
  the sweep pins the tuner; without it the sweep pins whatever gain the radio was left at, which is
  what made two sweeps of one band differ by 6 dB of floor in the survey, and `Scan.gains` says which
  either way.
- **`listen_summary`** subscribes to the channel's meter, squelch and sub-audible telemetry for
  `duration_s` and folds it. A transmission is a squelch-open interval, reported from the daemon's
  own close edge as an `ActivitySegment` (start and end on the capture's timeline, `peakDbfs` the
  loudest block, `meanDbfs` the mean of the meter readings while open), so the default squelch is
  `auto` for voice modes as `ley tune`'s is; with `squelch: off` there are no edges and the meter
  statistics are the answer. A close edge with no open edge before it in the window is the
  squelch having been open when listening began (a channel made with the squelch off starts open,
  and the threshold written a moment later closes it on the first quiet block), not a
  transmission this call observed: it is reported as `meter.open_at_start` and never as a
  segment. A squelch that never opened while the loudest reading sat within 3 dB under it is
  said to be a steady signal just under the auto squelch's margin, with `squelch: off` as the
  remedy, since "0 transmissions" on a weak carrier was read as an empty channel. Given a channel id it taps a channel already running and refuses the tune arguments,
  as `ley listen chan_…` does. A channel it made is removed when it returns.
- **`snapshot`** draws one FFT row as a PNG (`image/png` content, beside the text) and returns the
  row as numbers. The plot is one pixel per negotiated bin on a dark ground: the trace, a dashed
  floor line, a dB grid, the loudest bins marked with their frequencies, and the frequency asked
  for marked under the axis. Columns take the level ramp of `docs/dev/cli-style.md` section 3a,
  the same five stops the terminal chart uses, so a level is the same colour in both. `peaks` are
  local maxima at least 15 dB over the row's median, presentation only; `scan` is the detector.
  Like `ley spectrum` it reuses a capture that covers the frequency, refuses to move one others
  are listening on, and removes a capture it made. `no_image: true` returns the numbers alone,
  and `bins` is `null` unless `include_bins: true`: a row of 1024 numbers is a page of JSON an
  agent rarely reads (a 2048-bin survey was 39 KB), and the floor, the peaks and the text say
  what stood out. Given a frequency, the text also says what the row reads there (the loudest bin
  within a voice channel of it and its margin over the floor), because the peaks have a 15 dB bar
  and a carrier 6 dB up was read as nothing on the frequency.
  A band wider than the radio captures (the FM broadcast band is 20 MHz; an RTL-SDR captures
  3.2 at most) is shown centred, and the text says which frequencies the row covers and what
  share of the band that is; a radio that captures wider shows more at once, and `scan` sweeps
  the rest. A band group whose parts sit apart (`gmrs` is two halves 5 MHz apart) is refused
  with the parts named rather than centred on the spectrum between them.
- **`list_entities`** renders a decode job already running for the protocol rather than starting
  a second demodulator on the radio, replaying the records that job retained (up to 256) before
  listening for `duration_s`; with none running it starts one for the call and stops it after.
  Rows age out after the decoder's own `entity_silence_s`, and `since_s` seeds the table from kept
  records, as `ley track --since` does.
- **`query_records`** says why a page is empty, because an empty page reads the same for a quiet
  band and for a decoder that was never storing. The daemon cannot tell the two apart; the job
  list can. The text names which it was: the job (or every decode job for the protocol) was
  started without `keep`, so its records stayed on the live stream; no kept decode job for the
  protocol has run, so there was nothing to search; or a kept job exists and wrote nothing, in
  which case the band may be quiet or the decoder may hear nothing, and `listen_summary` on the
  job's channel is how to tell, since it reports whether audio is flowing without any decoder in
  the way.
- **`start_decode_job`** without `keep` runs while the server does and its records reach
  `list_entities` only; with `keep` the job runs on, its records are stored, and `query_records`
  (or the resource below) reads them. An alias a manifest lists (`vessels` for `ais`) resolves to
  the canonical decoder before the job starts, as `ley decode vessels` does.

- **`record`** is the one tool that waits: it starts the job, waits for it and returns the
  finished `Job`, so one call answers "record ten seconds and tell me what you got" instead of a
  start and a poll. `duration_s` is required and bounded at an hour — what an agent starts must
  end without it, and a radio recording for ever is a radio nobody else can use. `gate: "squelch"`
  records only while something is on the air and writes one file per exchange, so a quiet band
  costs no disk; the text then says how many times the squelch opened, which is usually the
  question. The recording outlives the call and the server: it is a file, and `find_recordings`
  finds it in the next session.
- **`get_recording`** returns the manifest and every part's path on the daemon's machine, never
  the samples. Audio and IQ do not cross this connection (`docs/design/data-planes.md`, "no
  lossless network stream"); an agent that wants to transcribe a recording hands the path to a
  tool that can open it, and an agent on another machine cannot, which is the honest answer.

What the job list says: a decode job reads `RUNNING` whether the decoder is producing records or
not, by design (`docs/plans/decoders.md`, DEC-16: a silent decoder is indistinguishable from a quiet
band, and SAME is silent by design), and a decoder that exits is restarted with the job saying so
in `statusDetail`. The same field carries the job's liveness (DEC-23): "decoding with aprs: 12
records, last 3 s ago", or "no records yet", refreshed every two seconds while records arrive, so
`get_job` and `list_jobs` tell a decoder that is hearing things from one that is not.

Not registered, because the daemon cannot back them yet: `get_transcript` (audio-transcript watch
jobs, D.15), `identify_signal` (the honest characteriser, DEC-14), `lookup_identity` (no external
lookup adapters exist) and `whats_out_there` (needs `identify_signal`). The server's instructions,
which an MCP client shows the agent at connect time, say the same, so an agent does not go
looking.

## Resources

Three resource templates are served, all `application/json`. `ley://recordings/{job_id}` is a
recording's manifest as `recording.json` holds it: the radio and gain it was made on, its parts
with their span on the capture's timeline, the times nothing was recorded and why, and how it
ended. It is on disk and outlives the daemon; `get_recording` returns the same document with each
part's local path added. `ley://records/{job_id}` is the
records of a decode job started with `keep`, as the `RecordPage` `query_records` returns for
that `job_id`; a job the store never had is a resource-not-found error, and a kept job that has
heard nothing yet is an empty page. `ley://scans/{scan_id}` is the whole `Scan` a sweep produced,
every detection included, resolved through `Jobs.GetScan`: what a job's `resultUris` names and
what the `scan` tool returns before `min_snr` trims it. It lives as long as the daemon remembers
the job (its last sixteen finished ones) and not across a restart, because a scan is not yet a
stored resource. Snapshots become resources when their store is built (`docs/plans/mcp.md`,
MCP-7).

## A recorded exchange

What crosses stdin and stdout, newline-delimited JSON-RPC, trimmed to the parts an agent reads.
The client asked for the tool list, then `list_devices`, then a scan of the 2 m band; the fixture
carries carriers at 145.2, 145.6, 146.4 and 146.8 MHz.

```console
$ ley --socket /tmp/ley-mcp-rec.sock mcp
→ {"jsonrpc":"2.0","id":2,"method":"tools/list"}
← {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"cancel_job",…},{"name":"get_job",…},{"name":"get_state",…},
   {"name":"list_decoders",…},{"name":"list_devices",…},{"name":"list_entities",…},{"name":"list_jobs",…},
   {"name":"listen_summary",…},{"name":"query_records",…},{"name":"scan",…},{"name":"snapshot",…},
   {"name":"start_decode_job",…},{"name":"tune",…}]}}
→ {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_devices","arguments":{}}}
← {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"scan_band.cf32 (file, serial 04424b881c48893a) available, tunes 146.000 MHz"},
   {"type":"text","text":"{\"devices\":[{\"deviceId\":\"dev_01K…\",\"driver\":\"file\",\"model\":\"scan_band.cf32\",…}]}"}]}}
→ {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scan","arguments":{"range":"145M..147M","dwell_ms":300}}}
← {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":
   "FREQUENCY    WIDTH            SNR (dB)  SEEN  BAND\n145.200 MHz  5.954 kHz              66   2/2  2 m amateur\n145.398 MHz  under 2.344 kHz         4   1/2  2 m amateur\n145.600 MHz  6.182 kHz              58   2/2  2 m amateur\n146.400 MHz  under 2.344 kHz        52   2/2  2 m amateur\n146.805 MHz  187.624 kHz            35   2/2  2 m amateur\n5 signals, floor -88 dBFS per 2.344 kHz bin\n  ley listen 145.2"}],
   {"type":"text","text":"{\"scanId\":\"scan_01K…\",\"config\":{…},\"detections\":[{\"centerHz\":\"145200000\",\"bandwidthHz\":5954,\"snrDb\":66.…,\"looks\":2,\"looksPossible\":2,\"floorDbfs\":-88.…},…],\"noiseFloor\":[…],\"resolutionHz\":2344,\"covered\":{…}}"}]}}
```

The 145.398 MHz row, seen once in two looks at 4 dB, is the detector reporting what it saw and
the reader's to weigh; nothing filtered it (`docs/design/scan.md`).
