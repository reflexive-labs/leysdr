# CLI style guide

How `ley` looks. This is the contract every verb's output follows, and the spec the
`go/internal/ui` package implements. Read it before changing anything a user sees.

The rules here exist because of one fact: `ley` is read by people in a terminal **and**
by scripts, agents and the MCP adapter through the same binary. Styling that cannot be
turned off, or that leaks into a pipe, breaks the second audience silently.

## 1. Principles

1. **Meaning survives without colour.** Colour and weight are redundant emphasis on
   information the words already carry. `ACTIVE` is green because it says ACTIVE, not
   the other way round. Anyone reading a `NO_COLOR` terminal, a pipe, or a screen
   reader loses nothing but polish. Every screen must be reviewed with colour off.
2. **The plain path is the same path.** There is no styled build and no unstyled build.
   Styling is a zero-value `ui.Style` whose methods are the identity function, so the
   default is plain and the existing golden tests keep testing what ships.
3. **stdout belongs to the machine; stderr belongs to the person.** Prose, banners,
   warnings and the live meter go to stderr. stdout carries tables, ids, JSON and bulk
   rows. Styling follows the stream, so `ley state | grep chan_` keeps coloured prose
   on the terminal and clean text in the pipe.
4. **Never style machine output.** `--json`, the bulk row streams (`fft`, `listen`, and
   `spectrum`, `waterfall`, `phosphor` under `--json`) and `--format bin` force the
   profile off before any renderer exists. This is decided once at start-up, not per
   call site.
5. **Restraint.** Six ink roles, one glyph ramp, one level ramp, and a frame only where
   it earns its width. A screen that needs more than three levels of emphasis needs
   restructuring.

## 2. Capability model

Resolved once in `NewRootCommand`, carried on `App.Style`, never re-derived.

### Colour, decided per stream

First match wins, evaluated separately for stdout and stderr:

| Order | Condition | Result |
|---|---|---|
| 1 | `--json`, a bulk row stream, or `--format bin` | off (stdout; stderr may still colour) |
| 2 | `--color=never` / `--color=always` | as asked |
| 3 | `NO_COLOR` set to a non-empty value | off |
| 4 | `CLICOLOR_FORCE` non-empty and not `0` | on |
| 5 | `CLICOLOR=0` | off |
| 6 | `TERM` is `dumb` or empty | off |
| 7 | that stream is a terminal | on, else off |

**Ink roles are the 16 ANSI names**, so the user's own terminal theme resolves them and
they read on a light Terminal.app profile and a dark iTerm2 one. **One exception: the
level ramp** (section 3a) uses the full depth the terminal reports, because a spectrum
carries level by hue and sixteen colours cannot express a gradient. Everything else stays
on the named sixteen. Never emit an OSC background query: it writes to the terminal and
reads stdin as a side effect.

### Width

First match wins: `--width N` where the verb has one, then `COLUMNS` if it parses above
zero, then `TIOCGWINSZ` on stdout, then on stderr, then `80`. A zero or errored ioctl
means "unknown", not "narrow": a pty with no winsize reports success with zero columns.
Clamp the result to `[40, 160]`. A 300-column chart is worse than a 120-column one.

### Unicode

On when `LC_ALL`, `LC_CTYPE` or `LANG` contains `UTF-8` (case-insensitive), off
otherwise, and `--ascii` forces it off. Every glyph has a declared ASCII fallback in
section 4; a screen must be legible in both.

## 3. Ink vocabulary

Six roles. Use the role, never a colour name, at the call site.

| Role | Rendering | Use for |
|---|---|---|
| `Label` | bold | table headers, field labels, the left column of a label block, verb names in help |
| `Muted` | dim | ids the user is not being asked to read, units, hints, scaffolding, values below the noise floor |
| `Ok` | green | `ACTIVE`, `AVAILABLE`, audio flowing, squelch open, a successful action |
| `Warn` | yellow | `OUT_OF_CAPTURE`, `IN_USE` by another program, muted audio, a degraded but working state |
| `Err` | red | `DISCONNECTED`, `CAPTURE_DETACHED`, the `ley:` error prefix, a rejected write |
| `Cmd` | cyan | commands the reader is meant to copy and run |

Plain (no role) is the default and carries the primary answer: the frequency, the mode,
the number the screen exists to report. Emphasis helps the reader find it.

Rules:

