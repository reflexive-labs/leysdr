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

1. generates the scene's fixtures into `~/Library/Caches/leyline-shots/iq/` with `leyfix`,
   unless a copy with the same generator record is already there;
2. starts its own `leylined --no-hardware` with a socket, store, recordings directory and log
   under `tmp/shots/run/<scene>/`, and `--wall-clock` set when the scene gives a `clock`. One
   daemon per scene, so no state carries from one shot to the next;
3. points `LEYLINE_BOOKMARKS` at a copy of the scene's bookmarks, attaches each fixture with
   `ley play --persistent`, and runs the scene's `ley` steps (tune, squelch, record, watch);
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
and crops in Go from a region's frame × 2. With the variable unset, nothing in the app changes.

### Terminal shots

Each terminal scene runs `ley` in its own tmux server (`tmux -L leyshots`) at a fixed size.
A scene can split the window, as `ways-terminal` does. `leyshots` reads each pane with
`tmux capture-pane -e -p` once the scene settles. `scripts/ansi2html.py` converts the panes, and
they are laid out in the site's terminal theme:

| role | colour |
|---|---|
| background | #090B0C |
| foreground | #9BA1A6 |
| bold | #E7E9EA |
| green | #2FB6A3 |

The font is SF Mono 13 (`ui-monospace`). A short Swift script, `scripts/render-html.swift`,
draws the page in a WKWebView at 2× and writes the PNG. On Linux, `leyshots` stops at the HTML,
which lets the terminal path be tested in CI.

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
| `scene_scan` | as `ley scan 144M..148M` needs | Three to six carriers, one keyed so briefly that the scan sees it in 1 of 8 looks. |
| `scene_aprs` | 144.390 MHz | AFSK packets from seven N0CALL stations with positions and comments, spread over the loop. |
| `scene_ais` | 162.000 MHz | GMSK position reports from five vessels with made-up MMSIs. |
| `same_alert` | 162.400 MHz | The existing weekly test. |

`ley scan 144M..148M` covers 4 MHz, and a file device cannot be retuned. Before building
`scene_scan`, check whether a scan runs over one file device at a rate wide enough for the whole
range (5 MSPS, cu8 to keep the file size down). If it does not, the scene scans the span
`scene_2m` already covers, and the asset's command changes to match.

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

## `shots.json`

Each entry has the asset name, pixel width and height, scale (2), alt text, the scene, the
fixtures' generator records, the `ley --version` output and the commit that produced it, and the
`shots-*` tag where the current image was first published.

## Work items

- [ ] **SHOT-1 (Go, testable on Linux).** The `scenes` set in `leyfix` and the `voice` source; the
  configurable APRS station list; the `leyshots` driver with `scenes.yaml`, the per-scene
  hermetic daemon (shared with `go/internal/eval` rather than copied), the terminal path through
  HTML, the manifest, `publish`, and the Makefile targets.
- [ ] **SHOT-2 (engine).** The sidecar `label` and `leylined --wall-clock`, each with a test.
- [ ] **SHOT-3 (app; can only be checked on the Mac).** `LEYLINE_APP_STAGE` and `regions.json`.
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
