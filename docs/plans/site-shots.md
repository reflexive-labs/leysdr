# Site screenshots

`make shots` produces the images for leysdr.com on a Mac. Each run uses the same layout, size,
state and theme. The images come from the real app and the real `ley`, connected to a daemon
that plays synthetic IQ. They are published as GitHub release assets and are never committed.
The asset list is the site's v3 screenshot brief. It lives outside this repository, and this
page covers each of its items.

## Decisions (2026-10-03)

- **Synthetic signals only.** `leyfix` generates each scene's IQ from a fixed seed, so a run
  needs no stored recording. Every scene's alt text ends with "Simulated signals."
- **The images are release assets.** Each refresh is a new release tagged `shots-YYYY-MM-DD`.
  The release holds every image plus `shots.json`. Shots that were not refreshed are copied
  forward from the previous `shots-*` release, so one tag is always a complete set.
  leysdr.com's build pins a tag and runs `gh release download <tag> --repo reflexive-labs/leysdr`.
  This repository holds only the inputs: `site/shots/scenes.yaml`, the scene CHIRP CSV and the
  tools.
- **A file device can carry a display name.** A sidecar's optional `label` replaces the
  filename as the device's `model`, so the toolbar can read "NESDR SMArt v5".
- **The daemon can shift its wall clock.** `leylined --wall-clock 19:42` offsets the time
  every capture anchor is dated from. Transmission times and recording times then read as that
  evening. Retention cutoffs keep the real clock.
- **Terminal shots are PNGs** rendered from the captured pane in the site's terminal theme.
- **Out of scope:** the light-mode hero copy (`Theme.swift` has no light palette),
  `ways-assistant.png` (Claude Desktop), hardware photos, `dmg-window.png`, `og-image.png` and
  both videos.

## How a run works

`go/cmd/leyshots` reads `site/shots/scenes.yaml`. For each scene it:

1. generates the scene's fixtures into `~/Library/Caches/leyline-shots/iq/` with `leyfix`
   (`$XDG_CACHE_HOME/leyline-shots/iq/` or `~/.cache/leyline-shots/iq/` elsewhere), unless a
   copy there matches what `leyfix generate --dry-run` prints: the same format, rate, centre,
   length, label and generator record, and a sample file of that size;
2. starts its own `leylined --no-hardware` with a socket, pidfile, store, recordings directory
   and log under `tmp/shots/run/<scene>/`, and `--wall-clock` set when the scene gives a `clock`.
   One daemon per scene, so no state carries from one shot to the next. The start is
   `go/internal/daemonrun`, which the agent evals use too;
3. points `LEYLINE_BOOKMARKS` at `tmp/shots/run/<scene>/bookmarks.json`, imports the scene's
   bookmarks into it with `ley bookmarks import` (a CHIRP CSV, `site/shots/bookmarks-2m.csv` for
   the 2 m scenes), attaches each fixture with `ley play --persistent --loop`, and runs the
   scene's `ley` steps (stop, scan, record), logging them to `steps.log`;
4. waits the scene's `settle` time, so the waterfall has history and the logs have entries;
5. takes the shot (see below), crops it, and writes `tmp/shots/<asset>.png` and its entry in
   `tmp/shots/shots.json`.

`make shots` runs every scene, and `make shots ONLY=app-radio-2m,inspector-tone` runs a subset.
`make shots-publish ONLY=…` takes the reviewed images from `tmp/shots/`, merges them with the
latest `shots-*` release, compresses them with `oxipng` (losslessly, because quantising bands
the waterfall gradients), checks that the manifest matches the files, and creates the release.

macOS asks the terminal that runs `make shots` for Screen Recording permission the first time
`screencapture` reads another app's window.

### App shots

`leyshots` launches `app/dist/Leyline.app` with `LEYLINE_SOCKET`, `LEYLINE_BOOKMARKS` and
`LEYLINE_APP_STAGE=<stage.json>` set. The stage file gives the window size in points, the place
(Radio or Library), whether the inspector is shown, the expanded band, the selected bookmark or
Library part, and an optional CHIRP file to import. The import goes through the same code path
as File > Import CHIRP…, so the notice shows real counts.