- **Never colour inside an aligned table cell** unless the renderer measures visible
  width. `tabwriter` counts escape bytes as characters and will misalign. Style the
  header row and whole-cell state words through `ui.Style.Pad`, which measures
  visible width, or leave the cell plain.
- **Never insert characters into an id.** Highlight by SGR only, so a mouse selection
  still yields a valid `chan_...`.
- **Never colour the only difference** between two states. The word differs too.

### 3a. The level ramp

`ui.Style.Level(frac, text)` inks text with the colour a normalised level maps to, and is
the only place depth above sixteen colours is used. The ramp runs cold to hot so height and hue agree:
teal at the noise floor, then green, amber, orange, and a salmon red at full scale. These are
the brand's terminal colours, sampled from the design system's dashboard mock; what the terminal
ramp shares with the app's is hue order and nothing else, because the app's runs from near-black
to cream and assumes the dark ground it owns. **The cold end is the
noise line, not the bottom of the chart**, so hue shows how far a signal is above the
floor.

**Every chart sets its own cold end, and one function does the normalising.** `rampFrac(value,
floor, top)` in `internal/cli/chart.go` is the only place a level becomes a ramp fraction. What
differs is the two references: `spectrum` runs from the noise line to the loudest column the run
has seen; `levels` from −60 dBFS to full scale, a held scale a meter can be read against;
`waveform` from silence to the scale on screen, so a quiet passage under `--scale 0.1` still has
colour in it; `waterfall` from the noise floor over its fixed 40 dB range. In every view, a colour
means the same distance above that chart's own zero reference.

**The ramp is tuned for a dark terminal.** Querying the terminal background is forbidden (no
OSC query, no `HasDarkBackground`), so the ramp cannot adapt and has to target one background.
The current stops clear 3.9:1 or better against black and `#1e1e1e`, and
between 2.5:1 and 4.2:1 against white and `#fafafa`, with the teal cold end at the low end of
that. On a light terminal the noise floor, which is the cold end and most of any chart, reads
faint. That cost was accepted after rendering both ramps side by side: the ramp before
this one held every stop between 0.18 and 0.26 relative luminance, the one band that clears
3.2:1 on both grounds, and it read as thin on the dark terminal nearly every reader has. Level is
carried by height and by texture as well as by hue, which is what keeps a light-terminal chart
readable. `TestLevelRampIsLegibleOnBothGrounds` holds two bars so no stop can drift to invisible
on either ground: 3.0:1 on black and `#1e1e1e`, 2.4:1 on white and `#fafafa`. The cold end was
once a saturated `#0000A0`, 1.2:1 on a dark terminal, and most of every chart vanished; the
lower bar exists so that cannot happen again in either direction.

**A quiet band is held to the cold third of the ramp, not to a single ink.** Forcing every
column to one colour when nothing is detected is accurate but unreadable: the chart becomes a
flat field with no shape, and the flatness of the floor, which is what a reader checks a quiet
band for, cannot be seen. Cap the ramp instead, so the texture shows but no hot colours appear.
The ramp degrades with the colour profile, with no separate code path:
truecolor renders the gradient, 256 renders the nearest cube
colour, 16 collapses to cyan/green/yellow/bright red/red, and none returns the string
unchanged. A reader with colour off still has the eight-level block ramp, so level
survives as height.


## 4. Glyph vocabulary

| Purpose | UTF-8 | ASCII | Notes |
|---|---|---|---|
| Spectrum column ramp | ` ▁▂▃▄▅▆▇█` | ` .:-=+*#%` | eight levels plus empty |
| Spectrum stem | `│` | `\|` | under a column's top edge, above the floor rule |
| Waterfall shade | ` ░▒▓█` | ` .:+#` | four levels plus empty; densities that tile |
| Level bar filled / empty | `█` / `░` | `#` / `.` | meter bars |
| Half cell top / bottom | `▀` / `▄` | `#` / `#` | a filled shape whose edge falls mid-cell, as the clip's envelope does |
| Marker (squelch, tuned freq) | `▲` | `^` | placed under the axis |
| Horizontal rule | `─` | `-` | section separators, the noise floor |
| Heavy rule | `━` | `=` | a break a light rule cannot carry |
| Frame | `╭╮╰╯│─` | `+|-` | `ui.Style.Box`, for a chart that deserves one |
| Tree branch / last / trunk | `├─` `└─` `│` | `+-` `\-` `|` | `ley state` hierarchy |
| Absent value | `-` | `-` | never blank, never the same glyph as a range separator |

