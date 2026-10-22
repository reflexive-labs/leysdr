# Plan: the agent's loop on the Mac

Until 2026-10-21 the app was written in a Linux container that compiles none of
`app/Sources/LeylineApp` (`../dev/swift-style.md`, section 12), so every view change ended in an
"Unverified on the Mac" list for the owner to work through by hand. Work now happens on the Mac
itself. This plan gives an agent what it needs to check a view change without a person: build
the app, run it against a hermetic daemon, put it in a known state, take its picture and its
structure, compare both with what they should be, and read the result in a few lines.

## Decisions (2026-10-21)

- **Extend `leyshots`; do not add a second harness.** It already starts one
  `leylined --no-hardware` per scene on synthetic IQ from a fixed seed, imports bookmarks, stages
  the window through `LEYLINE_APP_STAGE`, reads back `regions.json` and crops a
  `screencapture -l` image. A check scene is a site scene that is not published.
- **The app takes its own picture.** In a staged run the app renders its window with
  `cacheDisplay(in:to:)` and writes the PNG beside `regions.json`. This needs no Screen Recording
  permission, does not depend on focus or Mission Control, and records the backing scale with
  the image. `screencapture -l` stays as the site shots' path, and as a check that the two agree.
- **The control channel is a file the app watches, not a socket.** A staged run already reads a
  file; a check run appends commands to a second file (`stage`, `snapshot`, `state`, `ax`,
  `quit`) and the app answers each in a numbered result file. This keeps invariant 1's spirit
  (one protocol to the daemon; nothing new listens) and needs no port or socket permission. It
  is read only when `LEYLINE_APP_STAGE` is set.
- **Goldens are local and never committed.** They live in `tmp/goldens/<macOS>-<arch>/`, because
  system font metrics change between macOS releases and a golden from another Mac shows diffs
  nobody can see. They are re-recorded only with `RECORD=1`. An agent never re-records to make a
  check pass; it says in the handover which goldens it re-recorded and why.
- **A picture is compared by numbers, and judged by a model only as advice.** The diff is a
  percentage of changed pixels and a diff image. A vision review against a written checklist
  reports per item and never gates.
- **No XCUITest, no Xcode MCP, no Peekaboo in the loop.** XCUITest needs an `.xcodeproj`
  beside the package; the Xcode MCP needs Xcode open; Peekaboo needs both TCC grants. The
  accessibility dump below covers structure, and the staged run covers input. Peekaboo is
  fine for a person poking at the window by hand.
- **Dark only.** `Theme.swift` has no light palette (`site-shots.md`, "Out of scope"), so the
  matrix is scenes by window size.

## Units

### ML-0 `[x]` The Mac builds everything the loop needs

- `make go` on the Mac: `go/bin/ley` is a Linux ELF left by the container, which is why the
  `leyline` MCP server fails to start (`ENOEXEC`).
