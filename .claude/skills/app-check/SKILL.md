---
name: app-check
description: Check the Leyline Mac app on this Mac with `make app-check` (pictures, accessibility trees and view state against local goldens) and drive a staged copy of the app by hand. Use after changing anything under app/Sources, before handing over app work, and whenever you need to see or verify what the Mac app shows.
---

# Checking the Mac app

Each scene in `app/checks/scenes.yaml` runs against its own `leylined --no-hardware` playing
synthetic IQ, in a staged copy of the app (`tmp/staged-app/Leyline.app`, bundle id
`com.leysdr.app.staged`) that `leyshots` drives over a command file. Nothing touches the default
socket or the person's own app and settings. `docs/dev/app.md`, "Staged runs" and "The command
file", is the full reference.

## When to run what

**Every edit under `app/Sources`**: the PostToolUse hook (`scripts/claude-app-hook.sh`) runs an
incremental `swift build` and `scripts/check-theme.sh`. Fix what it prints before going on.

**Then the tiers: smoke, then targeted, then full** (`docs/plans/mac-loop.md`, ML-11).

| tier | command | runs |
|---|---|---|
| smoke | `make app-check-smoke` | the scenes marked `smoke: true`: radio-2m, identifiers, goto-bookmark (about 35 s) |
| targeted | `make app-check-affected` (`BASE=<ref>`) | the scenes whose `covers:` match a file changed under `app/Sources` or `app/checks` since the merge base with main, uncommitted and untracked files included; a shared file (`Theme.swift`, `AppSession.swift`, `Staging.swift`, the control code, the file's `shared:` list) brings in the smoke scenes as well. `make app-check ONLY=a,b` still vets one feature by name |
| full | `make app-check` | every scene (about 12 minutes on 2026-10-22); `JOBS=N` runs N side by side, the `serial: true` scenes (vhf-wide, the sweeps) alone. Leave it at 1 until runs at 3 show no flakes |

The targeted tier prints, before its lines, `since <commit>: …`, one `affected <scene>: <files>`
line per scene and `uncovered: <file>` for a changed file no scene covers: name that file in the
handover, or give the scene that checks it a `covers:` glob. The merge base with main can be far
back on a long branch; `BASE=HEAD~3` (or the batch's base) narrows it.

**Before handing over**: `make app-check` (every scene) and `make app-lint`. The make targets
rebuild `ley`, the engine and the bundle first, so they always check the code as it is, and run
under `caffeinate -i`, so the Mac does not sleep through them. The scenes' daemon is always the
release `leylined` (`make swift-release`): a debug one plays `scene_vhf20`'s 21 MSPS at about
half of real time. Running `go/bin/leyshots check` by hand takes the debug one unless
`LEYLINED_BIN` names the release build. `go/bin/leyshots check --list` lists the scenes and their
tiers.

## The batch loop

Implementers work in parallel worktrees: they build and run `make app-test` and the lints, never
a full check, because one run at a time owns the staged app and its Accessibility grant belongs
to the main checkout's copy. The coordinator merges the batch. One verify agent then runs the
full check, sorts every diff into a regression, an intended change (re-recorded, and named) or a
new finding, and fixes or files each. It loops on the smoke and targeted tiers until a full run
is clean, and a review of the batch follows.

## Reading the output

One line per artefact or expectation: `<status> <scene> <W>x<H> <item> <detail> <path>`. The
item is a snapshot's name, `<name>.ax` for a tree, `state#<id> <path>` for an expectation and
`<cmd>#<id>` for a command the app refused.

| status | means | do |
|---|---|---|
| `ok` | matches; a snapshot shows its % of changed pixels, under the scene's threshold (default 0.1 %) | nothing |
| `diff 2.40 %` | the picture changed more than the threshold; the path is the diff image | look at it (below) |
| `new` | no golden yet; the path is the picture or tree | look at it, then record it if it is right |
| `recorded` | `RECORD=1` wrote the golden | name it in the handover |
| `fail` | a `state` value (`got … want …`), a tree that differs (the path is `<name>.ax.diff`), a picture of another size, or a command the app answered `ok:false` (`the app: …`) | read the detail |
| `error` | the run could not check: the app never became ready, exited, or did not answer | read `run/app.log` |

After each scene and size's lines comes its time:
`time     radio-2m 1440x820 34.2 s  daemon 3.1 s, ready 6.0 s, commands 24.1 s, quit 1.0 s`, the
daemon set up, the app from launch to `ready.json`, the commands and the quit. One that took over
1.5 times its median in the earlier runs (three at least) ends `; slower than usual (median
20.1 s)`: look at its `run/app.log` for what waited. `tmp/checks/history.jsonl` keeps the last 20
runs' times.

The last line is `N checked: …; <total> s, slowest <scene> <size> <time>, … (three);
tmp/checks/summary.json`, naming any scene slower than usual before the path; `summary.json`
holds every result and time. The run exits 1 on any `diff`, `fail` or `error`.

Artefacts, in `tmp/checks/<scene>/<W>x<H>/`:

- `<name>.png`, the window at the backing scale (2880 × 1640 px for 1440 × 820 pt), and
  `<name>.diff.png` when any pixel changed.
- `<name>.ax.txt`, the tree; `<name>.masked.ax.txt` and `<name>.golden.masked.ax.txt`, the two
  sides as compared; `<name>.ax.diff` when they differ.
- `state-<id>.json`, each `state` answer.
- `run/`: `app.log` (one line per thing the window did), `app.stderr`, `leylined.log`,
  `steps.log` (the scene's `ley` steps), `stage.json`, `regions.json`, and `control/` (the
  command file and the app's answers).

Goldens are in `tmp/goldens/<macOS major.minor>-<arch>/<scene>/<W>x<H>/`, local to this Mac
and never committed.

## Looking at a picture

Read the PNG with the Read tool. For a `diff`, read `<name>.diff.png`: red pixels changed, grey
is masked, everything else is the golden faded. Then read the golden and the new picture to see
what the red is. The masked regions (`spectrum`, `waterfall`, `readings`, `transmissions`,
`log_day`, `heard`, `squelch`) move between runs and are never compared, so a change inside one is checked
only by looking at the picture.

Decide whether the change was intended. If not, fix the code. If it was, re-record that scene
only: `make app-check ONLY=<scene> RECORD=1`.

## Writing a check scene

Add or extend a scene for each behaviour you change. The header of `app/checks/scenes.yaml` is
the format: a site scene's inputs (fixtures, clock, bookmarks, `ley` steps, a stage applied at
launch), `sizes`, and `app`, the commands in order.

```yaml
  - name: filter-focus
    covers: [SidebarView.swift, Sidebar.swift]
    fixtures: [{name: scene_2m}]
    clock: "19:42"
    bookmarks: ../../site/shots/home.csv
    stage: {place: radio, settle: 3}
    app:
      - {cmd: key, keys: cmd+g}
      - {cmd: state, expect: {focused: sidebar.filter}}
      - {cmd: snapshot, name: focused}
      - {cmd: ax, name: focused}
```

- `covers` lists globs of the files under `app/Sources` whose behaviour the scene checks: the
  views it presses and pictures, and the façade rules behind them. A glob without a `/` matches
  a file's name in either target (`SidebarView.swift`). `make app-check-affected` runs a scene
  when one of its globs matches a changed file, and `TestCheckCoverage` (`make go-test`) fails on
  a file in `LeylineApp` no scene covers. `smoke: true` and `serial: true` are the tiers above.
- `expect` maps a dotted path into the `state` answer to a value; the keys are in
  `docs/dev/app.md`, "The command file".
- `mask` on a `snapshot` or `ax` replaces the default list of masked regions; `[]` compares
  everything.
- `press` and the tree's `id=` use the views' accessibility identifiers, listed in
  `docs/dev/app.md`; `grep -rn 'accessibilityIdentifier(' app/Sources/LeylineApp` finds them in
  the code. A view without one cannot be pressed: give it one.
- A file radio tunes only inside the capture it was recorded with, so a scene that tunes must
  stay inside its fixture's span. `scene_vhf20` holds 2 m, MURS, marine and NOAA WX2 in one
  capture, `scene_gmrs` the GMRS 462 MHz channels, `scene_wx` and `scene_wx_on` the NOAA channels
  silent and broadcasting.
- `ley`, `ley_bg`, `kill`, `file` and `daemon` in `app` are run by `leyshots`, not the app: a
  terminal's `ley` mid-scene against the scene's daemon (`expect_stdout`, `expect_exit`), a
  long-running one started and later interrupted, a file of the run directory matched
  (`contains`), and the scene's daemon stopped and started again. Their output is in
  `run/steps.log` and `run/ley_bg-<id>.log`.
- `expect_log` on a `state` or `wait` matches `run/app.log` from the command before onwards; a
  `!` pattern must not match. The matched line carries its timestamp, so two of them give a
  duration.
- `ai: {script: assistant/<name>.script}` gives the scene an assistant on a scripted model with a
  made-up key, so the toolbar toggle, the column and Settings' Features and Usage draw. Write the
  script as JSON lines (`{"text": …}`, `{"tool": …, "args": …}`, `sleep_ms`, `usage`);
  `run/ai/record.jsonl` holds what each call was sent. Nothing reaches a provider.
- `sweep_dwell: 4` makes a Scan band on the file radio last about four seconds, long enough to
  press Stop or click elsewhere while it sweeps. It is still one step.
- A snapshot draws an open popover or sheet in; `ax` with `window: popover` or `sheet` reads it
  alone. Keys go to the sheet, else the popover, else the key window, so the plan picker sees
  Up and Down. A sheet's button is `press` `alert.<title slugged>` (`alert.cancel`), and
  `state.alert` gives its title, message and buttons.
- `stage: {settings: true}` opens Settings; `snapshot` and `ax` take `window: settings`, `press`
  finds Settings' identifiers, and `state.settings_open` says whether it shows.
- `pick` chooses an item of a pop-up (a SwiftUI `Picker`) or a segmented control by its title
  (`{cmd: pick, identifier: settings.ai.feature.assistant.model, text: claude-opus-5-5}`), without opening its
  menu. A `press` on a text field focuses it in its own window, so a Settings field is typed
  into there; a `press` on a disabled element fails (`… is disabled`). ⌘W closes nothing in a
  check run (the app is never active, so File ▸ Close has no key window): close Settings with
  `stage: {settings: false}`.
- `hover` (an identifier, or `x` and `y` in points from the window's top-left corner) rests the
  pointer and answers the tooltip, which `state.tooltip` repeats; `click` does a mouse click
  there (`button: right`) for a chart point or anything `press` cannot reach; `menu` presses a
  menu bar item by its titles (`View>Show Assistant`), or with `read: true` describes it, and
  takes `expect` on its `enabled`, `checked` and `items`; `relaunch` quits the app and starts
  it again on the same daemon and staged defaults, with an optional `stage`.
- `state` also gives `muted`, `volume`, `sink`, `window`, `filter_caret`, `view_window` and,
  while the panel shows, `assistant` (its turns, field, focus and buttons); `docs/dev/app.md`,
  "The command file", has every key.

```yaml
  - name: follow-terminal
    fixtures: [{name: scene_2m}]
    stage: {place: radio, settle: 3}
    app:
      - {cmd: ley_bg, id: tune, args: [tune, "146.94"]}
      - {cmd: wait, seconds: 2, expect_log: "following chan_"}
      - {cmd: state, expect: {tuned_hz: 146940000}}
      - {cmd: kill, id: tune}
      - {cmd: ley, args: [state], expect_stdout: "146.940 MHz"}
```

The first run prints `new`. Read the picture and the tree, and record them only when they show
what the scene should.

## Driving the app by hand

To explore a state no scene reaches yet, hold a scene's app open. Build once with
`make app-check ONLY=<scene>`, then run, in the background:

```sh
go/bin/leyshots check --hold --only radio-2m --out tmp/explore
```

After the scene's commands it prints, on stderr, the app's pid and log, the scene's daemon
socket, the command file and the next free id, and waits:

```sh
C=tmp/explore/radio-2m/1440x820/run/control
echo '{"id":4,"cmd":"key","keys":"cmd+g"}' >> $C/commands.jsonl   # answered in $C/out/4.json
echo '{"id":5,"cmd":"snapshot"}' >> $C/commands.jsonl              # the picture is $C/out/5.png
echo '{"id":6,"cmd":"quit"}' >> $C/commands.jsonl                  # ends the hold and the daemon
```

Each id is used once. `ley --socket <the printed socket> …` reads the scene's daemon. Without
`--out`, the hold writes over that scene's artefacts in `tmp/checks`.

## Rules

- **Never re-record a golden to make a check pass.** `RECORD=1` is for a change you intended,
  scene by scene, and every re-recorded golden is named in the handover with the reason.
- **Kill only the pids you launched**: the app's pid in the hold's line or `ready.json`, and the
  `leyshots` you started. Never `pkill` or `killall` by name, never `launchctl`, never the
  default socket: the person's own Leyline app and daemon may be running on this Mac.
- **Accessibility is granted once, by the person**, to `tmp/staged-app/Leyline.app` in System
  Settings > Privacy & Security > Accessibility. An `ax` line `fail … the app: …` that names the
  permission means the grant was lost: stop and ask for it to be added again.

## The handover

- The summary line of the last `make app-check`, and each line that is not `ok`, with why.
- The goldens re-recorded, by scene, and why.
- The scenes added or extended.
- What no check covers: behaviour the change touches that no scene reaches (audio, a real
  radio, a masked region, a path with no key or identifier yet), and each `uncovered:` file
  the targeted tier named.
- A scene the run named slower than usual, if it stayed so on a second run.