Ranges read `24.000 MHz to 1.766 GHz`, never with a dash, so a dash always means
"no value".

## 5. Layout rules

- **Tables** keep ALL-CAPS headers, two-space gutters and `tabwriter`. Headers are
  `Label`. Columns carry units in the header (`OFFSET (kHz)`), never per cell.
- **The answer leads.** The first column is what the verb was asked about (model,
  frequency, name), not the id. Ids move right or behind `--wide`. A column that would read
  the absent glyph on every row is left out (`hideEmpty` on the column), because a column of
  dashes wastes width. An empty table keeps every header, so it still shows what a row holds.
- **Label blocks** align on a padded left column of `Label` ink, with the value plain
  and any diagnostic (`pid`, `socket`, serial) `Muted` on the same line.
- **Hierarchy is indentation**, not repeated ids. `ley state` shows device to capture to
  channel to sink as a tree; each level names only what is new.
- **Numeric columns are right-aligned**, header and all (`right` on the column), so the digits
  line up and a two-digit value does not sit at the far left of a `PEAK SNR (dB)` header with air
  after it. Text, frequencies and sparklines stay left-aligned.
- **Numbers** are formatted by the existing helpers in `format.go` and
  `pkg/leyline`, which stay pure and unstyled: they return the semantic string and the
  caller decides the ink. Frequencies keep three decimals and an SI unit; levels are
  `-42.1 dBFS`; the unit appears once per column or line, not per value.
- **A screen ends with what to do next** when the user is likely to be mid-task:
  one `Cmd` line, never a paragraph.
- **Blank lines group**; rules separate sections only when a blank line is not enough.
- **A chart draws its trace, not its area.** One glyph per column, on the row that column's
  value falls in, with a thin stem beneath it only where it stands above the reference line.
  Filling every cell under a column adds area without information: a flat noise floor covers
  two whole rows -- some two hundred cells against a carrier's dozen -- so the picture reads
  as one mass whatever is on the air, and the flatness of the floor, which is the thing the
  reader is checking, cannot be seen. The reference line itself is drawn as a
  rule and labelled on the axis, so height above it reads directly as margin.
- **A time-vs-frequency map double-encodes level, and leaves its floor blank.** The cell's texture
  carries the level and hue refines it. Hue alone disappears with colour off, so a map whose level
  lives only in colour is a blank rectangle under `NO_COLOR` or `--ascii`. This is why half-blocks
  (`▀` with a foreground and a background colour, two rows of time per cell) are rejected despite
  doubling the time depth: every cell becomes the same glyph. The floor draws as a space so the
  terminal's own background shows through, and the scale is chosen once and held -- a scale that
  moved per row would make the time axis misleading, since the same signal would change shade because
  something else got louder.
- **A chart's row is held coarse, and its span is not allowed to shrink to fit.** Autoscaling
  to the data is right until the data is noise: a receiver's noise floor spreads about 7 dB
  across the columns, so a scale that fits itself to an empty band gives a 1.5 dB row and
  scatters that floor over five of them. Hold a minimum span -- for the spectrum, 50 dB, a
  5 dB row -- and an empty band collapses to one line with seven empty rows of headroom above
  it. The headroom makes two bands comparable, because a column of a given height means the
  same dB on both.
- **A sparkline is eight cells of a real series, on the row it describes.** Drawn with the
  column ramp, oldest on the left, one line and never a chart; `sparkline` and `levelSparkline`
  in `internal/cli/spark.go` are the only renderers. A cell with anything in it is never blank,
  so a carrier that keyed once stays visible. It is allowed only where every
  cell is a measurement the daemon actually made in that slice: `ley monitor`'s ACTIVITY column
  (the share of each eighth of the watch the detector saw the carrier in, from the updates it
  re-publishes each row a carrier is found), the live meter's signal row (the loudest level the
  daemon reported in each of the last eight seconds), and `ley track`'s HEARD column (records per
  eighth of the table's window, one ramp step each, full at eight, so a packet reads the same on
  every row). `ley scan` has none: a sweep reports counts, and a ramp drawn from a count would
  show history the daemon never measured (invariant 12).
  Occupancy takes `Muted` ink, since it is not a level and eight
  full blocks in the foreground would outshine the numbers beside them; the meter's history takes
  level ink, because it is one. The same series goes out under `--json`
  as numbers (`on_air_slices`, `heard_slices`), the glyphs being the rendering, not the data.