With `LEYLINE_APP_STAGE` set, the app:

- skips the splash and the mark's flight to the toolbar;
- applies the stage once the daemon state has arrived, and never writes `UserDefaults`, so a
  staged run leaves the owner's last band, place and inspector setting alone;
- once the stage is applied and the spectrum has drawn for `settle` seconds, writes
  `regions.json` beside the stage file. It holds the window number and the frames, in window
  points, of `window`, `sidebar`, `inspector`, `toolbar`, `waterfall` and `library`.

`leyshots` captures with `screencapture -o -x -l <window>` (no shadow, no sound; Retina gives 2×)
and crops in Go from a region's frame × (image width ÷ window width in points). A crop is one
region, the union of several, or a box of a given size at an anchor inside that union
(`ways-app` is 480 × 300 pt at the top right of the waterfall and inspector). `leyshots` gives
the app the scene's `settle` plus 30 s to write `regions.json`, then stops with the path of the
app's log (`LEYLINE_APP_LOG`, `tmp/shots/run/<scene>/app.log`). With the variable unset, nothing
in the app changes.

### Terminal shots

Each terminal scene runs `ley` in its own tmux server (`tmux -L leyshots`) at a fixed size,
with no status line. Each pane is a `/bin/sh` with a `$ ` prompt, and the scene's commands are
typed at it, so the shot shows the command line. A scene can split the window, as
`ways-terminal` does. `leyshots` reads each pane with `tmux capture-pane -e -p` once the scene
settles. `scripts/ansi2html.py --palette site` converts the panes, and they are laid out in
character cells, with a 1 px rule in the column or row tmux leaves between two panes, in the
site's terminal theme:

| role | colour |
|---|---|
| background | #090B0C |
| foreground | #9BA1A6 |
| bold | #E7E9EA |
| green | #2FB6A3 |

The font is SF Mono 13 (`ui-monospace`) on 16 px rows. A short Swift script,
`scripts/render-html.swift`, draws the page in a WKWebView at 2× and writes the PNG, at a width
of 0.6 em per column plus 16 pt either side. On Linux, `leyshots` stops at the HTML, which lets
the terminal path be tested in CI.

## Scene fixtures

These are `leyfix` catalog entries in a `scenes` set. `leyfix generate --set scenes` writes
them, and `make fixtures` leaves them out because they are large. Each entry carries
expectations, so `leyfix check` shows that the daemon hears what the shot claims. Voice is a new
`voice` audio source: speech-shaped noise from 300 to 3000 Hz with a syllable-rate envelope and
pauses, seeded, so a keyed carrier looks like speech on the waterfall rather than a single tone
and its sidebands. All callsigns are N0CALL-n.

| fixture | centre | contents |
|---|---|---|
| `scene_2m` | 146.400 MHz | 146.520 simplex, PL 100.0, keyed in overs (the hero); 146.940 repeater output, PL 127.3; 147.180 net, DCS 023; 145.230 and 147.330 with short keyups. Labelled "NESDR SMArt v5". The loop is long enough that every carrier has at least three overs in it. |
| `scene_net` | 147.180 MHz | One net: eight overs of 4–30 s separated by 6–8 s gaps, so a gated recording with the default 5 s hang cuts one part per over. |
| `scene_scan` | 146.000 MHz | 146.520 PL 100.0, 146.940 PL 127.3, 147.180 DCS 023 and 145.230 on the air throughout; 144.390 keyed for 25 ms in every 210 ms, so the scan sees it in 1 of 4 looks. |
| `scene_aprs` | 144.390 MHz | AFSK packets from N0CALL-1 to N0CALL-7 with positions, symbols and comments, spread over the loop. |
| `scene_ais` | 162.000 MHz | GMSK position reports from five vessels with made-up MMSIs, all on AIS 1 (161.975 MHz): a decode job listens on its recipe's first frequency only, so a report on AIS 2 would never be heard. |
| `same_alert` | 162.400 MHz | The existing weekly test, generated by the scene at 960 kSPS for 10 s. |

