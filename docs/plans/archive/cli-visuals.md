# CLI visuals

Make `ley` look like a finished tool. Source: the visuals audit (2026-09-09, six passes:
terminal capabilities, static screens, live verbs, the spectrum showpiece, daemon/help/errors,
and a constraints-and-seams map). The contract every item follows is `docs/dev/cli-style.md`; read it
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
  `docs/dev/cli-style.md` exactly: `Style` with `Color`/`Unicode`/`Width`, the six ink methods
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
  `Muted`. Wording stays byte-identical (docs/reference/cli.md pins it). Piped, print the
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

### VIS-7 `[x]` The chart must not make an empty band look busy

From a screenshot of a live `--watch` run on a quiet band (frame 59, "peak nothing above the
floor"): the chart read as a solid wall of signal when the band held only noise. Three causes,
all confirmed in the code.

- **The scale reserves 30 dB that nothing reaches.** `spectrum_render.go:181` sets
  `top = ceil(max(peak, noise+30)/5)*5`, so on a band whose loudest column is a few dB over the
  noise the data is crushed into the bottom third of the chart and 70% of the rows are blank. Make
  the top track the data: the peak plus a small headroom, with a floor of about `noise+10` so a
  dead-flat band still has somewhere to draw. Keep the frozen-scale-across-frames behaviour and
  the one-time "scale now X to Y" note; only the choice of top changes.
- **Max-hold accumulates noise into a ceiling.** `hold` is a per-column running maximum that never
  decays (`spectrum_render.go:46`), so after tens of frames of noise every column's hold sits at
  the noise peak and draws as a solid band above the live trace. That is what the screenshot's grey
  wall is. Give it a decay (pull each column back toward the live value a little each frame) and
  draw it only where it stands a visible margin above the live column, as a thin trace rather than
  a filled block, so it marks real transients and disappears on noise.
- **The chart contradicts the peak line.** When nothing clears the detection threshold the peak
  line already says "nothing above the floor" while the chart is full of colour. Say it plainly
  ("nothing above the floor; the band looks quiet") and render a chart with no detections in the
  cold end of the ramp so busy and quiet look different at a glance.

Also, defensively: when `spectrum` reuses an existing capture whose centre is not the frequency
that was asked for, say so on stderr ("showing the capture at 85.500 MHz, which covers
88.500 MHz"), so a chart centred somewhere other than the argument is never a surprise. A fresh
daemon centres correctly, which was verified against the radio; this is about the reuse path.

Verify against the radio over rtl_tcp on a quiet band and on the FM broadcast band, in `--watch`,
and confirm the two look different.

Verified 2026-09-09 on the R820T over rtl_tcp. The quiet band (85.5 MHz) settles at a -45 to -25
scale, noise fills the lower rows with no grey ceiling, and the peak line reads "nothing above the
floor; the band looks quiet". The FM band (88.5 MHz) settles at -50 to -0 with carriers standing 40
dB over the floor and a real peak list. A third fix was needed on top of the item: the scale only
ever ratcheted upward, so one transient permanently cost the rest of a `--watch` run its rows (this
is what the reported screenshot showed at frame 59). The top now rises at once and relaxes by one
5 dB label step a frame, and `TestSpectrumScaleIsFrozen` was rewritten from "never contracts" to
"never snaps".

### VIS-8 `[x]` Draw a trace, not a filled mass

Reported after VIS-7 landed: "the spectrum is all dark blue, the heights look more accurate, I
would expect this to show that KQED is operating on 88.5 but across the whole range the noise level
looks more or less equivalent."

Measured against the radio first, on a 2.4 MHz capture centred on 88.5 over rtl_tcp. Two things
came back. The chart was telling the truth about the band -- the column at 88.5 sat 1.8 dB *under*
the band median, so there was nothing there to draw -- and the frequency mapping was verified
independently against `fixtures/two_nfm.cf32`, whose two carriers at 146.220 and 146.620 land within
one bin of truth. What was wrong was the drawing.

**Cause: area, not colour.** The ramp was already keyed near the noise line, so a noise column
really was cold. But a filled bar chart paints every cell below a column's top, so on a 90 column
chart the floor covered two full rows, about 180 cells, where the loudest signal covered a dozen. By
area the picture was mostly noise, and because noise is correctly cold, the picture was mostly dark
blue. Filling also destroyed the very thing the reader wanted: a solid block of cells has no shape,
so "the noise is even across the band" could not be seen.

Done:

- **The chart draws the top edge of each column**, one glyph on the row its level falls in, picking
  the block from the sub-row remainder. `traceRow` pins a column at or under the bottom to the first
  row rather than dropping it, so a dip does not open a hole in the trace.
- **A thin stem under the trace**, drawn with the trunk glyph, only in rows above the floor rule. A
  first cut without the stem left a tall carrier as a glyph floating over nine blank rows on
  high-dynamic-range playback; a first cut with stems everywhere rebuilt the wall one row lower.
  Above the floor only is what keeps a tower reading as one thing at one frequency while a flat
  floor stays a line. The stem is the trunk glyph and the max-hold trace is the rule glyph, so the
  two never blur.
- **The scale reserves one whole row under the noise line** (`floorRowLimit`). Rounding the noise
  down to 5 dB, which is all the bottom used to do, left the floor rule on the first row or the
  second depending on where the band happened to fall -- for a live FM band the label appeared about
  one frame in ten. The bottom is now the lower of that rounding and the limit that guarantees the
  row, so the rule always sits on a labelled row with a row beneath it for the columns that dip.
- **The interior axis label names the noise floor** instead of an arbitrary mid-scale value, so a
  column's height over the rule reads directly as signal margin. That is the answer to "is the scale
  useful": the absolute dBFS numbers are for the header, and the number a reader acts on is margin.
- **The bottom relaxes as the top does.** It is now tied to the top, so without the mirrored decay a
  transient would drag it down and strand the rest of the run in a stretched chart.
- **`levelBand` is keyed to the noise line**, not to the bottom of the axis. With a row of air
  reserved under the floor, keying to the bottom counted that air as levels to ink and drew every
  noise column slightly warm.

Not done, deliberately: the chart is still mostly cold ink on an empty band, and that is correct.
66% of the inked cells are blue on the 88.5 capture because 66% of that band is noise. Ink dropped
from 187 cells to 131 and, more to the point, the cold ink is now a one-cell line with texture
rather than a two-row block. Chasing the percentage would mean lying about the band.

Tests: `TestSpectrumNoiseDrawsALineNotAMass` (a flat floor may not spend more than one block per
column), `TestSpectrumDrawsOnlyTheTopEdge`, `TestSpectrumTallColumnKeepsAStem`,
`TestSpectrumStemsStayAboveTheFloor`, `TestSpectrumAxisLabelsTheFloor`.
`TestSpectrumFrameOnATerminal` had to stop detecting an ASCII frame by the bare presence of `+`,
which is also the sixth step of the ASCII column ramp: it now looks for a top-left corner.

### VIS-9 `[x]` A quiet band must read as one flat line

Reported twice more after VIS-8 landed, with a screenshot of `ley spectrum 85.5 --watch`: "the
spectrum is all dark blue", then "still not looking good", then "the blue is still hard to see on my
dark terminal". Three separate causes, all real, all fixed.

Measured against the radio over rtl_tcp rather than reasoned about. Real column distributions,
90 columns each:

```
band          min    p25    p50    p75    p90    p99    max   p75-p25  max-p50
quiet 85.5  -48.1  -42.3  -40.5  -39.0  -37.7  -35.1  -35.0      3.2      5.5
busy 88.5   -48.0  -44.1  -42.4  -37.0  -30.2  -12.4   -7.5      7.1     35.0
busy 91.7   -51.2  -43.6  -39.3  -34.4  -29.0  -13.4   -6.3      9.2     33.1
```

**1. The scale collapsed onto the noise.** The top tracked the loudest column, which on an empty
band is a noise column a few dB over the median. Quiet got top -30 / bottom -45, a 1.5 dB row, and
the floor's own ~7 dB of spread smeared across five rows as confetti. Busy got a 5 dB row and read
fine, which is why only the quiet band looked broken. Fixed by holding a minimum span of 50 dB, so
the row is never finer than 5 dB, and anchoring the bottom under the band's 10th-percentile column
rather than under its median, so the low tail is drawn where it is instead of clamped into a flat
edge that is an artefact of the scale. All three real bands now land on 0/-50 with the floor rule on
the same row, which also makes them comparable: a column of a given height means the same dB on each.
A band deeper than 50 dB still gets a coarser row, never a finer one.

Four independent design proposals were taken on this, from a reference-level angle, a
noise-spread angle, a robust-statistic angle and a detection-gate angle. All four converged on a
fixed ~50 dB span at 5 dB per row, for the same reason: 5 dB is coarser than any real noise floor's
spread. Two of three judges picked the robust-statistic form, which is what was built. The judge
who dissented caught the low-tail clamping, which is why the bottom uses p10.

**2. A quiet band was inked in exactly one colour.** When nothing cleared the detection threshold
every column was forced to ramp band 0. Honest, and unreadable: 100% of the inked cells on the real
85.5 capture were a single blue, so the chart was a flat field with no shape, and the flatness of
the floor -- the thing a reader checks a quiet band for -- could not be seen. Now the ramp is capped
at `spectrumQuietRampCap` instead of collapsed: the same capture draws 7 distinct inks, all between
blue and cyan, and nothing warm. The band still cannot wear the colours of a busy one.

**3. The cold end was invisible on a dark terminal.** The ramp started at a saturated `#0000A0`,
which is 1.2:1 contrast against a `#1e1e1e` ground. Since most of a spectrum is noise floor and the
noise floor is the cold end, most of the chart was literally unreadable. We cannot ask what the
terminal's background is, so the ramp now holds every stop between 0.18 and 0.26 relative luminance,
clearing 3.2:1 against black, `#1e1e1e`, white and `#fafafa`. Hue still sweeps cold to hot; only
luminance is held flat, which costs nothing because height carries level too. The 16-colour fallback
takes bright blue rather than blue for the same reason.

Tests: `TestSpectrumBandsAreComparable`, the rewritten `TestSpectrumScaleTracksTheData` (which used
to assert the scale must *not* reserve unreachable sky -- that rule was the bug), the rewritten
`TestSpectrumQuietBandReadsQuiet` (cold third, more than one ink), `TestLevelRampIsLegibleOnBothGrounds`
and `TestLevelRampSweepsColdToHot`.

Also corrected: an earlier capture that appeared to show nothing at 88.5 was taken while rtl_tcp was
crash-looping and was mistuned by about 1.08 MHz, which put KQED at an apparent 87.4. With the radio
healthy, KQED reads +40 dB over the floor at 88.5 and KALW +39 dB at 91.7. **Open:** a DC spike at
the capture's exact centre appears on some fresh rtl_tcp connections, at roughly the same -7 dBFS.
It was absent from the session the 88.5 and 92.0 numbers came from, but the clean way to separate it
from a real carrier is an off-centre capture (`ley spectrum 88.0`, where KQED should sit half a
division right of centre). rtl_tcp went down before that could be run.

## Closing

Done on 2026-09-09, commits 6233048..ed2946f (the `ui` package with two follow-ups, then one
commit per screen group, each built in its own worktree and applied to main with the suite run
between). Gate in the container at ed2946f:

- Go: build, vet, `go test ./...` green; `make lint` 0 issues; `gofumpt` clean.
- Swift: 137 tests, 0 failures (untouched by this pass).
- e2e: 2/2. One assertion moved: `set`'s confirmation no longer repeats the channel id, so the
  test asserts the value and the frequency it does print, and the state check that follows still
  proves the write reached the right channel.
- Verified by eye against the real daemon with a looping fixture: the spectrum chart at 40, 80 and
  160 columns in both alphabets, `ley state`'s tree, `ley devices`, the tune banner and meter, and
  a check that `--color always --json` leaks no escape byte on any verb or on the fft rows.

### Colour pass (UI-1, VIS-6)

Added on request after the first pass shipped. lipgloss v1.1.0 is now a dependency, the six ink
roles render through it, and `Style.Level(frac, text)` inks by level along a blue to red ramp at
whatever depth the terminal reports. Verified against a live FM broadcast band over rtl_tcp: the
noise floor renders deep blue, mid-band cyan and green, a broadcast carrier yellow, the strongest
peak orange-red, and the peak list takes the same ink so chart and list agree. Degradation checked
at truecolor, 256, 16 (five named stops) and none, and the rounded frame appears on a terminal at
least 60 columns wide and never when piped or under `--ascii`.

### Follow-ups

Now tracked in `docs/plans/archive/cli-papercuts.md`, which is where small CLI improvements collect so they are not
lost in the Closing section of whichever plan was open when they were noticed. Kept here for the
context they were written in.

- The `ley state` device line and `ley devices` disagree on how a one-frequency tuning range reads;
  state should use the same collapsing helper.
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
- `docs/dev/cli-style.md` section 6 says only the `ley:` prefix and the `[CODE]` suffix may take ink on
  an error line, while the VIS-5 item also allowed a muted path and a highlighted remedy. The
  implementation followed the item; the guide should be reconciled to match.
