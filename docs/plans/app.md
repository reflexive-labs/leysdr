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
  `make license-check` refuses an engine import under `app/`. 2026-09-18: the generated contract
  moved to its own package at `swift/LeylineProto`, so the app depends on that and neither client
  depends on the engine package.
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

### APP-2 `[x]` Layer 0 and spike S1: spectrum, waterfall, click to hear (E.2)

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
the decision above about no Xcode project is not reopened for this alone. **Tried 2026-09-18:**
the first run on the Mac drew the spectrum and left the waterfall dark, with no message, so the
shader is now Swift source (`WaterfallShader.swift`) compiled with `makeLibrary(source:)` at
launch, which works under `swift build` and Xcode alike, and a compile failure is printed to
stderr and shown in the panel instead of being a dark rectangle.

Where the handoff lands: the waterfall's ramp and the spectrum's inks in `Theme.swift`; the
layout in the views; nothing in the façade.

Written 2026-09-18 in the container, where the SwiftUI target cannot be compiled: `Theme.swift`
carries every token of the handoff; `SpectrumFeed` subscribes 2048 bins at 30 rows a second
and keeps the ring the waterfall's texture is filled from; `SpectrumView` draws the traces and
the tuned band on a `Canvas`; `WaterfallView` is an `MTKView` with `Resources/Waterfall.metal`
(one byte a bin in a ring texture, the loudest bin per pixel column, the six-stop ramp between
the floor and floor + 60 dB) and owns the mouse; `AppSession.adopt` creates the first capture
on the last band used or FM broadcast; signposts `row` and `draw` on `com.leyline.app` are the
client half of S1.

Ticked 2026-09-20. The window has been built and run on the owner's Mac since 2026-09-18 (APP-3
records every change since going through `make app-run`), so the Metal path, the type checker
and the layout are proven there. The S1 trace was not taken: the owner worked around it on the
Mac, and the spike's artifact (an Instruments trace and a findings note) is scratched rather
than owed. The signposts stay in the code for whoever wants the measurement later. The ring
decision stands where "Decisions" left it: gRPC, and the ring only if a window drops rows.

### APP-3 `[ ]` Layer 1 controls (E.3)

Frequency, mode, squelch, volume as Mac controls; drag-to-tune and scroll-to-zoom on the
waterfall through the coalescer; keyboard shortcuts; the named failure states from telemetry
(flat floor, zero gain, no antenna), each a sentence and the thing to try. Rule: nothing in
layer 2 is ever required for layers 0 and 1 to succeed (`user-stories.md`, V1a).