- `make swift`, `make app`, `make app-bundle`, `make fixtures`; `make app-lint` and `make lint`
  green. Fix what the first native compile of `LeylineApp` finds (it built clean on 2026-10-21
  with `swift build`; Xcode's stricter checker and warnings are still to be read).
- Grant Screen Recording to the terminal that runs `claude`, once, by hand, so the existing
  `make shots` works as a baseline. Record the terminal's name in `AGENTS.local.md`.
- Done when `make shots ONLY=app-radio-2m.png` writes an image on this Mac.

Landed 2026-10-21: all of the above green with nothing installed; the one failure was the `ley
daemon` tests reaching the machine's real launchd (`d487472`). The first shot showed two
layout faults for ML-9: the spectrum's trace draws over its dB labels at both edges, and the
sidebar filter's placeholder is cut to "Band, bookmark or channe".

### ML-1 `[ ]` The app writes its own window picture

`Staging.swift`: after `settle`, beside `regions.json`, write `window.png` from the window's
content view (`bitmapImageRepForCachingDisplay` + `cacheDisplay`), at the backing scale, with the
scale and the window's point size in `regions.json`. Check that it matches `screencapture -l`
on one scene, toolbar included; if the toolbar or the Metal waterfall does not render through
`cacheDisplay`, say which, and fall back to `screencapture` for those scenes.

### ML-2 `[ ]` Deterministic frames

Behind `LEYLINE_APP_STAGE` only: animations off (`NSAnimationContext` duration 0, a transaction
that disables animations at the root), the caret not blinking, the window drawn as key whether or
not it is frontmost, and the waterfall paused at a fixed row count before the picture. Two runs
of one scene give the same pixels, or the unit names what still moves.

### ML-3 `[ ]` The command file

`LEYLINE_APP_CONTROL` names a file the app tails. Each line is one JSON command; each answer is
`<n>.json` (and `<n>.png` for a picture) in a directory beside it:

| command | does |
|---|---|
| `stage {…}` | applies a `ShotStage` to the running window, so one launch takes several states |
| `snapshot` | ML-1's picture, now |
| `state` | `AppSession`'s view state as JSON: place, selection, tuned channel, open rows, inspector, notices |
| `ax` | ML-5's tree, from inside the process |
| `key "⌘G"` / `type "wx3"` | an event into the key window, for the keyboard paths in the Unverified lists |
| `quit` | ends the app cleanly |

`ShotStage` gains what the Unverified lists need to reach: open a popover, focus the filter
field, hover a point on the rail or the spectrum, open the assistant panel, open Settings.

#### The protocol (fixed 2026-10-21, so ML-3 and ML-4 can be built side by side)

- `LEYLINE_APP_CONTROL=<dir>` turns it on. It makes the session staged as `LEYLINE_APP_STAGE`
  does (nothing written to UserDefaults, ML-2's deterministic frames), with or without a stage
  file; with one, the stage is applied first and `regions.json` written as today.
- **Ready.** Once the session is live and has its first channel (`Staging.liveSeconds` and
  `channelSeconds`), or when those run out, the app writes `<dir>/ready.json`:
  `{"ok":true,"pid":123,"window_number":456,"scale":2.0,"error":""}`.
- **Commands.** The client appends one JSON object per line to `<dir>/commands.jsonl`. The app
  reads new complete lines every 100 ms and runs them one at a time, in order. Every command
  has an integer `id`, unique in the run, and a `cmd`.
- **Answers.** For each command the app writes `<dir>/out/<id>.json` by writing a temporary
  file and renaming it, so a reader never sees half an answer:
  `{"id":7,"ok":true,"error":"","files":["out/7.png"],"result":{…}}`. Paths in `files` are
  relative to `<dir>`. A command the app cannot parse or run is answered `ok:false` with the
  reason in `error`, and the next command still runs.

| `cmd` | fields | answer |
|---|---|---|
| `stage` | `stage`: a `ShotStage` object (`settle` applies; `window` resizes) | `result`: what was applied, as the log lines say it |
| `snapshot` | `settle` (seconds, default 0) | `out/<id>.png` at the backing scale; `result`: `{"scale":2,"width_pt":…,"height_pt":…,"regions":{…}}`, the regions as `regions.json` gives them |
| `state` | | `result`: the view state (place, selection, tuned Hz and mode, channel id, open sidebar rows, inspector shown, zoom, focused control, notices on screen, popover open, the assistant panel open) |
| `ax` | | `out/<id>.ax.txt` (ML-5's tree); `result` empty |
| `key` | `keys`: `"cmd+g"`, `"escape"`, `"down"`, `"return"` | sent to the key window as key down and up |
| `type` | `text` | one key event per character to the key window |
| `press` | `identifier` (ML-5) | `accessibilityPerformPress` on the element with that identifier |
| `wait` | `seconds` | answered after that long |
| `quit` | | answered, then the app terminates |

### ML-4 `[ ]` `leyshots check`

A sibling of `leyshots run` reading `app/checks/scenes.yaml` (same scene shape, plus a list of
`steps` of ML-3 commands and the window sizes to take). For each scene it starts the daemon and
the app (`open -g -n`, so nothing takes focus), runs the steps, collects the pictures, state and
trees into `tmp/checks/<scene>/`, compares each picture with its golden, and prints one line per
picture: `ok`, `diff 2.4 %` or `new`, and the path. The pixel diff is Go (`image` is already in
`leyshots`): per-channel tolerance, an anti-aliasing allowance, a red diff image. `make app-check`
runs it; `ONLY=` and `RECORD=1` as `make shots` has them.

### ML-5 `[ ]` The accessibility tree

`.accessibilityIdentifier` on the views the checks name (there are none today): the sidebar
rows, the band rail, the tuning field, the transport controls, the inspector groups, the Library
rows, the assistant panel. ML-3's `ax` writes role, identifier, label, value, frame and enabled
for each element as indented text, so a scene's tree diffs as text against its golden and an
agent can assert "the row `band.gmrs` is expanded and the third child reads `ch5`" without
a picture.

### ML-6 `[x]` The style checks

- `scripts/check-theme.sh`, run by `make app-lint`: no `Color(`, `NSColor(`, `.font(.system` or
  hex literal in `app/Sources/LeylineApp` outside `Theme.swift`, with an allow-list for
  `Color.clear` and the like; the 25 hits today are each moved to a token or allowed with a
  reason.
- A test that parses `docs/dev/app.md`, "Palette and type", and fails when a token or value
  differs from `Theme.swift`.
- A test of WCAG contrast for every ink token on the grounds the table pairs it with, so an ink
  that falls below 4.5:1 (3:1 for the faint ones the table names) is caught in Swift, on Linux
  too.
- In `leyshots check` (with ML-4, still open): every pixel of a scene's chrome regions (from `regions.json`) is a palette
  value or a blend of two, which catches a system default colour leaking into a panel.

Landed 2026-10-21 but for the pixel check: `scripts/check-theme.sh` in `make app-lint` (shorthand
colours too, one line at a time), eight glyph font tokens and `meterWell` (pure black, off the
palette: the owner may want it on), `PaletteTests.swift`. Two contrast pairs sit under 3:1 and
are recorded as exceptions: `inkFaintest` on `chrome` (2.98) and on `selected` (2.84).

### ML-7 `[ ]` The vision review

`app/checks/review.md`: the layout rules of `../dev/swift-style.md`, section 7, and the
palette's roles written as yes-or-no questions, plus per-scene questions taken from the
Unverified lists. The skill (ML-8) has the agent read the scene's picture at 1× with the
questions and answer each with yes, no or can't tell. A "no" becomes a task, not a failed check.

### ML-8 `[ ]` The skill and the hooks

- `.claude/skills/app-check/SKILL.md`: when to run `make app-check`, how to read its lines,
  how to look at one picture or diff, the never-re-record rule, and what to put in a handover.
- `../dev/swift-style.md`, section 12, rewritten for the Mac: the "read the diff by eye" list
  becomes "run `make app-check`", and "state what was not compiled" becomes "state what no check
  covers".
- `.claude/settings.json`: allow `make app-check`, `make app`, `make app-lint`, `open -g`,
  `pkill -x LeylineApp`.
- A PostToolUse hook on edits under `app/Sources` running `swift build` for the app and
  `scripts/check-theme.sh`: seconds, not the full loop.

### ML-9 `[ ]` Burn down the Unverified lists

Turn each item under "Unverified on the Mac" in `app.md` (U4 onward, Settings, the assistant
panel, the window following the radio) and `ai-features.md` into a check scene, a `state` or
`ax` assertion, or a review question, and run them. Fixes are filed as new items in those plans.
Items that need the real radio, real audio or a person's ear stay on a shorter list, named.

### ML-10 `[ ]` Snapshot tests of single views (later, if ML-4 is too slow)

Offscreen `NSHostingView` renders of single views from a fixture `AppSession`, in a macOS-only
test target. Only worth it if a whole-window run per check is too slow for the edit loop; it
first needs an `AppSession` that can be built without a daemon, which is its own design question.

## Order

ML-0, then ML-1 and ML-2 together, ML-4 on the existing stage, ML-3, ML-5, ML-6 (which can start
any time), ML-8, then ML-9 as the first real workload. ML-7 and ML-10 when ML-9 shows the need.
