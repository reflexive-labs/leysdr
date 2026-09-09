# CLI visuals

Make `ley` look like a finished tool. Source: the visuals audit (2026-09-09, six passes:
terminal capabilities, static screens, live verbs, the spectrum showpiece, daemon/help/errors,
and a constraints-and-seams map). The contract every item follows is `docs/cli-style.md`; read it
first, it is short and prescriptive.

Status legend: `[ ]` pending, `[x]` done, `[-]` dropped with reason.

## Decisions

- **No styling dependency.** The palette is the 16 ANSI names plus bold and dim, tables stay on
  `text/tabwriter`, and the only layout maths needed is visible-width padding. Measured against
  that: lipgloss v1 costs 1.71 MiB for capabilities we would use a twentieth of, and lipgloss v2
  moved to a vanity module path and emits truecolor from `Render()` unconditionally, staying safe
  only if every write goes through its writer, which inverts this CLI's "stdout is parseable"
  contract across dozens of `fmt.Fprintf(app.Stdout, ...)` call sites. So `go/internal/ui` is
  ours, standard library only. If a Bubble Tea dashboard lands later it brings lipgloss with it
  and `ui`'s six ink methods are the seam to re-implement.
- **16 colours, never 256 or truecolor.** The user's terminal theme resolves them, so output is
  right on a light Terminal.app profile and a dark iTerm2 one without querying the terminal.
- **Colour is decided per stream.** stdout and stderr are resolved separately so
  `ley state | grep chan_` keeps coloured prose on the terminal and clean text in the pipe.
- **`ley state` becomes a tree.** Four flat tables joined by repeated ULIDs become device to
  capture to channel to sink by indentation; `--wide` keeps a flat table for large states.

## Work items

### UI-0 `[x]` The `ui` package (foundation; everything else depends on it)

- New package `go/internal/ui`, standard library only, implementing section 7 of
  `docs/cli-style.md` exactly: `Style` with `Color`/`Unicode`/`Width`, the six ink methods
  (`Label`, `Muted`, `Ok`, `Warn`, `Err`, `Cmd`), `Glyphs()`, `Pad`, `Truncate`, `Bar`, `Ramp`,
  `Rule`, and the package functions `Visible` and `Strip`. Zero value is plain, ASCII, unknown
  width, and every method on it is the identity function.
- `Resolve(Options) Style` implements the colour chain and the width chain from sections 2,
  including the `--color`/`--ascii`/`--width` inputs, `NO_COLOR`, `CLICOLOR_FORCE`, `CLICOLOR=0`,
  `TERM`, per-stream isatty, `COLUMNS`, and the `[40, 160]` clamp. Options carries an env lookup
  and the two isatty results so it is testable without a pty.
- `App` (root.go) gains `Style ui.Style` for stdout and `ErrStyle ui.Style` for stderr, resolved
  once in `NewRootCommand` beside the existing `IsTTY`/`TermWidth` defaulting; `--color` and
  `--ascii` are persistent flags; `--json` and the bulk paths force colour off on stdout. Tests
  that build an `App` literal keep getting the zero value, so every existing golden passes
  unchanged.
- `App.table()` styles the header row through the resolved style.
- Tests: the identity property of the zero value; `Visible`/`Strip`/`Pad`/`Truncate` against
  strings with SGR and with wide runes; `Bar` and `Ramp` at the boundaries (0, 1, out of range);
  the full colour chain as a table test (every row of section 2); the width chain including the
  pty-reports-zero case and the clamp; and one test asserting `Strip(styled) == plain` for a
  sample of each ink method.
- Nothing else changes: no verb is restyled in this item. The gate must be green with the package
  in place and unused by callers apart from `table()`.

### VIS-1 `[x]` Orientation, state and version

Files: `root.go` (renderOrientation), `state.go`, `format.go`, `version.go`.

- Bare `ley`: `Label` the `Daemon`/`Devices`/`Playing` column, `Muted` the diagnostics (pid,
  socket, serial, trailing ids), `Cmd` the commands in the `Next:` block with their explanations
  `Muted`. Wording stays byte-identical (docs/interfaces.md pins it). Piped, print the
  orientation block rather than the help screen.
- `ley state`: render device to capture to channel to sink as an indented tree using the tree
  glyphs; each level names only what is new, so the repeated ULID columns disappear. Units go in
  the labels (`offset +100 kHz`, `bw 12.5 kHz`), state words take `Ok`/`Warn`/`Err` ink, ids are
  `Muted`. Keep a flat table behind `--wide`. `--json` is untouched.
