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
4. **Never style machine output.** `--json`, the bulk row streams (`fft`, `listen`,
   `spectrum --json`) and `--format bin` force the profile off before any renderer
   exists. This is decided once at start-up, not per call site.
5. **Restraint.** Six ink roles, one glyph ramp, no boxes, no rainbows. If everything
   is emphasised, nothing is. A screen that needs more than three levels of emphasis
   is a screen that needs restructuring instead.

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

**Depth is always the 16 ANSI names**, never 256 and never truecolor. The user's own
terminal theme resolves them, so the output is legible on a light Terminal.app profile
and a dark iTerm2 profile without querying the terminal for its background. Never emit
an OSC background query: it writes to the terminal and reads stdin as a side effect.

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
the number the screen exists to report. Emphasis is for finding it, not for being it.

Rules:

- **Never colour inside an aligned table cell** unless the renderer measures visible
  width. `tabwriter` counts escape bytes as characters and will misalign. Style the
  header row and whole-cell state words through `ui.Style.Pad`, which measures
  visible width, or leave the cell plain.
- **Never insert characters into an id.** Highlight by SGR only, so a mouse selection
  still yields a valid `chan_...`.
- **Never colour the only difference** between two states. The word differs too.

## 4. Glyph vocabulary

| Purpose | UTF-8 | ASCII | Notes |
|---|---|---|---|
| Spectrum column ramp | ` ▁▂▃▄▅▆▇█` | ` .:-=+*#%` | eight levels plus empty |
| Level bar filled / empty | `█` / `░` | `#` / `.` | meter bars |
| Marker (squelch, tuned freq) | `▲` | `^` | placed under the axis |
| Horizontal rule | `─` | `-` | section separators, the noise floor |
| Tree branch / last / trunk | `├─` `└─` `│` | `+-` `\-` `|` | `ley state` hierarchy |
| Absent value | `-` | `-` | never blank, never the same glyph as a range separator |

Ranges read `24.000 MHz to 1.766 GHz`, never with a dash, so a dash always means
"no value".

## 5. Layout rules

- **Tables** keep ALL-CAPS headers, two-space gutters and `tabwriter`. Headers are
  `Label`. Columns carry units in the header (`OFFSET (kHz)`), never per cell.
- **The answer leads.** The first column is what the verb was asked about (model,
  frequency, name), not the id. Ids move right or behind `--wide`.
- **Label blocks** align on a padded left column of `Label` ink, with the value plain
  and any diagnostic (`pid`, `socket`, serial) `Muted` on the same line.
- **Hierarchy is indentation**, not repeated ids. `ley state` shows device to capture to
  channel to sink as a tree; each level names only what is new.
- **Numbers** are formatted by the existing helpers in `format.go` and
  `pkg/leyline`, which stay pure and unstyled: they return the semantic string and the
  caller decides the ink. Frequencies keep three decimals and an SI unit; levels are
  `-42.1 dBFS`; the unit appears once per column or line, not per value.
- **A screen ends with what to do next** when the user is likely to be mid-task:
  one `Cmd` line, never a paragraph.
- **Blank lines group**; rules separate sections only when a blank line is not enough.

## 6. Frozen contracts

Styling may add SGR and may re-lay a screen, but these do not move:

- Exit codes `0` success, `1` daemon or runtime error, `2` usage, `3` daemon not
  running, `130` interrupted before the live phase (docs/interfaces.md).
- The error shape `ley: <sentence> [CODE]`. Only the `ley:` prefix and the `[CODE]`
  suffix may take ink, and only in `cmd/ley`'s printer; `ExitError.Message` stays a
  plain string because tests inspect it.
- Every `--json` shape, the bulk row shapes, and `ley version --json`.
- Ids and `ley ...` command strings stay verbatim and copy-pasteable.
- The golden help snapshots in `go/internal/cli/testdata/help/`: help is captured
  through a non-terminal writer, so styling must be TTY-gated and leave them
  byte-identical. A golden that must change is a deliberate, reviewed diff.
- The documented wording in docs/interfaces.md and docs/cli-guide.md. Emphasis may be
  added to a sentence; the sentence is not rewritten as part of a visuals change.

## 7. The `ui` package

`go/internal/ui` owns styling. It has no dependencies outside the standard library.

```go
type Style struct {
    Color   bool // emit SGR
    Unicode bool // use the UTF-8 glyph set
    Width   int  // resolved terminal width, 0 = unknown
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
func (s Style) Rule(width int) string

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
- `printJSON` and `printArray` never see a style. That is the proof that machine
  output is out of reach.

## 8. Testing rules

- Every screen gets a test that renders it **twice**, once with a plain style and once
  with `Color: true, Unicode: true`, and asserts `ui.Strip(styled) == plain`. That is
  the mechanical proof of principle 1.
- Golden files stay plain: they are captured through a non-terminal writer.
- Width-dependent renderers are tested at 40, 80 and 160 columns and must never emit a
  line whose `ui.Visible` exceeds the width.
- The `--json` and bulk paths get one test each asserting the output contains no `\x1b`
  byte with `Color: true` forced.
