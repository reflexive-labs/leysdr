# Agent evals

How an agent's use of `ley mcp` is measured without a radio or a person on the air. `leyeval`
stands up a daemon per scenario, plays recordings as radios, points an agent at the MCP server on
that daemon, and grades what it answered and how it got there. This page is for whoever adds a
scenario or reads a run; the adapter itself is [`docs/reference/mcp.md`](../reference/mcp.md).

## Why fixtures

Every scenario's truth is known before the agent starts, because the radios are recordings: the
sweep fixture has carriers at 145.2, 145.6, 146.4 and 146.8 MHz, the APRS fixture carries three
stations, the NOAA capture has no PL tone and the handheld's has one at 100 Hz. Nothing depends on
what is on the air, so a run is reproducible and two runs are comparable; only the agent varies.
The recordings go in under neutral names (`radio-a`), with a sidecar that holds only format, rate
and centre, because a fixture's filename and description would give away the answer.

## Running

```sh
make eval                                   # every scenario, MCP tools only
make eval EVAL_ARGS="survey-2m --mode shell" # one scenario, with a shell the agent may fall back to
go run ./cmd/leyeval show evals/runs/<run>/survey-2m | less
```

`make eval` builds `ley` and the daemon, then runs `leyeval run` with the fixtures and decoders
wired up. Each scenario's daemon starts with `--no-hardware`, so a dongle plugged into the
machine stays out of the run: without it, an agent that tunes "146.52" with no device named can
use the machine's own radio and spend calls noticing and undoing it. A run costs tokens, so it is not part of `make check`. The agent is `claude` on `PATH`
in headless mode (`-p --output-format stream-json`), which needs a credential on the machine
running it; `--claude` or `LEYEVAL_AGENT` names another command, which receives the same flags
and the prompt on stdin. `--model` passes through.

Two modes. `mcp` allows the leyline tools alone and disallows the host's, which tests whether the
tools suffice for the task. `shell` allows a shell beside them and counts how often the agent
left the tools for `ley` on the host, which is the number to drive down: every detour is a gap in
the adapter (the survey that found the phantom segments, the driver noise and the unfetchable
scans was one).

## What a run leaves

Each run makes `evals/runs/<timestamp>/<scenario>/` (gitignored) holding:

- `transcript.md`: the checks with their verdicts, the task, then the conversation in order with
  every tool call, its arguments and what came back, long results folded. This is the page to
  read first. `leyeval show <dir>` renders it again, and `leyeval show <any messages.jsonl>`
  renders a stream saved by any means, results and all.
- `messages.jsonl`: the agent's stream, one JSON object a line, untouched.
- `prompt.md`, `mcp.json`, `leylined.log`, `radios/`: what the agent was given, how it was pointed
  at the daemon (`ley mcp` with the run's socket and `--log` on the run's log, so `daemon_logs`
  reads this daemon and not the machine's), the daemon's log, and the recordings under their
  neutral names.
- `store/` and `recordings/`: the daemon's decode-record store and the recordings any `ley record`
  in the scenario made. They are never the machine's own.
- `result.json`: the verdicts and the metrics (tool calls by tool, host calls, tool errors, turns,
  duration, cost).
- `socket.txt`, only when the run directory's path is too long for a Unix socket (about 100
  bytes): the daemon's socket went in a short temp directory instead, and this file records where.

The summary table at the end has one line a scenario: passed, failed, tool calls, host calls,
cost. A scenario whose fixture is not on the machine is skipped with a message; a harness failure (the
daemon would not start) is an error, not a failed check.

## A scenario

One YAML file under `evals/scenarios/`. `leyeval check` parses them all and prints what each
grades without running anything.

```yaml
name: survey-2m
description: Sweep 145 to 147 MHz on a radio playing four known carriers and report every one.
fixtures:
  - file: scan_band.cf32   # relative to fixtures/, or absolute; cf32 or cu8, sidecar beside it
    as: radio-a            # the model name the agent sees
    capture: false         # leave the radio idle (default: tune it to the recording's centre)
    optional: false        # true skips the scenario when the file is missing, for local captures
    center: "144.39"       # tell the radio it is here rather than at the recording's centre (noise has none)
setup:                     # after the fixtures, before the agent
  - ley: ["tune", "146.52", "--persistent", "--no-audio"]
  - job: {decoder: aprs, frequency: "146.62", keep: true}
task: |
  One radio is attached. Find out what is transmitting between 145 and 147 MHz ...
answer_schema: |
  {"carriers": [{"hz": <integer, Hz>, "snr_db": <number>}], "summary": "<one sentence>"}
truth:
  carriers: [145200000, 145600000, 146400000, 146800000]
checks:
  - type: json_within
    path: carriers
    field: hz
    truth: carriers
    tolerance: 30000
    exact: true
    why: all four carriers, none invented
max_turns: 25            # optional; the runner's default otherwise
mode: mcp                # optional; overrides the runner's
```