Written 2026-09-18 with APP-2: the transport bar (`TransportBarView.swift`: play as the sink
attached or detached, the tuning field with its ⌘L entry and its stepper, mode and width pop-ups,
the signal readout from the channel meter, the squelch track with its words, volume with the
output's name from CoreAudio), the Tune menu (`TuneCommands`), click, drag and scroll on the
waterfall, and the device menu with the gain slider (`DeviceMenuView.swift`). The named failure
states landed 2026-09-19 (below). Built and running on the owner's Mac from 2026-09-18; every change
since has gone through `make app-run` there, and the state on 2026-09-19 is a window that hears,
tunes by click, drag, scroll, keys, field, rail and bookmarks, and shows the band rail, the dB axis
and the squelch-keyed waterfall. Nothing in M1 is still owed from the code (2026-09-20): CHIRP
import follows M1 (APP-4), and the S1 trace was scratched (APP-2); what remains is the first-run
checks each item names.

Found 2026-09-19 on the Mac, a daemon matter the window works around: `Meter.snr_db` is
`PowerMeter.snrDB`, the channel's power over its own running minimum across 5 s
(`engine/Sources/EngineCore/DSP/Demodulators.swift`), which on a carrier that never stops is
the carrier and reads `0 dB over noise` under a −12 dBFS signal. The window shows power over
the band's floor scaled to the channel's width instead (`AppSession.overNoiseDB`, the auto
squelch's rule); `ley`'s `snr` column showed the meter's number. Landed 2026-09-19: the capture
reads its own floor (`BandFloor`, the median bin of a 1024-bin row as a density) and every
channel's meter reports power over that floor at the channel's width, NaN until a row has been
read (`../dev/engine-internals.md`, "Squelch and meters"). `overNoiseDB` and the meter now agree
by construction, so the window's code is left as it is.

Landed 2026-09-19, the named failure states: `FailureState` in the façade (`../dev/app.md`,
"Failure states") names what the band's numbers show, from the feed's held floor and peak and
the capture's gains: a signal within 3 dB of full scale, or nothing 15 dB above the floor for
3 s, with the gain named as the thing to try when it is set by hand to its lowest. The strip
over the waterfall says it in a sentence with the number and one thing to try; `ley tune` says
the same sentence from the row it measured the squelch on, and the MCP tune tool carries it, so
an agent is told the band is deaf rather than left to read an empty decode as quiet. The daemon
not running, no radio and an unplugged radio were already the window's empty words. Not
compiled in the container: the strip's third branch in `MainWindow.swift` and the session's
`nameFailure` path; the rule itself is tested on Linux.

Found the same day from the app log: every gain write from the window was refused with
`GAIN_ELEMENT_UNKNOWN no gain element named ` because the window sent no element, while `ley`
names the device's first. Fixed on both sides: the daemon now reads an empty element as the
first the device lists, as `common.proto` promises and the scan allocator already did (a radio
with no gain stage says "this radio reports no gain elements"), the fake daemon does the same,
and the window names the element and logs the write like a tune. Unverified on the Mac: that the
slider's confirmed level now reads back under the element's name.

Found the same evening: a sample-rate change silenced the station. The daemon keeps the capture
centre on a rate write, so a station placed off-centre (88.5 MHz in a capture centred on
89.4 MHz, the band's centre) falls out of a narrower capture and the channel goes
`OUT_OF_CAPTURE`, which the window did not name. Now `setSampleRate` re-places the centre for
the tuned frequency at the new width and writes centre and rate in one tick (centre first when
narrowing, rate first when widening), refuses in words a width the channel cannot fit, and the
strip names an out-of-capture channel when another client causes one. Unverified on the Mac:
the placement and the one-tick order, which `LeylineApp` alone compiles.

Added 2026-09-19: the band rail (`BandRailView.swift`) replaces the band header, from a mockup
the owner brought and the four answers recorded in the handoff's "Decided 2026-09-19": the
band's edges as a track with numbered caps, the slice on screen as a pill, bookmarks and the
tuned frequency as ticks, the neighbouring bands named at the caps, a drag that moves the
region and pushes the station only from the middle 80 % of it (`AppSession.pan`: centre and
offset in one tick, because the daemon bounds an offset by the sample rate alone) and stops
at the band's edges, the neighbours' names crossing into them at the near edge
(`AppSession.select(band:at:)` places the capture so the edge is inside it), and what a column
covers as the one resolution the window states.

### APP-4 `[ ]` Bookmarks, presets and CHIRP import, with `ley bookmarks` (E.4)

Interpretation state, client-side, in one shared `bookmarks.json` both `ley` and the app read,
on the pattern `go/pkg/labels` set (`../design/decoders.md`, "The state boundary"). The built-in
band table is the seed layer: `bands.json`, generated by `ley bands --json`, checked in as an
app resource and drift-tested from Go, with the `step_hz` column the handoff adds. Not daemon
state; the daemon never learns a bookmark exists. Split on 2026-09-18 by the handoff: the seed
file, `bookmarks.json` and `ley bookmarks` are in the M1 cut; CHIRP import follows M1.

Landed 2026-09-18, the file half: `go/pkg/bookmarks` and `ley bookmarks` (list, add, remove,
`--json`), `Band.StepHz` and `step_hz` in `ley bands --json`, `bands.json` under
`LeylineClient/Resources` with `make bands-json` and `TestBandsJSONResource` holding it to the
table; on the Swift side `Bands.swift` (the seed file decoded, the sideband and sample-rate
rules `ley` applies) and `Bookmarks.swift` (the same file, the same shape, reloaded when the
directory changes), both tested on Linux. The sidebar renders both. CHIRP import is the open
half.

Seen on the Mac 2026-09-20, by the owner: the gain slider's level reads back under the
element's name, a rate change keeps the station inside the capture, the failure strip appears
and clears, and the stepper steps. M1 holds. One thing came back as not liked rather than not
working: the failure strip itself, carried below as a task rather than fixed in place.

## Carried out of M1

- `[ ]` **The failure strip's presentation.** The words are right and the rule is tested; the
  strip over the bottom of the waterfall is not where the owner wants to read them
  (2026-09-20). Revisit once M2's inspector exists, which carries signal in words and is the
  natural home for "what the numbers say is wrong"; the mirror-state words (out of capture) go
  with it. Not a rule change: `FailureState` and `ley tune`'s line stay as they are.

## The M1 cut

Decided 2026-09-18 from `../design/app-design-handoff.md`, "What M1 is": a window that hears
something. M1 is APP-2, APP-3, the file half of APP-4, and the device menu with its gain control
from APP-6; the inspector, recording, lifecycle prose and distribution wait. The handoff's
"Deliberately not in M1" is the list of what a reviewer should not find in the window. Two
things the handoff settled that the plan had left open: the waterfall runs at 2048 bins and
30 rows a second (the ladder's ceiling, and what the desktop SDRs do), and pause is the sink
detached rather than a volume of zero.

## The M2 cut

Decided 2026-09-20 from the handoff's ladder ("M2: the inspector: signal, tuning error, time on
air, recent transmissions on this channel"). M2 adds the right third of the window and moves
nothing an earlier step introduced, except signal, which leaves the transport bar as the
handoff's one named exception (Region 5). The order is data first, panel last: the folds and
the engine work are built and tested here, against fixtures, with their `ley` mirrors; the
panel waits for its handoff and is built on the Mac. The failure strip's presentation (above)
is revisited with the panel, which is where "what the numbers say" belongs.

### M2-1 `[x]` The transmissions log and time on air, in the façade and in `ley`

What `ley tune` already prints per closed transmission (`go/internal/cli/transmission.go`:
duration from `duration_samples` at the capture rate, peak SNR, peak audio) becomes a fold both
clients keep: a ring of the last transmissions on a channel from `SquelchTransition` edges, the
CTCSS tone `SubAudible` reported during each, and the open one's time on air from its open
edge's `SampleTime`. Wall clock is derived from the capture's `CaptureAnchor` and nothing else
(invariant 5; Go's `leyline.AnchorWallTime` gets a Swift mirror), and a transmission no anchor
covers has no clock. In the façade: `Transmissions.swift`, a value with no daemon in it, tested
on Linux from synthetic messages and against `nfm_keyed.cf32`. In `ley`: the meter line says
`on air 4 s` while the squelch is open, and the closed line carries the wall-clock start when
the anchor covers it. No contract change.

Landed 2026-09-20, both halves. Façade: `Transmissions.swift` (`TransmissionLog`,
`Transmission`, `OnAir`, `CTCSSTone`) and `SampleClock.swift`, with `TransmissionsTests` and
`SampleClockTests` on synthetic messages and one e2e test folding `nfm_keyed.cf32`'s keyed
carrier into dated transmissions. `ley`: `onAirSince`, `transmissionStart` and `anchorCovers`
beside `render` in `transmission.go`, the meter line ending `on air N s` only when the open edge
was seen, the session mirror folding `Event_Anchor` into `Capture.anchor` as the Swift mirror
already did, and one test of both against the fake daemon. Both clients refuse an undated
anchor (host time 0, what a Capture carries before its first block): a clock the daemon never
kept is not printed.

### M2-2 `[ ]` Tuning error and deviation in the meter (SV-6)

`docs/design/signal-views.md`: "The discriminator's DC *is* the tuning error, and is what feeds
`freq_error_hz`"; `docs/plans/signal-views.md` deferred `deviation_hz` and `freq_error_hz` to
SV-6 and reserved 7 and 8 "so the wire does not churn". `ley scope` derives the tuning error on
the client from the demod tap's DC today; the daemon computes none. Engine work: the FM
discriminator's DC and its deviation onto `Meter`, FM and squelch-open only, NaN otherwise, with
`ley`'s meter line and scope header reading the daemon's number. **Decided 2026-09-20:** the fields take 7 and 8 as the signal-views plan intended. The
reserved rule exists for fields people depend on and nothing has shipped yet; `CLAUDE.md` now
says when it starts to bind.

### M2-3 `[d]` The inspector panel

The right third: signal in words (the transport bar's readout leaves with it and the slot
returns to the layout), tuning error and deviation from M2-2, time on air and the recent
transmissions from M2-1, and the failure states carried out of M1. Waits for its handoff from
Claude Design, the way the M1 window did; built on the Mac after M2-1 lands.

### M2-4 `[ ]` The lifecycle half of APP-6

The daemon not running and the radio unplugged are already the window's empty words, and an
unplug is the `CAPTURE_DETACHED` transition the mirror keeps. Left for M2: the app starting the
daemon, which waits for APP-7's launchd job. Nothing to build until then; recorded so APP-6 is
not read as untouched.

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
