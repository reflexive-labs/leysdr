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

### ML-1 `[x]` The app writes its own window picture

`Staging.swift`: after `settle`, beside `regions.json`, write `window.png` from the window's
content view (`bitmapImageRepForCachingDisplay` + `cacheDisplay`), at the backing scale, with the
scale and the window's point size in `regions.json`. Check that it matches `screencapture -l`
on one scene, toolbar included; if the toolbar or the Metal waterfall does not render through
`cacheDisplay`, say which, and fall back to `screencapture` for those scenes.

Built 2026-10-21, not ticked until ML-4 has run on it: the picture is the theme frame (the
content view's superview), so the title bar and toolbar render. The Metal waterfall came out as
the ground; the renderer draws a frame offscreen and the app lays it over the Metal view for the
draw, so no scene needs `screencapture`. Against `screencapture -o -l` at 2× the picture differs
at the four rounded corners and in the filter's placeholder, which `cacheDisplay` draws brighter.

### ML-2 `[x]` Deterministic frames

Behind `LEYLINE_APP_STAGE` only: animations off (`NSAnimationContext` duration 0, a transaction
that disables animations at the root), the caret not blinking, the window drawn as key whether or
not it is frontmost, and the waterfall paused at a fixed row count before the picture. Two runs
of one scene give the same pixels, or the unit names what still moves.

Built 2026-10-21 for both variables, without the pause: the checker masks the spectrum and the
waterfall, so the waterfall runs on. `isKeyWindow` alone left the traffic lights grey; the window
also overrides AppKit's private key-appearance getters. Two pictures a second apart still differ
in the inspector's live readings (tuning and deviation figures, the audio ladder), about 0.2 % of
a 1100 × 700 pt window, and the `ax` tree carries the same figures as values.

### ML-3 `[x]` The command file

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
- **A used directory.** Before it writes `ready.json`, the app removes the directory's outputs
  (an old `ready.json` and `out/`) and skips whatever `commands.jsonl` already holds, so a
  directory reused from an earlier run neither reads as ready nor replays its commands
  (added 2026-10-21). A `commands.jsonl` that shrinks is read again from its start.
- **Ready.** Once the session is live and has its first channel (`Staging.liveSeconds` and
  `channelSeconds`), or when those run out, the app writes `<dir>/ready.json`:
  `{"ok":true,"pid":123,"window_number":456,"scale":2.0,"error":""}`.
- **Commands.** The client appends one JSON object per line to `<dir>/commands.jsonl` once
  `ready.json` is there. The app reads new complete lines every 100 ms and runs them one at a
  time, in order. Only the commands that use the window (`snapshot`, `ax`, `key`, `type`,
  `press`, and a `stage` that resizes) are refused for want of one. Every command
  has an integer `id`, unique in the run, and a `cmd`.
- **Answers.** For each command the app writes `<dir>/out/<id>.json` by writing a temporary
  file and renaming it, so a reader never sees half an answer:
  `{"id":7,"ok":true,"error":"","files":["out/7.png"],"result":{…}}`. Paths in `files` are
  relative to `<dir>`. A command the app cannot parse or run is answered `ok:false` with the
  reason in `error`, and the next command still runs.

| `cmd` | fields | answer |
|---|---|---|
| `stage` | `stage`: a `ShotStage` object (`settle` applies; `window` resizes) | `result`: what was applied, as the log lines say it |
| `snapshot` | `settle` (seconds, default 0); `window`: `main` or `settings` (added 2026-10-22) | `out/<id>.png` at the backing scale, the open popover and sheet drawn in (added 2026-10-22); `result`: `{"scale":2,"width_pt":…,"height_pt":…,"regions":{…}}`, the regions as `regions.json` gives them |
| `state` | | `result`: the view state (place, selection, tuned Hz and mode, channel id, open sidebar rows, inspector shown, zoom, focused control, notices on screen, popover open, the assistant panel open; from 2026-10-22 also mute, volume, sink, window size, the filter's caret, Settings open, the alert, the charts' span, the assistant's turns and buttons, the tooltip) |
| `ax` | `window`: `main` (default), `settings`, `popover` or `sheet` (added 2026-10-22) | `out/<id>.ax.txt` (ML-5's tree, values quoted with `\`, `"` and newlines escaped); `result`: as `snapshot`'s (changed 2026-10-21, so the checker can mask live regions in the tree) |
| `key` | `keys`: `"cmd+g"`, `"escape"`, `"down"`, `"return"` | sent to the key window as key down and up |
| `type` | `text` | one key event per character to the key window |
| `press` | `identifier` (ML-5); `alert.<title>` for a sheet's button (added 2026-10-22) | `accessibilityPerformPress` on the element with that identifier, in the main window, then Settings |
| `hover` | `identifier`, or `x` and `y` (added 2026-10-22) | the pointer moved there; `result.tooltip` |
| `click` | `identifier`, or `x` and `y`; `button` (added 2026-10-22) | a mouse down and up there |
| `menu` | `menu` (`View>Show Assistant`), `read` (added 2026-10-22) | the item pressed; `result`: `title`, `enabled`, `checked`, `items` |
| `wait` | `seconds` | answered after that long |
| `quit` | | answered, then the app terminates |

Built 2026-10-21 to this table with no field changed. Facts found on the way: keys must be posted
to the app's queue (`NSApp.postEvent`), because `sendEvent` skips the local key monitors and
Return never reached the filter; `ax` must read through `AXUIElement` on the app's own pid,
because the `NSAccessibility` walk from the window sees none of SwiftUI's elements; a command-file
run neither activates the app nor orders its window front. `ShotStage` gained `assistant`,
`focus_filter` and `channels_picker`; hovering a point and opening Settings are left.

### ML-4 `[x]` `leyshots check`

A sibling of `leyshots run` reading `app/checks/scenes.yaml` (the site scene's inputs, plus
`app`, a list of ML-3 commands, since `steps` stay the `ley` steps, and `sizes`, the window sizes
to take). For each scene and size it starts the daemon and the app (`open -g -n`, so nothing takes
focus), runs the commands, collects the pictures, state and trees into
`tmp/checks/<scene>/<W>x<H>/`, compares each picture and tree with its golden and each `state`
with its `expect`, and prints one line per artefact or expectation: `ok`, `diff 2.4 %`, `new`,
`recorded`, `fail` or `error`, and the path. A snapshot or an `ax` command takes `mask`, the
regions left out of the comparison, by default `spectrum`, `waterfall`, `readings` (the
inspector's figures and audio ladder), `transmissions` (its log's rows), `log_day` (the day over
them) and `heard` (the tone last heard), because each changes between two runs of one scene; in a tree, an element whose frame lies inside a masked region has
its value and frame replaced by `<masked>`, and a run of identical masked lines becomes one. The pixel diff is Go (`image` is already in
`leyshots`): per-channel tolerance, an anti-aliasing allowance, a red diff image. `make app-check`
runs it; `ONLY=` and `RECORD=1` as `make shots` has them. Both `check` and the site's `run` launch a copy
of the bundle under `com.leysdr.app.staged` (`tmp/staged-app/`), because a staged run under the
app's own identifier wrote a window frame into the person's defaults.

### ML-5 `[x]` The accessibility tree

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

### ML-8 `[x]` The skill and the hooks

- `.claude/skills/app-check/SKILL.md`: when to run `make app-check`, how to read its lines,
  how to look at one picture or diff, the never-re-record rule, and what to put in a handover.
- `../dev/swift-style.md`, section 12, rewritten for the Mac: the "read the diff by eye" list
  becomes "run `make app-check`", and "state what was not compiled" becomes "state what no check
  covers".
- `.claude/settings.json`: allow `make app-check`, `make app`, `make app-lint`, `open -g`,
  `pkill -x LeylineApp`.
- A PostToolUse hook on edits under `app/Sources` running `swift build` for the app and
  `scripts/check-theme.sh`: seconds, not the full loop.

Built 2026-10-22, not ticked until an agent has used it on ML-9's first scenes:

- `.claude/skills/app-check/SKILL.md`: when to run `make app-check [ONLY=…]`, each status and
  where its artefacts are, reading a picture and its diff image, writing a scene, the rules
  (no re-recording to pass, kill only pids you launched, the Accessibility grant) and the
  handover. ML-7's review questions are not in it, because `app/checks/review.md` does not exist.
- `leyshots check --hold --only <scene>` for exploring by hand: the scene runs at its first size,
  then the app and its daemon stay up, and leyshots prints the pid, the log, the daemon's socket,
  the command file and the next free id, until a `quit` command or an interrupt (SIGTERM too).
  Its closing quit takes the id after the last one used. Tried on radio-2m: a `state` sent by
  hand was answered, and a `quit` ended the hold and the daemon.
- Section 12 and AGENTS.md's convention now say: run `make app-check`, add or extend a scene,
  state what no check covers; the container's limits stay as a caveat.
- `.claude/settings.json` (`.gitignore` now ignores `.claude/*` but it and `.claude/skills/`)
  allows `make app-check`, `make app`, `make app-lint`, `make app-test`, `make app-bundle` and
  `go/bin/leyshots`. `open -g` and `pkill -x LeylineApp` are left out: `leyshots` opens the app
  itself, and a kill by name would reach the person's own app. The hook is
  `scripts/claude-app-hook.sh`: about 0.2 s for a file elsewhere; for one under `app/Sources`
  an incremental `swift build` (5.6 s with nothing to compile, 16 s after a change) and the theme
  gate; on a failure it prints the first 30 error lines and exits 2. A build error and a theme
  hit were tried in a scratch package, and an edit in a worktree builds that worktree.

### ML-9 `[ ]` Burn down the Unverified lists

Turn each item under "Unverified on the Mac" in `app.md` (U4 onward, Settings, the assistant
panel, the window following the radio) and `ai-features.md` into a check scene, a `state` or
`ax` assertion, or a review question, and run them. Fixes are filed as new items in those plans.
Items that need the real radio, real audio or a person's ear stay on a shorter list, named.

The inventory (2026-10-22, kept in `tmp/ml9-inventory.md` on the build Mac) splits the lists into
238 checkable facts: 58 a scene can check today, 172 after a harness addition, 5 that need a
person or hardware, 3 obsolete. Its numbering (U4.02, P.45, H3, F2) is used below. Four parts:

- **ML-9a `[x]` The scenes that need nothing new.** `sidebar-rows`, `filter-goto` (extending
  `goto-bookmark`), `plan-picker`, `bookmark-fields`, `heard-tones`, `chirp-import` (its first
  half), `scan-hits` (without the sweep's words), `assistant-absent`. Each fault found is fixed
  in its own commit when it is small and plainly a bug, and filed in `app.md` otherwise.

  Built 2026-10-22, not ticked until the owner has read the findings: the eight scenes, with
  `filter-goto` as `goto-bookmark`'s second half. About 55 facts are checked; `app.md` marks
  each with its scene and lists what was found. Fixed on the way: the filter's placeholder and
  the spectrum's dB labels (the two layout faults above), Go to… from the Library, the
  pencil's field taking the focus, a plan pick or a band row on a file radio answering
  `FREQ_OUT_OF_RANGE`, the Tone and Note placeholders' ink, and hit identifiers that moved from
  run to run. The app's side of the harness gained `press` on a text field (the focus), `state`'s
  `heard` and `hits` and a focused SwiftUI field's identifier, and an `ax` that leaves a text
  field's top and height out. What the scenes could not reach, for ML-9b and ML-9c:
  - the words over the squelch track follow the noise between overs and no region masks them,
    so most scenes turn the squelch off and `heard-tones` asserts through `state` (a `squelch`
    region in `leyshots`'s list and its default mask);
  - `leyshots`'s stage has no `assistant`, `channels_picker` or `focus_filter` key, though the
    app takes them;
  - keys go to the main window, so a popover's key monitor never sees Up and Down, and the
    window's picture leaves popovers out (the plan picker's highlight and scroll);
  - `ax` is now and then answered no window, or the application in its place, by a trusted
    process whose window is on screen, for minutes at a time (the locked screen, ML-9c found);
  - nothing sets a `ley` value mid-scene (H6), and the arrows beside the frequency read the
    person's ⇧, so scenes step with → instead.
- **ML-9b `[x]` The harness from outside the app** (Go, `leyfix`, the daemon): the AI provider
  stub as a scene key (H3, about 70 facts: `LEY_ASSISTANT_SCRIPT`, a `ley` that answers
  `worker check`, `ley ai add` and `use` steps); `ley`, `ley_bg`, `kill` and `file` in a scene's
  `app` list, run mid-scene against its socket (H6); `daemon stop|start` (H9); `expect_log`
  against `run/app.log` (H7); the fixtures `scene_gmrs`, `scene_vhf20`, `scene_wx` and a CHIRP
  file with no Frequency column (F1–F4); a sweep that lasts seconds on a file device (H10).

  Built 2026-10-22, not ticked until ML-9d's scenes have run on it (no scene uses it yet, and
  nothing of it has run against the app): the keys and commands are in the header of
  `app/checks/scenes.yaml` and the skill's "Writing a check scene".
  - `ai: {script, model, provider, key}` (H3): the scene's daemon gets `LEY_ASSISTANT_SCRIPT`,
    `LEY_ASSISTANT_RECORD` (`run/ai/record.jsonl`) and, as `LEYLINE_LEY`, a shim in `run/ai/`
    that answers `worker check` as accepted and hands every other verb to the real `ley`; a
    made-up key is added on stdin and the model chosen before the app starts. `daemonrun` already
    keeps keys in the daemon's own data directory (`LEYLINE_SECRETS=file`), so nothing reaches the
    keychain or a provider. The first script is `app/checks/assistant/hello.script`. Tried with a
    real `leylined` and `ley ask`: the key read `accepted`, the turn played the script.
  - `ley`, `ley_bg`, `kill`, `file` (H6) and `daemon` (H9) run in the runner, in order with the
    app's commands, under the same ids. `ley` checks `expect_exit` (default 0) and
    `expect_stdout`; `kill` sends SIGINT and fails when the process had exited already or outlives
    10 s; a `ley_bg` still running at the end is interrupted before the app quits. `daemon stop`
    is `daemonrun.Daemon.Halt`, `start` is `Resume` on the same socket, store, data and log, then
    the fixtures played again, because a daemon keeps no file device across a restart.
  - `expect_log` on `state` and `wait` (H7): patterns against `run/app.log` from the moment the
    command before was sent; `!` negates; a matching line is printed with its timestamp.
  - F1–F4 in `leyfix` (scenes set, cached as the others are): `scene_gmrs` (462.650 MHz, 480 kSPS,
    channels 5, 1 and 21 in overs, 30 s, 29 MB); `scene_vhf20` (153.200 MHz at 21 MSPS, so the
    capture is 142.7 to 163.7 MHz and every carrier sits inside the 45 % edge: 146.520, 146.940,
    MURS 1 and 4, marine 16, NOAA WX2; 7 s, 294 MB, about 12 s to generate); `scene_wx` (162.475
    MHz, the floor alone) and `scene_wx_on` (WX2 and WX1 broadcasting), 19 MB each. All pass
    `leyfix check`. `fixtures/chirp/nofreq.csv` has no Frequency column. 20 MSPS at 152.6 MHz,
    the inventory's choice, put 162.400 outside the 45 % edge that `leyfix` holds every scene to.
    Whether a debug `leylined` keeps up with 21 MSPS in real time is unmeasured.
  - H10: `leylined --file-scan-dwell MS` raises the dwell of a scan on a file device to MS when it
    asks for less; other drivers keep theirs (`ScanSweepTests`). A check scene sets it with
    `sweep_dwell` in seconds. The sweep stays one step, so the "7 steps" words of U5.03 are still
    out of reach: a file device that retunes needs an oversampled source and a
    mix-filter-decimate chain (`ScanSweepTests`'s header), which is not small.
- **ML-9c `[x]` The harness inside the app**: the Settings window in `stage`, `ax`, `snapshot`
  and `state` (H4); `state` fields for mute, volume, the sink, window size, the caret, an alert,
  the assistant's turns and buttons, the waterfall's view and a tooltip (H5); `click` and `hover`
  for what `press` cannot reach (H1, H2); `menu` (H8); alert sheets (H13); `relaunch` (H11).

  Built 2026-10-22, not ticked until the owner has read it: every item above, the stage keys
  ML-9a missed in `leyshots` (`assistant`, `channels_picker`, `focus_filter`, and `settings`),
  and a `squelch` region in the default mask, so `heard-tones` takes a tree and neither it nor
  `bookmark-fields` needs a raised threshold. Scenes: `plan-picker` (Up in the popover, its
  picture and tree), `goto-bookmark` (`filter_caret`), `settings-sheet` (Settings, a Remove
  sheet read and cancelled), `pointer-and-menus` (hover, a click on the waterfall, View ▸ Show
  Assistant, the assistant's turns through `state`, `relaunch`). Found on the way:
  - The two flakes ML-9a met had causes. A tree differing by a point (`inspector.identity` 116
    or 117 pt) came from the inspector's Tone and Note fields taking the next bookmark's text in
    place during a retune: AppKit then measured them, on about one change in ten, at the 15 pt of
    the 12.5 pt field closing in the same pass (seen with a frame-change log and a debugger on
    `-[NSTextField setFrameSize:]`, whose caller was SwiftUI's display-list geometry from
    `AppKitPlatformViewHost.intrinsicLayoutTraits`). The fields are now made new for each
    bookmark (`.id`); 14 runs of `plan-picker` and `chirp-import` showed no 15 pt field. That
    also fixed a stale draft: a refused tone (`D024N`) stayed in the field after a tune to
    another bookmark, and `bookmark-fields`'s `tuned` golden had recorded it.
  - "`ax` answered no window, or the application, for minutes" was the screen being locked:
    `_NSAccessibilitySafeToVendElement` refuses every element under the lock's shield, and the
    API substitutes the application. The walk now reads the window's objects when the API
    answers no window, which gives the same tree once a scroll bar's parts, the window's own
    buttons' insides, its title and a slider knob's frame are left out of both readings (the
    goldens were pruned to match by a script, not re-recorded). The application's window list
    also leaves out windows on Spaces not shown (its disassembly asks `currentManagedSpaces`),
    which the same reading covers.
  - Keys now go to the open popover, and the filter's key monitor takes the window being typed
    into when the app is not active (an inactive app has no key window), so a check run's Up
    and Down reach the plan picker. A region measured under a view that `.id` makes new kept
    its old, dying view and dropped out of `regions.json`; the probe keeps the one in a window.
  - What is left: a snapshot draws a sheet's glass as the window background of its appearance
    and a popover without its arrow, because the window server draws both; an open menu is not
    drawn; the menu items' titles are read once (`Show Assistant` stays so while the panel
    shows, as the Commands body's comment says).
- **ML-9d `[ ]` The remaining scenes**: `settings-ai`, `assistant-conversation`,
  `assistant-cards`, `assistant-view-tools`, `follow-terminal`, `follow-assistant`,
  `follow-launch-and-daemon`, `gmrs-plan`, `vhf-wide`, `sweep-lifecycle`, `change-note`,
  `alert-and-menus`.

ML-9a and ML-9b run side by side; ML-9c follows ML-9a in the same tree, since both edit the app;
ML-9d needs all three. Light appearance stays out (Decisions: dark only).

### ML-10 `[ ]` Snapshot tests of single views (later, if ML-4 is too slow)

Offscreen `NSHostingView` renders of single views from a fixture `AppSession`, in a macOS-only
test target. Only worth it if a whole-window run per check is too slow for the edit loop; it
first needs an `AppSession` that can be built without a daemon, which is its own design question.

## Order

ML-0, then ML-1 and ML-2 together, ML-4 on the existing stage, ML-3, ML-5, ML-6 (which can start
any time), ML-8, then ML-9 as the first real workload. ML-7 and ML-10 when ML-9 shows the need.