The agent is given the task, the mode's rule, and the answer schema with the instruction to end
its answer with one JSON block in that shape. The `json_*` checks read that block; the others
read the tool calls and the prose. `why` is printed beside the verdict, so a reader of the
transcript learns what the check was for without opening the scenario.

### Check types

| type | reads | parameters | passes when |
|---|---|---|---|
| `answered` | the answer | | the answer ends with a JSON block that parses |
| `json_equals` | the answer | `path`, `truth` or `value` | the scalar at the path equals the expectation (numbers as numbers, strings case-folded, `null` allowed) |
| `json_set_equals` | the answer | `path`, `field`, `truth` or `values`, `exact` | the list at the path (each entry's `field`, when given) holds every expected value; `exact` also forbids extras |
| `json_within` | the answer | `path`, `field`, `truth` or `values`, `tolerance`, `exact` | every expected number matches one entry within the tolerance, each entry used once; `exact` also forbids extras |
| `require_words` | the prose | `words` | every word appears, case-insensitively |
| `forbid_words` | the prose | `words` | none appears |
| `used_tool` | the calls | `tool` (short name: `scan`) | the tool was called at least once |
| `used_one_of` | the calls | `values` (tool names) | any of them was called |
| `not_used_tool` | the calls | `tool` | the tool was never called |
| `max_tool_calls` | the calls | `n` | at most `n` tool calls of any kind (the client loading tool schemas through `ToolSearch` is not one; the transcript shows it in italics and `result.json` counts it as `harness_calls`) |
| `no_shell` | the calls | | no call left the MCP tools for the host (`Bash`, the file tools) |
| `no_tool_errors` | the results | | no tool call came back as an error |
| `take_over_after_refusal` | calls and results | | `take_over: true` was sent only after a result that refused and said so |

Adding a check type is one entry in `checkers` in `go/internal/eval/checks.go`: a function from
the check, the scenario, the log and the parsed answer to a verdict. `Check`'s fields are the
union of what every type reads, so a new type needs no new schema unless it needs a new kind of
parameter.

## The scenarios so far

| scenario | fixture | proves |
|---|---|---|
| `survey-2m` | `scan_band` idle | the four carriers are found with `scan` and called carriers, not services |
| `aprs-stations` | `aprs_afsk` tuned | the three stations come from a decoder's records, with positions |
| `dont-disturb` | `nfm_tone` with a channel listening | asked to look elsewhere, the agent reports the refusal and who is listening, and never takes over first |
| `quiet-or-broken` | `noise_floor` with a kept APRS job on it | an empty store is explained and `listen_summary` shows a live channel at the floor: the chain works and the band is quiet |
| `pl-tone-absent` | `rf-captures/noaa-wx2-auto` (local) | no PL is reported on a station that sends none |
| `pl-tone-present` | `ht-narrow` (local) | the handheld's 100 Hz PL is reported |
| `dcs-code-present` | `rf-captures/ht-dcs-754` (local) | the GMRS handheld's DCS 754 is named, normal, with no PL tone invented |
| `dcs-code-absent` | `ht-narrow` (local) | asked for a tone or a code, the agent names the 100 Hz PL and no DCS code. `pl-tone-absent` already covers a station that sends neither |
| `record-squelch-opens` | `nfm_keyed` tuned | a gated recording is made and the three transmissions counted. The count comes from the manifest's `squelch_opens`, not from the part count: at the default 5 s hang the fixture's 3 s gaps keep all three overs in one part, so an agent that counts parts answers 1 |

No scenario covers a restart mid-task because the runner has no restart hook. A live `rtl_tcp`
tier would have no fixed expected answer and can report metrics only.

## What to keep out

- Truths that depend on the clock. Fixtures loop, so "how many packets in the last minute" is
  not stable; "which stations" is.
- Frequencies outside a fixture's centre. A file device tunes only where it was recorded, so a
  task that needs the radio moved fails with `FREQ_OUT_OF_RANGE` before the agent has done
  anything wrong. `dont-disturb` relies on the refusal coming first, which it does.
- Checks that need a judge. Everything here is a string or number comparison, so a verdict is
  the same on every run of the same log.