## 6. Frozen contracts

Styling may add SGR and may re-lay a screen, but these do not move:

- Exit codes `0` success, `1` daemon or runtime error, `2` usage, `3` daemon not
  running, `130` interrupted before the live phase (docs/reference/cli.md).
- The error shape `ley: <sentence> [CODE]`. The sentence is the verb's own words and is
  never rewritten for ink. **Five spans may take ink**, by SGR only, each redundant on
  words that are there with colour off: the `ley:` prefix (`Err`); a parenthetical
  holding a path (`Muted`) -- one listing accepted values stays plain; the remedy
  `ley ...` command following one of the leads in `remedyLeads` (`Cmd`); the daemon's
  state words `not running` (`Err`); a trailing `[CODE]` (`Muted`). That list is closed:
  a sixth span is a change to this guide.
  One renderer applies it -- `errorLine`/`inkMessage` in `go/internal/cli/errink.go` --
  called by `cmd/ley`'s printer and by any screen repeating one of these sentences
  (`ley daemon status` does, on **stdout**). No other call site inks an error sentence.
  `ExitError.Message` stays a plain string because tests inspect it, and stripping the
  styled line gives back the plain one byte for byte.
- Every `--json` shape, the bulk row shapes, and `ley version --json`.
- Ids and `ley ...` command strings stay verbatim and copy-pasteable.
- The golden help snapshots in `go/internal/cli/testdata/help/`: help is captured
  through a non-terminal writer, so styling must be TTY-gated and leave them
  byte-identical. A golden that must change is a deliberate, reviewed diff.
- The documented wording in docs/reference/cli.md and docs/guide/using-ley.md. Emphasis may be
  added to a sentence; the sentence is not rewritten as part of a visuals change.

## 7. The `ui` package

`go/internal/ui` owns styling. It renders through lipgloss v1: `Render()` self-downsamples
to the profile it was given, so a stray `fmt.Fprintf` cannot leak truecolor into a pipe. The
package owns its own renderers, one per depth, writing nowhere; it never touches lipgloss's
global default renderer, and never calls `HasDarkBackground` or `AdaptiveColor`, both of
which query the terminal and read stdin.

```go
type Style struct {
    Color   bool    // emit SGR
    Profile Profile // colour depth, for Level alone; zero reads as the 16 names
    Unicode bool    // use the UTF-8 glyph set
    Width   int     // resolved terminal width, 0 = unknown
}

// Zero value is plain, ASCII, unknown width: every method is the identity.
func (s Style) Label(string) string
func (s Style) Muted(string) string
func (s Style) Ok(string) string
func (s Style) Warn(string) string
func (s Style) Err(string) string
func (s Style) Cmd(string) string

func (s Style) Glyphs() Glyphs          // the table in section 4
func (s Style) Pad(text string, n int) string      // pad to visible width
func (s Style) Truncate(text string, n int) string // ellipsis on visible width
func (s Style) Bar(frac float64, width int) string // level bar
func (s Style) Ramp(frac float64) string           // one column of the spectrum ramp
func (s Style) Shade(frac float64) string          // one cell of the waterfall ramp; blank at the floor
func (s Style) Level(frac float64, text string) string // the level ramp, section 3a
func (s Style) Rule(width int) string
func (s Style) RuleHeavy(width int) string
func (s Style) Box(content string) string          // rounded frame, ASCII fallback

func Visible(string) int    // width ignoring SGR
func Strip(string) string   // remove SGR; tests assert on this
```

Resolution lives beside it:

```go
func Resolve(o Options) Style // Options carries the flag, env lookup, isatty, width
```

Rules for callers:

- Get the style from `App.Style`. Do not construct one per call site.
- `App.table()` styles the header row; individual cells are plain unless they go
  through `Pad`.
- `session.say` is the prose router and already knows the stream; it applies ink.
- `printJSON` and `printArray` never see a style, so styling cannot reach machine
  output.

## 8. Testing rules

- Every screen gets a test that renders it **twice**, once with a plain style and once
  with `Color: true, Unicode: true`, and asserts `ui.Strip(styled) == plain`. This
  checks principle 1 mechanically.
- Golden files stay plain: they are captured through a non-terminal writer.
- Width-dependent renderers are tested at 40, 80 and 160 columns and must never emit a
  line whose `ui.Visible` exceeds the width.
- The `--json` and bulk paths get one test each asserting the output contains no `\x1b`
  byte with `Color: true` forced.