- `ley version`: no visual change beyond `Label` on the field names; `--json` untouched.

### VIS-2 `[x]` Devices, presets and bands

Files: `devices.go`, `tables.go`.

- `ley devices`: lead with `MODEL`, then `STATE` with `Ok`/`Warn`/`Err` ink, then `RANGE`,
  `RATES`, `GAIN`; move `ID` and `SERIAL` right or behind `--wide` with the full id always
  reachable. Ranges read `24.000 MHz to 1.766 GHz`; absent values are `-`. Mark a device flagged
  `held_externally` as `IN_USE (other program)` in `Warn`. Header row `Label`.
- `ley presets` / `ley bands`: drop the frequency restated in the description, `Muted` the
  aliases, group the `noaa*` family and the amateur bands under `Label` sub-headings. `--json`
  arrays keep every field including the full description.

### VIS-3 `[x]` Live verbs: tune, play, listen, set, stop

Files: `tune.go`, `play.go`, `listen.go`, `session.go`, `set.go`, `stop.go`, `format.go`.

- The live meter becomes a level bar: fixed width scaled floor to 0 dBFS with a marker at the
  squelch threshold, the `audio`/`muted` word in `Ok`/`Warn`, the dB number plain. Wrap the
  existing golden-tested string in the TTY branch rather than replacing it, and gate the `\r`
  redraw on the stderr TTY: piped, emit newline-terminated lines throttled to one per second.
- `tune`/`play` banners become a `Label`-aligned block: frequency, mode, device, gain, squelch,
  each on its own line, ids `Muted`, the "Ctrl-C stops" hint `Muted`. Same words.
- `set` confirmations show old to new with the previous value `Muted`; drop the repeated trailing
  `chan_` id and keep `(channel N)`. The no-argument view groups channel, radio and sink.
- `stop` and the ambiguity picker: bold the row number, `Muted` the shared id prefix, and give the
  picker a discriminating column (frequency and mode) so rows differ by something human.
- Interrupted live verbs print one closing line on stderr saying what happened to the radio
  ("stopped; channel removed, radio free", or the surviving id under `--persistent`), suppressed
  under `--json`, exit code unchanged.

### VIS-4 `[x]` Spectrum showpiece and fft

Files: `spectrum.go`, `fft.go`.

- Chart: replace `#`/space with the eight-block ramp, dim everything within 6 dB of the noise
  floor, draw the floor as a rule, and label the level axis at three points with `dBFS` once.
- Peaks: raise the detection threshold above median+6 dB, allow fewer than five, and lead with the
  strongest peak's margin above the floor. `--json` gains `floor_db` beside `peaks`.
- Axis: real tick marks with the count scaled to width, labels on round frequencies, and a marker
  under the frequency the user asked for.
- `--watch`: freeze the dB scale across frames with a one-time visible re-scale when a signal
  exceeds it, erase to end of line on redraw, hide and restore the cursor, and add a dim max-hold
  trace. A status line carries frame count, rate and elapsed, and says `waiting for data` when the
  stream has produced nothing.
- One next-step line after a one-shot chart (`tune with: ley tune 146.624`) in `Cmd` ink.
- `ley fft --format bin` refuses to write binary to a terminal.
- Every chart line stays within the resolved width; test at 40, 80 and 160 columns.

### VIS-5 `[x]` Daemon, help and errors

Files: `daemon.go`, `topics.go`, `root.go` (help), `cmd/ley/main.go`.

- `ley daemon logs`: on a TTY, dim the repeated date, show one dimmed subsystem token, colour the
  level, and align the message; fall back to verbatim passthrough for any line that does not
  parse and when piped.
- `ley daemon status`: `Label` the field column, state word in `Ok`/`Err`.
- Help: `Label` the group headings, verb names, option keys, glossary terms and preset names; dim
  the Cobra scaffolding. TTY-gated so every golden stays byte-identical. Fix the duplicated
  `(default: full) (default "1")` on `--volume`, which does regenerate `tune.golden` as a
  reviewed diff.
- Errors in `cmd/ley/main.go`: `Err` ink on the `ley:` prefix only, `Muted` on a parenthetical
  path, `Cmd` on the remedy. `ExitError.Message` stays a plain string.
- Bring the root unknown-verb error up to the house voice, matching the unknown-topic message.
- Fix the two daemon sentences that break the house convention (`did not exit within 5 s`,
  `spawn ... fork/exec ...`) and re-check the 5 s stop timeout, which fired on clean stops during
  the audit.

