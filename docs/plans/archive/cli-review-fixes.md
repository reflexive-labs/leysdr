# CLI review fixes (v0)

Source: the CLI-focused code review of `main` at `7e75220`. The review's report and machine-readable findings
lived under an ephemeral `/tmp` run directory that no longer exists; finding numbers `#N` below are kept only
because the commit messages that closed them cite those numbers. Scope: every P1-P3 primary finding plus the
agent-native gaps. Same loop as the engine fixes: one commit per work item, verified independently, `make
check` green on both hosts. Each work item lists its findings and the why/suggested fix for each.

Status legend: `[ ]` pending, `[x]` done, `[-]` dropped with reason.

## Decisions

- **`--json` on destructive verbs (#25, agent-native detach warning).** `stop`, `stop --all` and `devices detach`
  print the daemon's `Empty` response (`{}`) under `--json`; the exit code carries success. No stale or invented
  object is echoed. docs/reference/cli.md states this.
- **`version --json` (#27).** Documented as the second named exception to the proto3 mapping (keys `version`,
  `go`, `os`, `arch`), emitted through encoding/json (not `%q`) and pinned by a golden test. No proto message for a
  client-local value.
- **`spectrum --span` (#7).** The span is the capture width. For a fresh capture the CLI snaps the requested span to
  the nearest rate the device supports and says so on stderr ("showing 2.4 MHz, the closest this radio can do to
  200 kHz"); on an existing capture whose rate differs it exits 2 with a message naming the current width and
  `ley stop all`. Help and cli-guide say this.
- **Audio for agents (agent-native critical).** A `ley listen <sel|freq> [--format json|bin]` verb mirrors `ley fft`
  and streams the channel's decoded audio via the client library's SubscribeAudio; audio rows are added to the
  documented bulk-row exception in docs/reference/cli.md. `ley presets` and `ley bands` list the client-local tables,
  with `--json` arrays documented as client-local data.

## Work items (dependency order)

### CLI-1 `[x]` JSON on stdout and exit status under --json (#8, #24, #25, #3, #1, #27)

- #8 stop.go:120/143: both early-return sentences go to stderr, or nothing under `--json`; exit 0.
- #24 set.go:490: detect WriteRejected before the JSON branch; under `--json` print the event line, then exit 1
  (ExitError with an empty message, the daemonStatus convention); without `--json` unchanged.
- #25 stop.go:83 and stopAll: print the daemon's Empty response under `--json` (see Decisions); devices detach already does.
- #3 devices.go:90: `--watch --json` prints the wrapped ListDevicesResponse first, then Event lines; document the two shapes.
- #1 daemon.go: `start`/`stop` under `--json` print the same DaemonInfo-shaped JSON `status` prints (after the
  action, from a fresh GetState; for stop, the last known info with pid); `install`/`uninstall`/`logs` reject
  `--json` as a usage error (exit 2).
- #27 version.go: encoding/json output of the four keys; golden test; docs/reference/cli.md exception paragraph.
- Tests: fake-backed CLI cases for each (idle `stop --all --json` has empty stdout; `set --json` rejection exits 1
  with the event on stdout; `stop --json` prints `{}`; `devices --watch --json` first line is the wrapped list;
  `daemon start --json` output parses as DaemonInfo; `version --json` golden).

### CLI-2 `[x]` Exit codes and interruption (#9, #29, #23)

- #9 tune.go: wrap resolveTuneTarget's three error returns and tuneFlags.parse's flag errors in usageError; rows
  in TestExitCodesUsage for `tune`, `tune 146,52`, `tune nooa`, `tune 146.52 --mode morse`, `play x.cf32 --freq 1,1`.
- #29 leyline.Error gains a `cause` set in FromStatusWithTrailer and `Unwrap()`; exitStatus treats
  `Code == "CANCELED"` under a cancelled ctx as ExitInterrupted (130); main_test case.
- #23 play.go:78: os.ErrNotExist -> fileMissing(...) wrapped in usageError (exit 2), other stat errors unchanged; test.

### CLI-3 `[x]` Daemon lifecycle management (#2, #22, #21, #20, #12, #19, #17)

- #2 daemonStatus routes the State error through app.notRunning; non-UNAVAILABLE codes exit 1 with `[CODE]`.
- #22 daemonStop (no launchd): when readPid() is 0, probe the socket first; take the pid from State().Daemon.Pid;
  only reportNotRunningForStop (which unlinks) when unreachable.
- #21 daemonStart: re-check readPid()+reachable() before spawning (daemonInstall's ordering); after cmd.Start(),
  write the pidfile only once the child answers on the socket (bounded wait), otherwise SIGTERM+wait it and fail.
- #12 on pidfile write failure SIGTERM and wait for the child before returning the error.
- #20 stopPid: when the socket answers require State().Daemon.Pid == pid; otherwise `ps -o comm= -p <pid>` (argv,
  no shell) must be leylined; on mismatch remove the stale pidfile and report not running.
- #19 plist(): escape bin/socket/log with encoding/xml EscapeText; filepath.Abs for socket and log in daemonInstall;
  golden test with `&`, `<`, `>` in each path.
- #17 socket.go: DefaultPidPath/DefaultLogPath derive `.pid`/`.log` from the socket's own base name (so the
  non-darwin fallback yields /tmp/leyline-<uid>.pid|.log); tests for darwin and non-darwin naming.