Each scene fixture is cu8 at its own rate and length, on a -40 dBFS floor that spans a few
8-bit steps. `leyfix check` passes every one (2 min 41 s for the set in the Linux container,
2026-10-03).

| fixture | rate | length | size |
|---|---|---|---|
| `scene_2m` | 2.88 MSPS | 50 s | 288 MB |
| `scene_net` | 480 kSPS | 163 s | 156 MB |
| `scene_scan` | 5 MSPS | 20 s | 200 MB |
| `scene_aprs` | 960 kSPS | 21 s | 40 MB |
| `scene_ais` | 960 kSPS | 20 s | 38 MB |
| `same_alert` | 960 kSPS, cf32 | 10 s | 77 MB |

`scene_2m` is 2.88 MSPS rather than 2.4 because 145.230 and 147.330 lie 1.17 MHz and 0.93 MHz
from the centre, and a 2.4 MSPS capture analyses only 1.08 MHz either side.

`ley scan 144M..148M` runs over one file device. A file device tunes only its recording's
centre, so the sweep plan is a single step there, and at 5 MSPS that step's windows reach
2.25 MHz either side of 146.000 MHz, covering the whole range. Its DC guard leaves 145.750 to
146.250 MHz unanalysed, and no carrier sits there. A run in the Linux container on 2026-10-03
found all five carriers, with 144.390 at `1/4` and the rest at `4/4`. The sweep refuses a radio
that has a channel on it, so the scene runs `ley stop all` after `ley play` and before the
scan. A default 250 ms dwell at 5 MSPS gives four looks, not eight; `--dwell 500` would give
eight, at the cost of a longer command in the shot.

Only app scenes set `clock`. `ley track --since` seeds its table from the real clock, so a
daemon started with `--wall-clock` can open a track empty. `ways-sync` shares one daemon
between an app shot and a terminal, so it leaves the clock unset as well, and `leyshots`
refuses a `clock` on any scene that is not an app scene.

## Assets

| asset | kind | scene |
|---|---|---|
| `app-radio-2m.png` | app, 1440 × 820 pt window | `scene_2m` at 146.520 NFM, 2 m band expanded with Calling, APRS and a net bookmark, inspector shown, clock 19:42 |
| `sidebar-chirp-import.png` | app, `sidebar` crop | `scene_2m` with `site/shots/chirp-100.csv` imported (about 100 memories over 2 m, 70 cm, GMRS, NOAA, MURS and marine); 2 m expanded |
| `chirp-csv-before.png` | HTML table of the same CSV, terminal theme | none |
| `inspector-tone.png` | app, `inspector` crop | `scene_2m` at 146.940, bookmark with offset −0.6 and tone 127.3 |
| `inspector-dcs.png` | app, `inspector` crop | `scene_2m` at 147.180, DCS 023 |
| `scan-2m.png` | terminal, 100 columns | `scene_scan`, `ley scan …` |
| `scan-app.png` | app, `sidebar` crop | `scene_scan`, the band row's Scan with its hits |
| `library-net.png` | app, `library` crop, Library place | `scene_net` recorded gated, then one part selected |
| `notification-same.png` | screen region | `same_alert`, `ley watch same --county … --notify`; see below |
| `aprs-track.png` | terminal | `scene_aprs`, `ley track aprs` |
| `ais-track.png` | terminal | `scene_ais`, `ley track ais` |
| `ways-app.png` | app, 480 × 300 pt crop of the waterfall and inspector | `scene_2m` |
| `ways-terminal.png` | terminal, split | `ley tune 146.52` beside `ley set squelch -45` |
| `ways-sync.png` | composite | the app window and the split terminal, side by side, after the squelch change |
| `app-icon-1024.png` | `scripts/render-icon.swift --png 1024` | none |

