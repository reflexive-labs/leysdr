# Plan: the Mac app

Status: draft, started 2026-09-18. Implements Milestone E of `build-order.md`, whose items E.1
to E.7 are the ids below; the stories are V1a in `user-stories.md`; the contract for the code is
`../dev/app.md`. Legend: `[ ]` pending, `[x]` done, `[-]` dropped with the reason, `[d]` waiting
on a decision.

## Context

The core closed on 2026-09-18 (`build-order.md`, "Closing the core"): recording landed as C.12
and S2 passed on the owner's Mac, so the app is the next thing to build. The designs exist in Claude
Design and arrive as a handoff, the way the terminal visuals did (`../dev/cli-style.md` records how
that one was reconciled). This plan is the order the app lands in and where each piece of the
handoff goes.

The app is a peer client (`AGENTS.md`, invariant 1): it links the generated contract and never
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
  in 6, so an actor-isolation mistake is a compile error here rather than a warning.
- **The mirror is one `@MainActor` object, and the app's session is the `@Observable` one.**
  Control events are a few a second; folding them where the views read them costs nothing and
  removes a hop per event. The façade imports no UI framework (Linux's Observation library does
  not link into a test bundle, and the façade must test there), so `DaemonMirror.onChange` feeds
  `AppSession`, which the views observe. Bulk and telemetry have their own streams and never
  touch the mirror.
- **gRPC first, ring later.** The waterfall draws from the gRPC FFT stream, S1 is measured, and
  the shm ring is built if the numbers say so (`build-order.md`, "Decided not to gate on").
- **The bundle identifier is `com.leyline.app`**, beside the daemon's `com.leyline.daemon`
  launchd label. Changing it now needs no migration (the app stores nothing yet); it becomes
  fixed once APP-4's shared file uses it.
- **Not sandboxed.** Direct, notarized distribution (`D2-licensing.md`, "Distribution
  obligations"); the daemon holds the USB access, and the app reads the socket under
  `~/Library/Application Support/Leyline`.

## Work items

### APP-1 `[x]` App target and the client façade (E.1)

Landed 2026-09-18: `app/Package.swift`, `LeylineClient` (identity, connection, errors, mirror,
coalescer, streams), the SwiftUI skeleton (`LeylineApp`: a window showing the daemon's state and
listing radios and channels, no spectrum), `make app | app-test | app-e2e | app-run |
app-bundle`, both CI jobs, `scripts/bundle-app.sh`, and the licence gate's two new rules.
Verified: `make app-test app-e2e` green in the Linux container against the Linux-built daemon,
including the story "the CLI changes the tuning and the UI reflects it" as a test in which a
second identity creates a channel and the mirror shows it, then drops it on the tombstone.

Still to see on the Mac, the first time anyone runs it there: `make app-run` opens a window
that says `leylined <version>` with the daemon running and "The daemon is not running" without
it, and `ley tune 146.52M` from a terminal puts a row in its channel list. That checks the same
behaviour as the test, in a window instead of an assertion.

### APP-2 `[x]` Layer 0 and spike S1: spectrum, waterfall, click to hear (E.2)

The window on launch: the first connected radio's capture (created if none, on the opinionated
defaults: auto gain, 2.4 MSPS, the preset the user last used or FM broadcast; the gain default
became a fixed 28 dB on 2026-09-21, below), the spectrum row
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
Mac, and the spike's artifact (an Instruments trace and a findings note) is dropped, not
pending. The signposts stay in the code for whoever wants the measurement later. The ring
decision stands where "Decisions" left it: gRPC, and the ring only if a window drops rows.

### APP-3 `[x]` Layer 1 controls (E.3)

Frequency, mode, squelch, volume as Mac controls; drag-to-tune and scroll-to-zoom on the
waterfall through the coalescer; keyboard shortcuts; the named failure states from telemetry
(flat floor, zero gain, no antenna), each shown as a sentence and one fix to try. Rule: nothing in
layer 2 is ever required for layers 0 and 1 to succeed (`user-stories.md`, V1a).