- Tests: extend play_daemon_test's real-spawn harness for #21/#22/#12 where feasible; unit tests for the helpers.

### CLI-4 `[x]` Session cleanup and shared captures (#14, #26, #4, #15)

- #14 teardown(): report non-NotFound errors from DestroyChannel/DestroyCapture on stderr with `ley stop --all`
  as the recovery; same for play's DetachFileDevice.
- #26 telemetryPump: reuse the client library's pump pattern (io.EOF -> clean end, ctx error -> ctx error);
  print one stderr line when the daemon closes the stream; test by cancelling the fake's Serve context.
- #4 ParseSquelch: lower bound -200 dBFS (the daemon's rule); createChannel awaits the initial squelch/gain writes'
  confirmation and treats a WriteRejected as a tune failure (tear down what tune created, exit 1); test.
- #15 openSession: subscribe WatchEvents with the snapshot's seq so no event is missed (docs: reconnect = GetState
  + resume from seq); every verb drains the event stream while running; before DestroyCapture, refresh state and
  skip the destroy when other clients' channels remain (report it on stderr). Test with a second client adding a
  channel after the session opened.

### CLI-5 `[x]` Selectors and parsing (#6, #13, #5, #33)

- #6 resolveTarget: explicit --channel and --capture that disagree (channel.CaptureId != capture.CaptureId) are a
  usage error naming both ids.
- #13 format.go: delete channelFreq; call leyline.ChannelFrequency; test with a negative absolute frequency.
- #5 resolveTarget takes a verb-specific hint and example (set: `--channel N`; stop: bare `N`); stop's message
  shows `ley stop 2`.
- #33 ParseFrequency: no comma/underscore stripping; doc comment says Hz-strict; ParseUserFrequency unchanged; tests.

### CLI-6 `[x]` Fake daemon fidelity and stream delivery (#11, #10, #16)

- #11 writes.go:156: drop the channelFits half of the bandwidth guard (bandwidth > 0 stays); add the stored-write
  test (bandwidth/mode/squelch on OUT_OF_CAPTURE, applied on re-entry) mirroring the daemon's.
- #10 fake AttachFileDevice opens and validates the file like the daemon (regular file, sidecar present and its
  sample_rate within 1 kHz..100 MHz, else INVALID_ARGUMENT/DEVICE_IO with the daemon's codes); the stream loop
  counts samples from the file's size and, without loop, marks the device DISCONNECTED and its capture
  CAPTURE_DETACHED at EOF; tests for a bad file and a non-loop EOF.
- #16 client library: SubscribeFFT requests GAP_MARKED (audio and IQ stay LATEST_WINS), so the documented fft gap
  line is reachable; test `ley fft --format json --count 55` against the fake and assert the gap line; docs.

### CLI-7 `[x]` Docs, leyfix coverage and the span decision (#18, #30, #7)

