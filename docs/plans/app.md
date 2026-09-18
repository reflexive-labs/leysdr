# Plan: the Mac app

Status: draft, started 2026-09-18. Implements Milestone E of `build-order.md`, whose items E.1
to E.7 are the ids below; the stories are V1a in `user-stories.md`; the contract for the code is
`../dev/app.md`. Legend: `[ ]` pending, `[x]` done, `[-]` dropped with the reason, `[d]` waiting
on a decision.

## Context

The core closed on 2026-09-18 (`build-order.md`, "Closing the core"): recording landed as C.12
and S2 passed on the owner's Mac, so the app is the next thing built rather than the next thing
argued about. The designs exist in Claude Design and arrive as a handoff, the way the terminal
visuals did (`../dev/cli-style.md` records how that one was reconciled). This plan is the order
the app lands in and where each piece of the handoff goes.

The app is a peer client (`CLAUDE.md`, invariant 1): it links the generated contract and never
the engine, keeps no state of its own, and every contract addition it needs ships with its `ley`
mirror so nothing works only from Swift.

## Decisions

- **A SwiftPM package at `app/`, not an Xcode project.** `swift build` is what CI and the
  container already run; the manifest merges; Xcode opens the package directly. What a bundle
  needs beyond the executable is `scripts/bundle-app.sh`. Reopened if a feature needs something
  only a project gives (an asset catalog with app icons is fine as a package resource; an
  Xcode-only entitlement flow would be the sign).
- **Outside `engine/`.** The licence gate maps `engine/*` to GPL; the app is Apache-2.0
  (`../decisions/D2-licensing.md`) and depends on the engine package for `LeylineProto` alone.
  `make license-check` refuses an engine import under `app/`.
- **Swift 6 language mode.** The engine builds in Swift 5 mode for its history; the app starts
  in 6, so an actor-isolation mistake is an error here, not a warning to read past.
- **The mirror is one `@MainActor` object, and the app's session is the `@Observable` one.**
  Control events are a few a second; folding them where the views read them costs nothing and
  removes a hop per event. The façade imports no UI framework (Linux's Observation library does
  not link into a test bundle, and the façade must test there), so `DaemonMirror.onChange` feeds
  `AppSession`, which the views observe. Bulk and telemetry have their own streams and never
  touch the mirror.
- **gRPC first, ring later.** The waterfall draws from the gRPC FFT stream, S1 is measured, and
  the shm ring is built if the numbers say so (`build-order.md`, "Decided not to gate on").
- **The bundle identifier is `com.leyline.app`**, beside the daemon's `com.leyline.daemon`
  launchd label. Changing it later means a migration of nothing (the app stores nothing yet),
  so it is a decision only until APP-4's shared file names it.
- **Not sandboxed.** Direct, notarized distribution (`D2-licensing.md`, "Distribution
  obligations"); the daemon holds the USB access, and the app reads the socket under
  `~/Library/Application Support/Leyline`.

## Work items

### APP-1 `[x]` App target and the client façade (E.1)

Landed 2026-09-18: `app/Package.swift`, `LeylineClient` (identity, connection, errors, mirror,
coalescer, streams), the SwiftUI skeleton (`LeylineApp`: a window naming the daemon's state and
listing radios and channels, no spectrum), `make app | app-test | app-e2e | app-run |
app-bundle`, both CI jobs, `scripts/bundle-app.sh`, and the licence gate's two new rules.
Verified: `make app-test app-e2e` green in the Linux container against the Linux-built daemon,
including the story "the CLI changes the tuning and the UI reflects it" as a test in which a
second identity creates a channel and the mirror shows it, then drops it on the tombstone.

Still to see on the Mac, the first time anyone runs it there: `make app-run` opens a window
that says `leylined <version>` with the daemon running and "The daemon is not running" without
it, and `ley tune 146.52M` from a terminal puts a row in its channel list. That is the same
promise the test makes, with a window instead of an assertion.

### APP-2 `[ ]` Layer 0 and spike S1: spectrum, waterfall, click to hear (E.2)

The window on launch: the first connected radio's capture (created if none, on the opinionated
defaults: auto gain, 2.4 MSPS, the preset the user last used or FM broadcast), the spectrum row
and a Metal waterfall from `fft(capture:bins:rowsPerSecond:)`, a click that creates an NFM
channel and a system-audio sink. `os_signpost` from the frame's arrival to the draw, matched
with the daemon's signposts, is S1: p95 under 50 ms antenna to pixels, no dropped rows at 2.4 MSPS
over ten minutes, an Instruments trace and a findings note in `../decisions/S1-latency.md`. The
ring decision is made from that note.

First commit here confirms the Metal path: a `.metal` file as a resource of the `LeylineApp`
target, compiled by SwiftPM into the resource bundle, loaded through `Bundle.module`. If SwiftPM
does not compile it on the Mac, the fallback is a build plugin or a checked-in `.metallib`, and
the decision above about no Xcode project is not reopened for this alone.

Where the handoff lands: the waterfall's ramp and the spectrum's inks in `Theme.swift`; the
layout in the views; nothing in the façade.

### APP-3 `[ ]` Layer 1 controls (E.3)

Frequency, mode, squelch, volume as Mac controls; drag-to-tune and scroll-to-zoom on the
waterfall through the coalescer; keyboard shortcuts; the named failure states from telemetry
(flat floor, zero gain, no antenna), each a sentence and the thing to try. Rule: nothing in
layer 2 is ever required for layers 0 and 1 to succeed (`user-stories.md`, V1a).

### APP-4 `[ ]` Bookmarks, presets and CHIRP import, with `ley bookmarks` (E.4)

Interpretation state, client-side, in one shared `bookmarks.json` both `ley` and the app read,
on the pattern `go/pkg/labels` set (`../design/decoders.md`, "The state boundary"). The built-in
preset table becomes the seed layer of the same list and gains the newcomer presets the V1a
story names. Not daemon state; the daemon never learns a bookmark exists.

### APP-5 `[ ]` Recording from the window (E.5)

Start and stop over C.12 (`Jobs.StartJob(RecordConfig)`), the job rendered from the mirror's
`jobs`, reveal in Finder through `Resources.ResolveLocalPath`.

### APP-6 `[ ]` Lifecycle and the inspector (E.6)

The daemon not running (named, with `ley daemon start` offered and, once APP-7 installs the
launchd job, started by the app); unplug and replug as the `CAPTURE_DETACHED` state transition
it already is; the layer 2 parameter inspector last.

### APP-7 `[ ]` Distribution (E.7)

`scripts/bundle-app.sh --with-daemon` is the layout; this item makes it install: the app
bootstraps `com.leyline.daemon` on its own `leylined` the way `ley daemon install` does, puts
`ley` and the decoders where a terminal finds them, and is signed with a Developer ID and
notarized (`../dev/release-checklist.md`). D3, the trademark check, gates the first public build.

## Open for the owner

- `[d]` **The handoff itself.** The terminal handoff was reconciled item by item against
  `cli-style.md`, and the guide stayed outside the repository. The same for the app: the tokens
  land in `Theme.swift`, the layouts in views, and the guide stays where it is unless a page of
  it is a contract the code must follow, in which case it becomes a section of `../dev/app.md`.
  The `/design-login` step authorises `DesignSync`, which pushes a component library *to* a
  Claude Design project; pulling the designs is the handoff document, as before.
- `[d]` **An icon.** An asset catalog as a package resource carries one; none exists. Wanted
  before APP-7, not before APP-2.