The notification is captured from the NotificationCenter window's on-screen frame, found through
`CGWindowListCopyWindowInfo`, so it needs a plain dark desktop behind it. `leyshots` prints a
reminder to set one before that scene, and treats the shot as manual if the window is not found
within 10 s.

Some scenes need more than the stage and a tuned channel:

- `scan-2m` and `scan-app` run `ley stop all` first, because a sweep refuses a radio a channel is
  on. `scan-app` then runs `ley scan 144M..148M` and `ley tune 146.52 --persistent` before the app
  starts. The stage has no key for the band row's Scan action, so whether the band rail shows the
  hits of a scan a terminal ran is to be seen on the Mac.
- `ways-terminal` and `ways-sync` run `ley stop`, which removes `ley play`'s channel and leaves the
  radio tuned. `ley tune 146.52` in the first pane is then the only channel, the one
  `ley set squelch -45` picks. In `ways-sync` that command is typed before the app starts, so the
  app opens on its channel, and the squelch change is typed once the app shows.
- `library-net` records with `ley record 147.18 --gate squelch --for 75s --detach` and waits
  80 s. In the Linux container a 40 s recording of `scene_net` made 3 parts.

## `shots.json`

Each entry has the asset name, pixel width and height, scale (2), alt text, the scene, the
fixtures' generator records, the `ley --version` output and the commit that produced it, and the
`shots-*` tag where the current image was first published. `leyshots run` writes the entries
with no tag, and `leyshots publish` sets it on the images it refreshes.

`make shots-publish SHOTS_ARGS=--dry-run` builds the release in `tmp/shots/publish/<tag>/`,
compresses and checks it, and prints the `gh release create` it would run. A second release on
one day is tagged `shots-YYYY-MM-DD-2`, then `-3`.

## Work items

- [x] **SHOT-1 (Go, testable on Linux).** The `scenes` set in `leyfix` and the `voice` source; the
  configurable APRS station list; the `leyshots` driver with `scenes.yaml`, the per-scene
  hermetic daemon (shared with `go/internal/eval` rather than copied), the terminal path through
  HTML, the manifest, `publish`, and the Makefile targets. Done 2026-10-03. Verified by the unit
  tests in `go/cmd/leyfix` and `go/cmd/leyshots`, `leyfix check` over the generated set, and a
  Linux run of `scan-2m`, `aprs-track`, `ais-track`, `ways-terminal` and `chirp-csv-before` to
  HTML. The app capture, the composite, the notification, the icon, `render-html.swift` calls
  and `publish` against GitHub are written and have not run; they are SHOT-4's first run.
  The 2 m bookmarks are a CHIRP CSV imported per scene rather than a bookmarks file, so the
  import path is the one a person uses.
- [ ] **SHOT-2 (engine).** The sidecar `label` and `leylined --wall-clock`, each with a test.
- [ ] **SHOT-3 (app; can only be checked on the Mac).** `LEYLINE_APP_STAGE` and `regions.json`.
  Written and not yet compiled on the Mac; `docs/dev/app.md`, "Staged runs" has the stage keys
  and the regions file. Differences from the description above: the stage does not reopen the
  remembered band, so each app scene must leave a capture tuned (`ley tune`) before the app
  starts, or the app opens FM broadcast; `settle` is counted from when the stage is applied, not
  from the spectrum's first row; `select_part` selects the part without playing it; in the
  Library, `sidebar` and `inspector` are the Library's own.
- [ ] **SHOT-4 (Mac).** `scripts/render-html.swift`, `render-icon.swift --png`, the window and
  notification capture in `leyshots`, then the first full run on the Mac.

## The app is the source of truth

Each scene stages the app as it is, and the site copy follows the images. Where the site's
mockup and the app differ, the leysdr.com side changes the mockup. Differences known on
2026-10-03:

- The mockup's "Save tone to bookmark" is the app's add channel action.
- The Library draws a level-bar graph for each part, not a waveform.
- Scanning in the app is the band row's Scan action, which marks hits on the band rail. There
  is no separate Scan view.