- #18 docs/guide/using-ley.md: append ` [FREQ_OUT_OF_RANGE]` / ` [DEVICE_BUSY]` to the two example lines.
- #30 leyfix_test: generate+check am_tone, wfm_tone and two_nfm individually via `--only` at a rate that fits.
- #7 spectrum: implement the Decisions entry (snap for a fresh capture with a stderr note; exit 2 on an existing
  capture with a different width); update the flag help, docs/guide/using-ley.md and the spectrum golden.

### CLI-8 `[x]` Agent parity: `ley listen`, `ley presets`, `ley bands`

- `ley listen <sel|freq> [--format json|bin] [--count N] [--rate/--mode as tune]`: resolves like tune (creating a
  capture/channel when needed, no system-audio sink), subscribes AUDIO via the client library, writes NDJSON rows
  `{seq, sample_index, sample_rate, format, pcm(base64)}` or raw PCM frames (`bin`), ends on --count or Ctrl-C
  (exit 130), tears down what it created. Document the row shape as part of the bulk-row exception in
  docs/reference/cli.md; add it to docs/guide/using-ley.md and `ley help scripting`; remove any roadmap stub it supersedes.
- `ley presets` and `ley bands`: tables from Presets()/Bands(); `--json` prints arrays (documented as client-local
  data in docs/reference/cli.md). `ley help presets` keeps its prose.
- Tests: fake-backed listen test asserting rows and teardown; golden help files for the new verbs.

## Closing

Done on 2026-09-09, commits 97d9bb1..067bb7f (one per work item, each verified by an independent reviewer before
landing). Gate at 067bb7f, run in the container:

- Swift: `swift build` clean; `swift test` 137 tests, 0 failures (125 before this plan; the engine gained the
  event-replay tests CLI-4 needed).
- Go: `go build ./... && go vet ./... && go test ./...` green; `make lint` 0 issues; `gofumpt` clean.
- Generated code: `scripts/gen-proto.sh` produces no drift (the one proto change below is regenerated and committed).
- e2e (real `leylined` + Linux `ley`): 2/2 pass.
- Smoke test of the new verbs against the real daemon with `fixtures/nfm_tone.cf32`: `ley listen <chan> --format json`
  returned 20 NDJSON rows at 48 kHz S16 with monotonic seq and real audio (peak 8085/32767), `--format bin` returned
  the matching raw PCM, `ley presets --json` and `ley bands --json` returned 10 and 14 entries, and listening on
  another client's channel left that channel ACTIVE.

### Wire change

CLI-4's #15 (no event may be missed between the state snapshot and the event stream) had no wire support: `EventScope`
carried no resume point. `optional uint64 since_seq = 3` was added, plus a 256-event retained window in both the real
daemon and the fake, and the control-plane docs now state that reconnect = GetState + resume from that seq. Additive
within v1, generated code regenerated, both daemons and the Go client updated together.

## Follow-ups noted while implementing (not in the review's primary set)

- `fakedaemon.Options.WriteAwaitsWatcher`, added in CLI-1 to make a rejection test deterministic, is redundant now
  that `since_seq` closes the same window; drop it and the one test that opts in.
- `ley listen` ends on Ctrl-C with exit 0, not the 130 this plan first wrote: 130 is documented as "interrupted before
  the live phase began" and every other live verb exits 0, so listen was added to that list in the docs instead.
- `ley listen` takes a frequency, a preset or a `chan_` id, but not a channel row number (a bare number is a
  frequency there). Decide whether row numbers should work for it the way they do for `--channel`.
- listen skips two stderr notes tune prints while resolving the same argument (the kHz-typed-as-MHz warning and the
  "using NFM: <reason>" line); cosmetic, but they should probably match.
- The fake daemon detects file EOF inside its bulk-stream loop, so a non-loop capture with no open stream never
  detaches; the real daemon's I/O thread hits EOF regardless. A per-capture timer in the fake would close the gap.
- `buildChannelWrites`/`showSettings` still take a `cap` parameter that is unused on some paths after CLI-5.
- The `ps -o comm=` identity check (#20) is only exercised on its negative path in tests; a hung real `leylined`
  with no socket answer is hardware-in-the-loop territory.