Written 2026-09-18 with APP-2: the transport bar (`TransportBarView.swift`: play as the sink
attached or detached, the tuning field with its ⌘L entry and its stepper, mode and width pop-ups,
the signal readout from the channel meter, the squelch track with its words, volume with the
output's name from CoreAudio), the Tune menu (`TuneCommands`), click, drag and scroll on the
waterfall, and the device menu with the gain slider (`DeviceMenuView.swift`). The named failure
states landed 2026-09-19 (below). Built and running on the owner's Mac from 2026-09-18; every change
since has gone through `make app-run` there, and the state on 2026-09-19 is a window that plays
audio, tunes by click, drag, scroll, keys, field, rail and bookmarks, and shows the band rail, the
dB axis and the squelch-keyed waterfall. Nothing in M1 is still owed from the code (2026-09-20):
CHIRP import follows M1 (APP-4), and the S1 trace was scratched (APP-2); what remains is the
first-run checks each item lists. Ticked 2026-09-23: the owner confirmed M1 on the Mac on
2026-09-20 (below), and the failure strip carried out of M1 landed with M2-3. Of the named
failure states only clipping remains; the others were dropped on 2026-09-21 (`FailureState.swift`).

Found 2026-09-19 on the Mac, a daemon matter the window works around: `Meter.snr_db` is
`PowerMeter.snrDB`, the channel's power over its own running minimum across 5 s
(`engine/Sources/EngineCore/DSP/Demodulators.swift`). On a carrier that never stops, that minimum
is the carrier itself, so the meter reads `0 dB over noise` under a −12 dBFS signal. The window
shows power over the band's floor scaled to the channel's width instead (`AppSession.overNoiseDB`,
the auto squelch's rule); `ley`'s `snr` column showed the meter's number. Landed 2026-09-19: the
capture reads its own floor (`BandFloor`, the median bin of a 1024-bin row as a density) and every
channel's meter reports power over that floor at the channel's width, NaN until a row has been read
(`../dev/engine-internals.md`, "Squelch and meters"). `overNoiseDB` and the meter now agree by
construction, so the window's code is left as it is.

Landed 2026-09-19, the named failure states: `FailureState` in the façade (`../dev/app.md`,
"Failure states") classifies the band from the feed's held floor and peak and the capture's
gains: a signal within 3 dB of full scale, or nothing 15 dB above the floor for 3 s. When the
gain is set by hand to its lowest, raising it is the suggested fix. The strip over the waterfall
shows one sentence with the number and one fix to try; `ley tune` prints the same sentence from
the row it measured the squelch on, and the MCP tune tool includes it, so an agent learns the
receiver is hearing nothing instead of reading an empty decode as a quiet band. The daemon not
running, no radio and an unplugged radio already had empty-state messages in the window. Not
compiled in the container: the strip's third branch in `MainWindow.swift` and the session's
`nameFailure` path; the rule itself is tested on Linux.

Found the same day from the app log: every gain write from the window was refused with
`GAIN_ELEMENT_UNKNOWN no gain element named ` because the window sent no element, while `ley`
sends the device's first. Fixed on both sides: the daemon now reads an empty element as the
first the device lists, as `common.proto` specifies and the scan allocator already did (a radio
with no gain stage says "this radio reports no gain elements"), the fake daemon does the same,
and the window sends the element and logs the write like a tune. Unverified on the Mac: that the
slider's confirmed level now reads back under the element's name.

Found the same evening: a sample-rate change silenced the station. The daemon keeps the capture
centre on a rate write, so a station placed off-centre (88.5 MHz in a capture centred on
89.4 MHz, the band's centre) falls out of a narrower capture and the channel goes
`OUT_OF_CAPTURE`, which the window did not report. Now `setSampleRate` re-places the centre for
the tuned frequency at the new width and writes centre and rate in one tick (centre first when
narrowing, rate first when widening), refuses with a message a width the channel cannot fit, and the
strip reports an out-of-capture channel when another client causes one. Unverified on the Mac:
the placement and the one-tick order, which `LeylineApp` alone compiles.

Added 2026-09-19: the band rail (`BandRailView.swift`) replaces the band header, from a mockup
the owner brought and the four answers recorded in the handoff's "Decided 2026-09-19": the
band's edges as a track with numbered caps, the slice on screen as a pill, bookmarks and the
tuned frequency as ticks, the neighbouring bands named at the caps, a drag that moves the
region and pushes the station only from the middle 80 % of it (`AppSession.pan`: centre and
offset in one tick, because the daemon bounds an offset by the sample rate alone) and stops
at the band's edges, the neighbours' names crossing into them at the near edge
(`AppSession.select(band:at:)` places the capture so the edge is inside it), and the span one
pixel column covers as the only resolution figure the window shows.

### APP-4 `[ ]` Bookmarks, presets and CHIRP import, with `ley bookmarks` (E.4)

Interpretation state, client-side, in one shared `bookmarks.json` both `ley` and the app read,
on the pattern `go/pkg/labels` set (`../design/decoders.md`, "The state boundary"). The built-in
band table is the seed layer: `bands.json`, generated by `ley bands --json`, checked in as an
app resource and drift-tested from Go, with the `step_hz` column the handoff adds. Not daemon
state; the daemon never learns a bookmark exists. Split on 2026-09-18 by the handoff: the seed
file, `bookmarks.json` and `ley bookmarks` are in the M1 cut; CHIRP import follows M1.

Landed 2026-09-18, the file half: `go/pkg/bookmarks` and `ley bookmarks` (list, add, remove, move,
`--json`), `Band.StepHz` and `step_hz` in `ley bands --json`, `bands.json` under
`LeylineClient/Resources` with `make bands-json` and `TestBandsJSONResource` holding it to the table
(the sidebar's selection and editing model was revised 2026-09-21: the M1 handoff's "Decided
2026-09-21: the sidebar"); on the Swift side `Bands.swift` (the seed file decoded, the sideband rule
`ley` applies) and `Bookmarks.swift` (the same file, the same shape, reloaded when the directory
changes), both tested on Linux. The sidebar renders both. CHIRP import is the open half.

Seen on the Mac 2026-09-20, by the owner: the gain slider's level reads back under the
element's name, a rate change keeps the station inside the capture, the failure strip appears
and clears, and the stepper steps. M1 is confirmed. The owner disliked one thing that did work:
the failure strip itself, carried below as a task rather than fixed in place.

Decided 2026-09-21, the radio's two settings. The capture rate belongs to the radio, not the band:
2.4 MSPS unless the device menu set another, remembered, and never changed by a band change. A
capture the window creates starts at a fixed 28 dB gain, the RTL-SDR's mid-table entry, not
the tuner's auto mode: on the Mac, 89.5 FM at auto gain put 44 % of samples at the
converter's rails at one sample rate and none at another, because an RTL-SDR's "auto" lets the
LNA and mixer chase the signal with the last stage fixed and overloads on a strong local station,
which is why every desktop SDR defaults to a fixed gain. The stories' "auto gain" default was
written before a strong station had been measured through this dongle; the daemon now measures
clipping and the strip reports it, so a fixed default is the right one. The device menu's choice,
auto included, is remembered over it. `ley tune` and the daemon's open are unchanged: the radio
still opens in auto mode, and a fixed default there is a separate decision.

## Carried out of M1

- `[x]` **The failure strip's presentation.** The words are right and the rule is tested; the
  strip over the bottom of the waterfall is not where the owner wants to read them
  (2026-09-20). Revisit once M2's inspector exists, which carries signal in words and is the
  natural home for "what the numbers say is wrong"; the mirror-state words (out of capture) go
  with it. Not a rule change: `FailureState` and `ley tune`'s line stay as they are. Landed
  2026-09-20 with M2-3: both read in the inspector's Region 2 (`FailureStrip`), the gain clause
  as a button that opens the device menu, and `NoticeStrip` keeps only the notice and the last
  error.

## The M1 cut

Decided 2026-09-18 from `../design/app-design-handoff.md`, "What M1 is": a window that tunes and
plays audio. M1 is APP-2, APP-3, the file half of APP-4, and the device menu with its gain control
from APP-6; the inspector, recording, lifecycle prose and distribution wait. The handoff's
"Deliberately not in M1" lists what should not be in the window yet. Two
things the handoff settled that the plan had left open: the waterfall runs at 2048 bins and
30 rows a second (the ladder's ceiling, and what the desktop SDRs do), and pause is the sink
detached rather than a volume of zero.

## The M2 cut

Decided 2026-09-20 from the handoff's ladder ("M2: the inspector: signal, tuning error, time on
air, recent transmissions on this channel"). M2 adds the right third of the window and moves
nothing an earlier step added, except the signal readout, which leaves the transport bar; the
handoff lists that as its only exception (Region 5). The order is data first, panel last: the folds
and the engine work are built and tested here, against fixtures, with their `ley` mirrors; the panel
waits for its handoff and is built on the Mac. The failure strip's presentation (above) is revisited
with the panel, since the panel is where measurements are explained in words.

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
anchor (host time 0, what a Capture carries before its first block): a time the daemon never
recorded is not printed.

### M2-2 `[x]` Tuning error and deviation in the meter (SV-6)

`docs/design/signal-views.md`: "The discriminator's DC *is* the tuning error, and is what feeds
`freq_error_hz`"; `docs/plans/signal-views.md` deferred `deviation_hz` and `freq_error_hz` to SV-6
and reserved 7 and 8 "so the wire does not churn". `ley scope` derives the tuning error on the
client from the demod tap's DC today; the daemon computes none. Engine work: the FM discriminator's
DC and its deviation onto `Meter`, FM and squelch-open only, NaN otherwise, with `ley`'s meter line
and scope header reading the daemon's number. **Decided 2026-09-20:** the fields take 7 and 8 as the
signal-views plan intended. The reserved rule exists for fields people depend on and nothing has
shipped yet; `AGENTS.md` now specifies when it starts to apply.

Landed 2026-09-20: `Meter.deviation_hz = 7` and `freq_error_hz = 8`. Engine: a
`DiscriminatorInterval` (sum, count, high, low; four scalars, no allocation) inside
`NFMDemodulator` and `WFMDemodulator`, fed from the raw discriminator beside the sub-audible tap,
taken by `ChannelDSPCore` when it stamps the meter and carried through `ChannelTelemetryRecord`,
`ChannelTelemetry.meter` and `TelemetryService`. The DC is the tuning error, positive when the
transmitter sits above the channel; the larger excursion from the DC is the deviation. NaN
outside the FM modes, and the error NaN while the squelch is closed.
`ChannelTests.testMeterReadsTuningErrorAndDeviationOffTheDiscriminator` established the sign on
`nfm_tone.cf32`: on the carrier 2495-2504 Hz of deviation for the generator's 2500 and an error
within 8 Hz of zero, a channel 1 kHz above the carrier −1000 Hz, and an AM channel NaN for both.
`ley scope`'s demod-tap header shows the daemon's `freq_error_hz` when the meter carries one and
falls back to the window's DC only for a daemon that sends NaN (`scopeTuningHz`); the fake daemon
sends both fields off its own tap. `ley tune`'s meter line is unchanged, and `--json` carries the
fields as it carries the rest of the Meter. The app reads the generated proto and draws neither
until M2-3.

### M2-3 `[x]` The inspector panel

The right third: signal in words (the transport bar's readout leaves with it and the slot
returns to the layout), tuning error and deviation from M2-2, time on air and the recent
transmissions from M2-1, and the failure states carried out of M1.

Landed 2026-09-20 from `../design/app-design-handoff-m2.md`: `InspectorView.swift` (the toolbar
toggle, the header, the identity with its inline rename, the failure strip, the reading in words
with a popover under every word) and `InspectorGroups.swift` (the log, the disclosure groups, the
number and clock formatting); `Reading.swift` in the façade with the word tables and `ReadingTests`;
`MeterFeed` widened into `ChannelTelemetryFeed`, one subscription per channel for the meter, squelch
edges and tones folded into a `TransmissionLog`; `BookmarkStore.renameBookmark` for the pencil; the
tokens in `Theme.swift`; `View ▸ Show Inspector` (⌥⌘I) and `AppSession.inspectorShown`. The
exception: the signal readout left the transport bar (`SignalReadout` is deleted) and the squelch
track has the slot. The strip: `NoticeStrip` keeps the notice and the last error; the failure state
and the out-of-capture words read in the panel. The handoff's "Decided 2026-09-20" records where the
tree and the design differed, and "Decided 2026-09-21" what the first day on the Mac changed: meters
for tuning and deviation, one disclosure group, secondary ink. Written in the container, so
unverified without a Mac: that the panel compiles at all; the layout at 820 pt without a scroll
view; the popovers, the dotted underline and the ramp-filled bar; the inline rename's focus on
appear and its key monitor (space and the arrows handed to the field editor past the Tune menu); the
toolbar toggle beside the chip; the disclosure rows; that the `Show Inspector` title follows the
state; and that the widened telemetry subscription is accepted by the daemon and the log fills.

Revised 2026-09-23 after a review of the panel (the handoff's "Decided 2026-09-23"): the reading
is four fixed columns with the number beside each word and the sentence as a tooltip, the
popovers are gone, `ChannelReading` in the façade steadies the meters and words (12 tests), one
`MeterTrack` draws all three meters, Tuning and Deviation hold the last transmission dimmed, the
squelch is a tick on the Signal bar, On air reads `last heard`, and the log fills the height.
Not compiled in the container: `MeterTrack.swift`, the reading rows and their widths at 312 pt
(that `Not audible` fits the word column), the tooltips, the log's row count from its height,
and the bordered mini buttons under the identity.

### M2-5 `[x]` Clipping, measured rather than inferred

Found on the Mac 2026-09-20: "a signal is within 3 dB of full scale" popped up on FM broadcast
at auto gain, where a strong constant-envelope carrier sits near full scale all day and nothing
is wrong. The state infers the ADC's condition from the loudest FFT bin, which is a proxy; only the
daemon can measure it directly: samples at the rails (a cu8 byte at 0 or 255) counted
where every block is already converted, reported as capture telemetry (`CaptureLevel`: clipped
and total samples per interval, and the block's peak), with `ley levels`' OVER and `ley tune`'s
line reading it. The failure state becomes "the radio is clipping", reported only when it is, and
near-full-scale becomes a number in the inspector's Measurements. Until this lands the client
rule has hysteresis and gain-aware words (2026-09-20), which stop the flicker and the useless
"set it to auto", not the false alarm.

Landed 2026-09-20, the daemon's half and `ley`'s: `CaptureDSPCore.deliver` counts the rails on
the native block as it arrives (`Kernels.countAtRails*`, one pass, before the ring so a dropped
block still counts), `CaptureLevelMeter` publishes a reading per quarter second of samples
through a seqlock, and `TelemetryService` sends it as `CaptureLevel` (`CAPTURE_LEVEL = 6`) with
the interval's end as its time. The count is of complex samples with I or Q at a rail, not of
components, so the fraction is a fraction of time; the peak is the interval's largest component
against full scale. `ley levels`' OVER and `ley tune`'s failure line read it (`clippingFloor`,
one in ten thousand: a single rail hit in 600 000 samples is noise), say "The radio is clipping:
N of M samples (x.x %) hit the converter's rails" with the gain clause, and print nothing about
full scale when the level is clean, whatever the bins show; the loudest-bin rule stays only as the
fallback for a daemon that sends no level. The fake daemon emits one at 4 Hz with an
`Options.Clipping` hook. The app's half follows: the façade's failure state re-based on
`CaptureLevel`, and the near-full-scale number moving to the inspector's Measurements.

App half landed 2026-09-20: `FailureState.clipping` from `CaptureLevel` through a
`CaptureLevelFeed` per capture (one sample in ten thousand raises it, half that clears it, the
same floor as `ley`'s), the near-full-scale state dropped rather than kept as a fallback (the app
ships with its daemon), and the radio's peak and clipped fraction as two rows of the inspector's
Measurements.

### M2-6 `[ ]` The failure strip retired

Seen on the Mac 2026-09-23: a banner flashing in the panel, "weird, hard to read, and not
useful". The log names two causes. Every band or bookmark switch showed the out-of-capture
words for 90 ms (`shown: out of capture` / `cleared`, six times in the last minute of the log):
the window writes the centre first and the channel's offset second, and the mirror's channel
event between the two reads `OUT_OF_CAPTURE`, so the strip announced a state the window itself
was in the middle of leaving. And clipping comes in bursts of half a second to two seconds (a
keyed HT, an FM peak), each of which popped the strip in with no animation and pushed every
region under it down.

Stepping back: the strip carried two measured facts with one action each, and neither is the
panel's. Clipping is the radio's problem, and the radio already has a place, the toolbar's chip
and the device menu with the gain slider in it. Out of capture is the channel's problem, and the
identity region already has a line under the frequency for a channel's condition (`Changed from
the bookmark`). So the strip goes, and the facts move to where their fix is:

- **Clipping lives on the device chip.** While the state holds, the chip's dot is `caution` and
  the name reads `HackRF Pro · clipping`, the suffix in `caution`; the device menu's header
  carries the sentence (`FailureState.headline` and `detail`) under the state line, and the gain
  slider is right there. No close control: the words are a state, and they go when it clears.
- **Out of capture lives in the identity.** One line under the frequency, in `caution`:
  `Outside the radio's 20.000 MHz around 97.500 MHz`, with a mini bordered `Tune inside`
  button styled as `Revert` and `Save` are, which re-places the centre on the tuned frequency
  the way `setSampleRate` does. No close control.
- **A state is shown only once it has held.** Clipping is raised after the count has been over
  `clippingFloor` for 1 s of the capture's clock and cleared after 2 s under
  `clippingExitFraction` (the levels carry `SampleTime`; the hold is in the façade, beside
  `FailureState.name`, and unit-tested). Out of capture is shown once the mirror has reported it
  for 1 s. `ley tune`'s line does not change: it prints once per change and cannot flicker.
- **Gone:** `FailureStrip`, `dismissFailure`, `dismissOutOfCapture`, `dismissedFailure`, the
  `warnGround` and `warnBorder` tokens if nothing else draws them. The log lines stay: a state
  still logs when it is raised and when it clears, now after the hold.

Also, because the same session showed no PL on 1 029 GMRS transmissions and the log could not say
whether the daemon ever reported one: the feed logs the first sub-audible report whether it names
a tone or not (`lastToneHz` starts unknown, not at 0), and the transmission-ended line says which
tone the transmission carried or `no tone`.

Docs: `../design/app-design-handoff-m2.md` gets a "Decided 2026-09-24" entry and Region 2 is
marked retired; `../dev/app.md`'s failure-state paragraph follows.

### M2-7 `[ ]` The audio ladder in the panel

The M2 handoff's open item ("the audio levels meter `ley levels` draws, band by band, in the
panel"), decided 2026-09-23 by the owner: its own region between the reading and the log, the
demod tap, octave bands. The stream exists (`docs/design/audio-meters.md`: an FFT subscription
whose source is a channel, `FftParams.tap`, at most 20 rows a second; the daemon refuses raw
IQ), `ley levels` reads it, and the Swift client lacks only the call.

- **Façade** (`LeylineClient`): `DaemonConnection.fft(channel:tap:bins:rowsPerSecond:…)`
  beside `fft(capture:…)`, the same `BulkDecode.fftRows` under it. `BandLevels`, pure and
  tested, ported from `go/internal/cli/levels_bands.go`: the nine octave centres 63 Hz to 16 kHz
  with edges a factor √2 either side, a band's level as the power sum of its bins over the Hann
  window's noise bandwidth (1.5), the band too narrow for a bin reading its centre bin, and
  −120 dBFS as the floor. `LevelBar`, the ballistics: attack instant, release 20 dB a second, a
  peak cap that holds 1.5 s then falls 10 dB a second, timed on the sample clock from the rows'
  `SampleTime` and the capture rate. Tests mirror `TestLevelsBandSumsInPower` and
  `TestLevelsBallistics`.
- **Feed** (`AudioLevelsFeed`, the `SpectrumFeed` pattern): follows the tuned channel on the
  demod tap at 1024 bins and 20 rows a second, latest-wins, one subscription per channel, reset
  with it, stopped while the inspector is hidden and for a raw IQ channel. Folds each row into
  nine `LevelBar`s. `rms` and `peak` come off the meter (`audio_dbfs`, `audio_peak_dbfs`), never
  off a row, as `ley levels` does, so two clients report the same numbers. While the meter says
  the squelch is closed the bars are reset and stay unlit, because the demod tap carries the
  discriminator's noise between transmissions.
- **Region** (`AudioLevelsView`, after Region 3, a hairline either side): a `section` header
  `Audio`; a plot 64 pt high with a 22 pt dB gutter marked 0, −18 and −60 in `columnHead`
  `inkFaintest`, the −18 dBFS alignment line dashed across in `border`; eleven bars, the nine
  bands then a gap then `rms` and `peak`, each bar 14 pt in a 22 pt slot; the scale a meter's,
  6 dB per step from 0 to −24 and 10 dB per step to −60 (`ley levels`' scale, piecewise linear).
  The lit part is the level ramp (`Theme.levelStops`, cold at −60, hot at 0), the unlit part is
  drawn in `border` so the scale reads while nothing plays, the cap is a 1.5 pt `inkSecondary`
  line. Labels under the bars in `columnHead`: `63 125 250 500 1k 2k 4k 8k 16k`, `rms`, `peak`;
  the meter's two numbers under the pair in `valueSmall` `inkTertiary`, `—` before a meter. One
  `Canvas`, redrawn as the feed changes. No `OVER`: clipping is the chip's (M2-6).
- **The log gives up its spare rows** and keeps its five; at 820 pt everything still fits
  (header 36, identity ~70, reading ~112, audio ~120, log 155, Measurements 30).
- **e2e** (`LeylineClientDaemonTests`, `nfm_pl.cf32` on the demod tap): the 125 Hz band (the
  100 Hz PL) and the 1 kHz band read well over the 8 and 16 kHz bands.

Docs: the M2 handoff gains "Region 3b: audio" and the open item is closed; `../dev/app.md` lists
the feed; `docs/dev/app.md`'s unverified list names the view, which the container cannot build.

### M2-4 `[ ]` The lifecycle half of APP-6

The daemon not running and the radio unplugged already have empty-state messages in the window,
and an unplug is the `CAPTURE_DETACHED` transition the mirror keeps. Left for M2: the app starting
the daemon, which waits for APP-7's launchd job. Nothing to build until then; recorded so APP-6 is
not read as untouched.

### APP-5 `[ ]` Recording from the window (E.5)

Start and stop over C.12 (`Jobs.StartJob(RecordConfig)`), the job rendered from the mirror's
`jobs`, reveal in Finder through `Resources.ResolveLocalPath`.

### APP-6 `[ ]` Lifecycle and the inspector (E.6)

The daemon not running (reported, with `ley daemon start` offered and, once APP-7 installs the
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