### UI-1 `[x]` Adopt lipgloss and add the level ramp

The dependency decision above is reversed by request: take `github.com/charmbracelet/lipgloss`
(v1, the module path the user linked). v1 is the right line here because its `Render()`
self-downsamples, so a stray `fmt.Fprintf` cannot leak truecolor into a pipe; v2 inverts that and
would put this CLI's stdout contract at the mercy of every call site.

- `internal/ui` renders its six ink roles through lipgloss styles instead of hand-written SGR.
  The `Color bool` gate stays authoritative and is checked before lipgloss is called at all, so a
  zero `Style` is still the identity function and every existing test and golden holds.
- Detect the profile once, from the same per-stream decision `Resolve` already makes, and set it on
  a lipgloss renderer the package owns. Never touch lipgloss's global default renderer, and never
  call `HasDarkBackground` or `AdaptiveColor`: both query the terminal and read stdin.
- Add `Level(frac float64) string`, the ramp from section 4a of the style guide: deep blue at the
  floor through cyan, green and yellow to red at full scale, rendered at whatever depth the
  profile reports and collapsing to five named colours at 16.
- Add the line and border vocabulary lipgloss brings: a `Box` helper (rounded border) and a
  heavier rule glyph set, both with ASCII fallbacks, for the screens that want a frame.
- Tests: the identity property still holds with lipgloss in place; `Level` is monotone in hue
  across the range and returns the input unchanged when `Color` is false; a forced 16-colour
  profile emits only the named five; and no ramp output appears under `--json`.

### VIS-6 `[x]` Colour the spectrum by level, and frame what deserves a frame

- Every spectrum column takes `Level` ink keyed to its own dB, so the band reads by hue as well as
  height: the noise floor is cold and a carrier is hot. This replaces the three-band
  Muted/plain/Ok inking, which real RF showed collapses to plain across most of a live band.
  Keep the block ramp doing the same job for a reader with colour off.
- The `--watch` max-hold trace keeps its own dim treatment so it stays distinguishable from the
  live trace now that the live trace is coloured.
- Frame the chart with the new `Box` helper on a terminal wide enough for it, with the header
  inside the frame; no frame when piped, under `--ascii`, or below the width it needs.
- Give the peak list the same ramp ink on its dB values so the chart and the list agree.
- Verify against real RF over rtl_tcp (a live FM broadcast band shows a full range of levels), at
  40, 80, 100 and 160 columns, in truecolor, 256, 16 and no colour.

## Closing

Done on 2026-09-09, commits bdec168..3768071 (the `ui` package with two follow-ups, then one
commit per screen group, each built in its own worktree and applied to main with the suite run
between). Gate in the container at 3768071:

- Go: build, vet, `go test ./...` green; `make lint` 0 issues; `gofumpt` clean.
- Swift: 137 tests, 0 failures (untouched by this pass).
- e2e: 2/2. One assertion moved: `set`'s confirmation no longer repeats the channel id, so the
  test asserts the value and the frequency it does print, and the state check that follows still
  proves the write reached the right channel.
- Verified by eye against the real daemon with a looping fixture: the spectrum chart at 40, 80 and
  160 columns in both alphabets, `ley state`'s tree, `ley devices`, the tune banner and meter, and
  a check that `--color always --json` leaks no escape byte on any verb or on the fft rows.

### Follow-ups

- `ley play`'s banner did not get the one-fact-per-line treatment `tune`'s did; it still reads as
  a five-line block of ids. Worth a small follow-up for symmetry.
- `ley state`'s per-device tuning range prints `146.520 MHz to 146.520 MHz` for a file device;
  `ley devices` collapses a one-frequency range and state should share that helper.
- The spectrum peak threshold is a constant 15 dB above the median bin. The honest quantity scales
  with bin count (the max of N noise bins grows with ln N); if `scan` ever wants real detection it
  needs the scaled form.
- The live meter moved from stdout to stderr so the stderr-tty gate is coherent, but the banner
  still goes to stdout in human mode, so a scraped live session now sees its two halves on
  different streams. Worth deciding deliberately.
- `ley bands`' NOTE column truncates to about 15 columns at 80 columns wide, because NAME, RANGE,
  MODE and BANDWIDTH already spend 63. Dropping BANDWIDTH would give NOTE room.
- `docs/cli-style.md` section 6 says only the `ley:` prefix and the `[CODE]` suffix may take ink on
  an error line, while the VIS-5 item also allowed a muted path and a highlighted remedy. The
  implementation followed the item; the guide should be reconciled to match.
