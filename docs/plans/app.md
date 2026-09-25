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

### M2-6 `[x]` The failure strip retired

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

Landed 2026-09-24: `FailureHold` in the façade (`FailureState.swift`) folds each `CaptureLevel`
through `FailureState.name` and times the run from its first interval's first sample, so four
quarter-second readings are one second; a reading on another capture, or none, starts again,
and five tests cover the half-second burst, the second that shows, the one-second gap that
does not clear, the two seconds that do, and the exit fraction. `CaptureLevelFeed` keeps the
reading's `SampleTime` for it. Out of capture waits on a main-actor task started when the
mirror first reports the state and cancelled when it leaves, so the words cannot show early.
The chip's dot and suffix and the menu header's sentence read `AppSession.failure` directly;
the identity's line reads `outOfCaptureWords`, now `Outside the radio's … around …`, and
`AppSession.tuneInside` shares `placedCentre` with `setSampleRate` and logs under `tune`.
`FailureStrip`, both dismissals, `failureShown`, `warnGround` and `warnBorder` are gone.
`ChannelTelemetryFeed` logs the first sub-audible report of each channel, and the
transmission-ended line ends ` · PL 100.0` or ` · no tone` from the log entry it closed (none
for an opening shorter than `TransmissionLog.shortestSeconds`). The views are not compiled in
the container: the chip, the header's wrapped sentence, the identity line and its button, and
the out-of-capture wait are unverified until a run on the Mac.

### M2-7 `[x]` The audio ladder in the panel

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

Landed 2026-09-24. Façade: `fft(channel:tap:bins:rowsPerSecond:format:policy:buffer:)` on
`DaemonConnection` in `Streams.swift`, the same `BulkDecode.fftRows` under it and DB_F32 by default,
as `ley levels` asks; `AudioLevels.swift` with `BandLevels` (the nine octaves, the power sum over
the window's 1.5 bins of noise bandwidth, the centre-bin fallback, the −120 dBFS floor, filled in
place so a row allocates nothing past its decode), `LevelScale` (the piecewise scale and the −18
alignment level) and `LevelBar` (the ballistics, on whatever clock the caller folds with);
`AudioLevelsTests`, six cases, two of them `TestLevelsBandSumsInPower` and `TestLevelsBallistics`
with Go's numbers. One difference from Go: a cap's hold summed from row intervals in `Double` ends a
row early (thirty of 0.05 s is 1.5000000000000002), so the hold has a microsecond of slack where
Go's `time.Duration` is exact. App: `AudioLevelsFeed` beside the other feeds in
`SpectrumFeed.swift`, followed from `AppSession.mirrorChanged` and from `inspectorShown`'s `didSet`,
handed every meter through `telemetry.onMeter`, and resubscribing on a mode change, because the
tap's audio rate is the mode's; its bars are stored outside Observation and published once per row.
`AudioLevelsView.swift`, one `Canvas`, placed after `ReadingsView` with a hairline; the `audio*`
tokens in `Theme.Layout`; `Measure.bare` for the two numbers. The region is about 136 pt against the
~120 this item estimated, and the panel still comes to about 545 pt. e2e:
`testAudioSpectrumBandsReadTheFixturesTones` on `nfm_pl.cf32` asks for 20 dB over the louder of 8
and 16 kHz in both the 125 Hz and the 1 kHz band; against the Linux-built daemon the bands read
−11.3, 0.0, −49.6 and −95.6 dBFS, the first two as `ley levels` reads them in
`go/internal/e2e/meters_test.go`. The suite ran against a `leylined` built earlier the same day from
`main`, not rebuilt from this change, which touches no engine code. Not compiled in the container:
`AudioLevelsView.swift`, the feed and the session's wiring; the Canvas's layout at 312 pt (the 272
pt ladder inside the 280 pt of padding), the gutter marks' anchors at the plot's top and bottom, a
`−120` under the pair overflowing its 22 pt slot, the dashed line's visibility over the unlit
`border` bars, the gradient's direction, and that the window's subscription starts and stops with
the panel and the channel.

### M2-8 `[x]` Clipping drawn, not written

Seen on the Mac 2026-09-23, after M2-6: "I noticed the clipping warning in the hardware
popover. That's not very discoverable. Remove the written warning entirely and think about
where else we could surface clipping." Chosen by the owner from a list: three indicators, one at
the picture, one at the radio, one at the fix, none of them a sentence.

- **The waterfall records it.** A row captured while the radio clipped carries a 2 px
  `recording` mark at the waterfall's left edge, so the picture shows when and for how long,
  and the mark scrolls away with the row. Which rows: those whose `SampleTime` falls inside a
  `CaptureLevel` interval (its `time` is the interval's end, `total_samples` its length) whose
  clipped fraction is at or over `FailureState.clippingFloor`, the raw per-interval count, not
  the held state, because the mark is the record and the hold is for the chip. Levels arrive
  after the rows they cover, so marking is retroactive: `WaterfallBuffer` keeps each row's
  sample index beside its levels and a flag per row; `CaptureLevelFeed`'s reading marks the rows
  in its interval; the renderer uploads the flags as a one-column texture beside the ring and
  the fragment shader paints the first two pixels of a flagged row's line `recording`.
- **The chip's dot, no words.** While the state holds the device chip's dot is `caution` and
  the sentence (`headline` and `detail`) is the chip's tooltip (`.help`). The ` · clipping`
  suffix and the device menu header's sentence from M2-6 go.
- **The gain slider lights.** `GainSlider`'s knob is `recording` while the state holds, so the
  fault is on the fix.
- `FailureHold` and the `failure:` log lines are unchanged.

Docs: the M2 handoff's "Decided 2026-09-24" gains the change; `../dev/app.md`'s failure-state
paragraph names the three places.

Landed 2026-09-24: `ClippedRows` in the façade (`ClippedRows.swift`) keeps a sample index and a
flag byte per ring slot, preallocated at `WaterfallBuffer.capacity`; `append` clears the new
row's flag, and `mark(_:at:)` flags every held row inside a reading's interval when its clipped
fraction is at or over `clippingFloor`. Every held row is compared rather than stopping at the
first older one, because after a change of capture the ring still holds rows on the old clock.
Eight tests cover the interval, an empty one, a reused slot, overwritten rows, the reset, the
floor, a reading under it, and an interval longer than the clock. `WaterfallBuffer` holds one
beside its levels, `SpectrumFeed.ingest` passes each row's sample index, and `AppSession`'s
`onLevel` handler marks the rows when the reading's capture (`CaptureLevelFeed.capture`, now
readable) is the waterfall's subscribed capture. The renderer sends the flag column whole every
frame with `setFragmentBytes` at buffer index 2: 2048 bytes is under the 4 KB that call takes,
and a reading flags rows already drawn, so tracking the touched slots would save nothing worth
the code. The shader returns `recording` (three floats appended to `WaterfallUniforms` from
`Theme.recordingRGB`) for a flagged row's pixels whose centre is under x = 2. The chip lost its
suffix and gained `.help` with `headline: detail` while clipping and the radio's name
otherwise; the menu header's sentence is gone; `GainSlider` takes `clipping` and its knob is
`recording` while it holds. The views and the shader are not compiled in the container: the
marks, their colour and scroll, the tooltip and the knob are unverified until a run on the Mac.

### M2-9 `[x]` dB and margin on the spectrum

Asked 2026-09-23: "Could the trace show dB and/or SNR?" Today the window is the held floor
less 10 dB to the floor plus 70, labelled only at its two ends, over an unlabelled 10×4 grid,
and the pointer's badge names the frequency alone. The terminal's `ley spectrum` draws the
floor as a rule labelled on the axis so height above it reads as margin (`docs/dev/cli-style.md`,
"A chart draws its trace, not its area"), and prints `N dB above the floor` for a peak. The
window follows it:

- **The floor is a rule.** A dashed `borderStrong` line across the plot at `floorDB`, labelled
  `floor −78` at the right edge in `valueSmall` `inkFaint`, beside the two end labels that stay.
- **The grid's rows are dB over the floor.** The four horizontal lines sit at the floor plus
  10, 30, 50 and 70 dB (the window's rows are 20 dB, so this is where they already fall, moved
  to start at the rule), each labelled at the left edge `+10`, `+30`, `+50`, `+70` in
  `columnHead` `inkFaintest`. The absolute scale reads on the right, the margin on the left.
- **The badge carries the level.** The pointer's badge reads
  `146.520 MHz · −52 dBFS · 26 dB over the floor`, the column's loudest bin as the trace draws
  it, and `—` for both before a floor is held. During a drag the swept clause stays and the
  level clause is dropped, so the badge stays one line.
- The 150 pt height and the grid's ten columns do not change.

Landed 2026-09-24. Façade: `SpectrumFold.levelWords(levelDB:floorDB:)` prints the level clause,
whole dB with U+2212 and no plus, the margin taken as the difference of the two rounded numbers
so it agrees with the level beside it and with the rule's label, and dashes for a NaN or
infinite level or floor; two tests in `SpectrumFoldTests`. App: `SpectrumView.draw` strokes the
grid's rows at the floor plus `gridStepsDB` (10, 30, 50, 70, the last the top edge) once
`floorDB` is held, the three interior lines as before otherwise, and draws the dashed rule and
`floor −78` before the traces. The margin labels sit under their lines at the left edge: above
its line `+50` would overlap the max-hold chip (8 to about 29 pt from the top, against 24 to 35
for the label at 150 pt), and `+70` is the top edge, under the chip either way, so it is not
labelled. The badge's level is the newest row's `Columns.loudest` for the column under the
pointer, computed in `PointerOverlay` from the chart's own `Columns` and the pointer's x, so it
is the column the trace draws and not one bin; `AppSession.pointerWords(_:levelDB:)` adds the
clause or, during a drag, the swept figure instead. On the waterfall the column is the
waterfall's, the same width. The badge now measures its width (`onGeometryChange`) for the
right-edge clamp, which assumed 130 pt, and is `fixedSize` so it stays one line. Not compiled in
the container: `SpectrumView.swift`, `ChartMouse.swift` and the session's change; unverified
until a run on the Mac are the label positions against the chip and the end labels, the rule's
visibility in `borderStrong` under the traces, the half-drawn top grid line at y = 0, and the
badge's width (about 310 pt for the full clause) and clamp near the right edge.

### M2-10 `[x]` Clipping said once, in both clients

Seen 2026-09-24 in `ley tune 462.5625` with a keyed handheld a metre from the HackRF: the
clipping line printed on every quarter-second reading, seven times with seven counts across one
transmission; "Nothing is above the noise … the gain is at its lowest. Turn it up" printed
three times, between overs, though the design has it warn once at tune; and "at the lowest gain.
Move the antenna away" was said at LNA 8 dB and VGA 20 dB, because the rule counts any stage at
its minimum and the AMP, a two-value stage, was off. The owner: "the TUI should handle these
clipping alerts more gracefully."

- **The hold the app has, in `ley tune`**: raised after 1 s over `clippingFloor`, cleared after
  2 s under the exit fraction, on the capture's clock, one line when raised and nothing when it
  clears (the transmission's summary line already carries the peak). The count in the line is
  the reading that raised it.
- **The quiet-band line is said once, at tune**, from the first rows, and never again in the
  session; it is not a state the tracker re-raises.
- **"At the lowest gain" means every continuous or table stage is at its lowest.** A two-value
  stage (the HackRF's AMP) does not count. When one such stage is not at its lowest the advice
  names it: "Lower the VGA gain." The façade's `FailureState.gainAtMinimum` and `detail` follow
  the same rule, with tests for a HackRF at LNA 8 / VGA 20 / AMP off (not at the lowest, names
  the VGA) and at 0 / 0 / off (at the lowest).
- **`ley record --gain 0` on the HackRF left LNA at 8 dB** (the take's sidecar). Find out whether
  the flag reaches the job's capture and fix it if it is a plumbing gap.

Landed 2026-09-24. `ley tune`: `clipHold` (`go/internal/cli/cliphold.go`) is `FailureHold`'s rule
in Go, timed on the readings' `SampleTime`; the live loop prints one line when it raises,
carrying the reading that raised it, and nothing when it clears. The banner's failure line is now
`bandWords` alone, the quiet-band or full-scale reading of the first row, so it is said once at
tune and never re-raised; the persistent tune and the MCP adapter's tune tool, which have no live
phase, still print the one-shot `failureWords`. `clipping` counts a reading at the floor itself,
as the app always did (`>=`), where `ley` had used `>`. "At the lowest gain" is now every
continuous or table stage by hand at its lowest, a two-value stage (`valid_db` of two entries,
`step_db` 0: the HackRF's AMP) left out, in `gainAtMinimum` and in the façade's
`FailureState.gainAtMinimum`; with some stage above its lowest the advice names the stages above
it in the device's order ("Lower the VGA gain.", "Lower the LNA or VGA gain." for the owner's
LNA 8 / VGA 20), and a radio with one stage keeps "Lower the gain." The case carries the names
(`lower:`), `namesGain` follows, and both clients' tests hold the HackRF at 8/20/0 and 0/0/0 and
an RTL at 0 (`TestFailureWordsOnAMultiStageRadio`, `FailureStateTests`). `--json` is untouched:
it never carried these lines. `ley record` has no failure line; `ley levels`' OVER reads
`clipping` and its two-second hold is its own.

The gain finding: the record job's `applyGain` (`JobStore+Record.swift`) passed the CLI's empty
element straight to the device, and `try?` dropped the refusal, so `ley record --gain` has never
reached a real radio; the synthetic test device refuses an element that is not its own, which is
how `RecordingJobTests` now shows it. An empty element now resolves to the first stage through
`resolvedGainElement`, which the gain write and the sweep's pin share and which matches a name
ignoring case, and a refusal fails the job with the device's code and "the gain asked for could
not be set: …". Asked by the owner in the same session ("could you do --gain 0 --element VGA
--gain 0 --element LNA?"), `--gain` on `tune`, `record`, `play`, `listen`, `levels`, `scope` and
`waveform` also takes stage=dB pairs, `--gain LNA=0,VGA=0`, applied in the order given:
`RecordConfig.gains = 16` carries them to a job (additive; `gains` wins over `gain`), `tune`
writes them one `ParamWrite` at a time, and a stage the radio does not have is the daemon's
refusal with the stages it has ("no gain element named IF; this radio's are LNA, VGA and AMP").
Both banners list every stage on a radio with several (`Radio HackRF Pro, gain LNA 0.0 dB, VGA
0.0 dB, AMP 0.0 dB`); the record banner's `Radio` line is new and appears when a stage was set
by hand. `ley set gain N --element X` and `ley scan --gain` are unchanged, and the app sends no
`RecordConfig` yet, so the contract addition's mirror is `ley record` itself. The fake applies
the writes, fails the job the same way and gained a HackRF descriptor (`fakedaemon.HackRFPro`).
On the same afternoon `ley tune` read the owner's handheld on DCS 023, 754 and 664 correctly on
the first key-up of each; the 664 seen in that session's transcript was the radio's setting, not a misread.
Not verified here: the whole thing against the HackRF itself, and `ley recordings show`, which
still names only the first stage.

### APP-5b `[x]` The Library: two places, one switch

Decided 2026-09-25 with the owner after the first run of the recording screens
(`../design/app-design-handoff-m3.md`, "Decided 2026-09-25: the Library"): a `Radio | Library`
switch in the toolbar (⌘1, ⌘2); Radio is the window with 8a and 8b and no sidebar source or
footer; Library replaces the body with the channel list and store footer in its sidebar, 8c's
channel page in the centre, the part in the inspector, and a player in the transport bar's
place (play/stop, previous/next part, the part's words, a display-only progress track, the
volume caption); the live radio keeps running underneath and is held silent while a part plays.

Landed 2026-09-25 (the handoff's "Decided in the build" bullets record what the build decided:
the switch as two plain buttons, the body switched rather than overlaid, the selection rule, the
channel's lines, the player's part, the keys and the caption). Façade, `RecordingPages.swift`:
`PlayerWords` and `Recordings.playerWords` (`GMRS CH3 · Tuesday 14:02 · part 5 of 11`,
`16:11:04 · 10.0 s`, `0:03.8` and `0:10.0`, the fraction), `Recordings.neighbourPart` (⏮ and ⏭
in part order, nil at the ends and for another recording's part) and `PlayQueue.start(_:at:)`
(Play all from a part); `partWords`' title shares `recordingStartWords` with the player. Session:
`place: WindowPlace` in the defaults under `place` replaces `sidebarSource`; arriving in the
Library selects the first channel, as does a listing that arrives with none selected; the audio
ladder follows only in the Radio; `player`, `canStepPart`, `stepPart`, `togglePlayer`,
`channelTitle(of:)`, and `pressSpace`/`pressArrow`, the one dispatch both menus' bare keys go
through; `revealInFinder(uri:)` takes a recording's URI as well as a part's. Window:
`MainWindow` switches its body between `RadioBody` (today's window) and `LibraryBody`
(`LibraryView.swift`: `LibrarySidebar` with the search field, `CHANNELS`, the rows and
`StoreFooter`, moved from `SidebarView.swift`; `RecordingsPage`; `LibraryInspector`, the part or
`ChannelSummary`; and `PlayerBar.swift`), and draws `PlaceSwitch` at the toolbar's leading edge.
`SidebarView` is bands and bookmarks only, `InspectorView` the Channel panel only, and the
`Radio | Recordings` picker, the Radio's store footer and the canvas overlay are gone. Menus: View
▸ Radio (⌘1) and Library (⌘2), checked by the place; the Library menu's Play/Stop (space),
Previous Part (←) and Next Part (→); the Tune menu's Tune Up, Tune Down and Mute disabled in the
Library; `TextFieldKeys` gives a bare key back to a text field being typed into. Theme:
`Font.transportGlyph`, `Layout.transportButton` and `Layout.playerWordsWidth`. `VolumeControl`
takes `library` for the `GMRS CH3 · live` caption.

Verified in the container: `RecordingPagesTests` (the player's words idle, playing, clamped at
the part's length and undated; ⏮ and ⏭ in part order from a shuffled manifest, at both ends and
for another recording's part; Play all from a part and a step back), and in
`LeylineClientDaemonTests` the recording case, which now builds the player's words and checks ⏮
and ⏭ against the daemon's own manifest. `make app-lint`, `swift test --filter
LeylineClientTests` and `make app-e2e` pass.

Unverified until the first `make app-run` on a Mac: every change in `AppSession.swift`,
`LeylineApp.swift`, `MainWindow.swift`, `LibraryView.swift`, `PlayerBar.swift`,
`RecordingsPage.swift`, `PartInspector.swift`, `InspectorView.swift`, `InspectorGroups.swift`,
`SidebarView.swift`, `TransportBarView.swift` and `Theme.swift`. Named behaviours: the switch at
the toolbar's `navigation` placement with its hidden shared background, beside the window title,
its two inks and hit areas; ⌘1 and ⌘2 and their check marks; the Radio's Metal view made again
on ⌘1, how long the shader's compile from source takes there, and the waterfall coming back with
its rows; the Radio's sidebar starting at the Bands header with the picker gone; the Library's
sidebar at 236 pt with the empty sentence wrapping, the `CHANNELS` header, the footer at its foot;
the first channel selected on arrival and on a cold start in the Library; the page in the centre
without the canvas under it, and its notice strip; the channel's lines and Show in Finder
selecting the newest recording's directory; the player at 88 pt: the circle, the mini bordered
⏮ ⏭ and their disabled state at the ends, the two lines at 260 pt truncating, the track and its
ends moving four times a second, the caption `GMRS CH3 · live` and `playing a part · GMRS CH3
held`; ▶ with no selection playing the top card's first part; ⏭ during Play all walking on and
the live sink not coming back between parts; space, ← and → reaching the Library menu and not
the Tune menu in the Library (and the reverse in the Radio), including when the Commands body has
not re-evaluated; a space and the arrows typed into the search field staying in the field
(`TextFieldKeys`, which assumes the field editor is the key window's first responder and that
`insertText(_:replacementRange:)` with the selection is what typing a space does); the bookmark
rename field in the Radio, which the Tune menu's bare keys may reach first as they could before.

### APP-5c `[x]` The Library, revised (10a)

The owner's screen 10a (`../design/app-design-handoff-m3.md`, "10a · The Library, revised"):
rows are parts with a recording as a bracket in the gutter, a level graph a row, a 24-hour
strip a day, `Play day`, the inspector as the part's numbers and its recording's, the sidebar
grouped by frequency, the switch as a segmented control by the traffic lights, and a player
that pauses. Engine lane first: `clipped_ms` a part, `Playback.paused` with
`SetPlaybackPaused` and `ley play`'s space, and empty recordings discarded at job end.

**Engine lane built 2026-09-25** (the four asks; the window's side is still to come).
`RecordingPart.clippedMs` and the sidecar's `recording.clipped_ms` come from the capture's
`CaptureLevel` readings, read by the runner off the meter the telemetry service publishes from and
charged to a part by overlap at the 1e-4 floor (`ClipLedger`); `ley recordings show` gains `CLIP`
when a part clipped. `Playback.paused` and `Control.SetPlaybackPaused` hold the position, the
4 Hz event is not sent while paused, any client may pause as any may stop, and `ley play` pauses
on space on a terminal. A record job that writes no part removes its directory and ends
`COMPLETED`, `nothing was heard`; `ley record` and the MCP `record` tool say `Recorded nothing:
the squelch never opened.` Verified by `RecordingTests` (a synthetic level feed),
`RecordingJobTests` (a file at the rails, pause across 0.5 s, `noise_floor` gated and cancelled),
the fake's own tests and the CLI and MCP tests against it (`../design/recording.md`, "The part
sidecar", "Nothing heard", "Playing a recording back"). For the window: `0.0 dBFS · clipped` and
`Clipped for 0.4 s.` read `clipped_ms`, never the peak; the player's ⏸ is `SetPlaybackPaused` and
renders `Playback.paused` from the mirror; a recording that heard nothing never reaches
`ListResources`, so the Library needs no filter of its own for it.

**Landed 2026-09-25 (window).** With both lanes in, the item is `[x]`. What the build decided
that 10a left open is the handoff's "10a", "Decided in the build (APP-5c, 2026-09-25)". Façade:
`RecordingPart.clippedMs` (`clipped_ms`, absent when nothing clipped); `Recordings.channels` by
frequency alone, the mode the newest recording's and the subtitle `19 recordings · today`;
`LibraryRows.swift` with `Recordings.dayRows` (`DayRows`: title, EARLIER, head and EARLIER words,
rows with their bracket and gap, the strip's `DayMark`s, `playOrder`), `PartRow.words`
(`PartRowWords`) and `Recordings.partInspectorWords` (`PartInspectorWords`); `LevelGraph.swift`,
the WAV reader and its columns; `PlayQueue.start(parts:)` and `holds(recordingURI:)` for Play
day; `Recordings.playerWords` as `GMRS CH3 · Today` over `14:03:20 · part 4 of 4`; 8c's delete
line cut to `Deletes all 4 parts.`. 8c's card and chip model went with the cards
(`RecordingDay`, `Recordings.days`, `rangeWords`, `countWords`, a chip's words, `PartWords`,
`partWords`, `partTable`, `FlowRows`). Window: `RecordingsPage.swift` rewritten as day sections
(`DaySection`, `DayStrip`, `PartColumnHead`, `PartRowView`, `LevelBars`, `EarlierDay`, `PlayDayButton`)
under the header as built, with the notice strip and `FlowLayout` gone; `PartInspector.swift` as
10a's two sections with no progress bar; the sidebar without its `CHANNELS` header; the place
switch's raised segment; the player's ⏮ ⏸/▶ ⏭, words and caption; `AppSession`'s `clickRow`,
`playDay`, `pausePlayback`, `isPaused`, `pageDays`, `openedDays`, `levelGraphs` and
`loadLevelGraph`, and `togglePlayer` pausing while a playback exists; the Library menu's Play,
Pause or Resume on space and a Stop with no key; `Theme`'s row, strip, level-graph and switch
tokens and `Font.playingGlyph`.

Verified in the container: `RecordingPagesTests` (a store of six recordings written to disk and
read back, two days and two EARLIER recordings, one clipped part, one with no parts: the rows,
brackets, gaps, marks, head and EARLIER words and Play day's order; a recording past midnight and
an undated one; a row's words; the inspector's words on the clipped part and a clean one, running
and not; the player's words; the level graph from written WAVs, with a LIST chunk, and its
refusals of stereo, 8-bit and a non-WAV), `RecordingsTests` (`clipped_ms` parsed and absent, the
channels by frequency), and in the daemon-backed suite
`testTheWindowsRecordingHoldsTheTransmissionsHeardLive`, which now checks that the clean fixture's
parts carry no `clipped_ms`, builds the day rows and the inspector's words from the daemon's own
manifest and a level graph from its WAV, and pauses a playback and checks the position holds for
0.5 s. The pause check needs the daemon's audio output, so on Linux `StartPlayback` answers
`PLATFORM_UNSUPPORTED` and the check prints that it was not run; it runs on a Mac. `make
app-lint` passes.

Unverified until the first `make app-run` on a Mac, because nothing in `LeylineApp` compiles in
the container: every change in `RecordingsPage.swift`, `PartInspector.swift`, `PlayerBar.swift`,
`LibraryView.swift`, `MainWindow.swift`, `AppSession.swift`, `LeylineApp.swift`,
`TransportBarView.swift` and `Theme.swift`. Named behaviours to check there: the rows' columns
lining up with the column head at the window's default width, and `−60.0 dBFS` fitting the peak
column; the bracket's three pieces joining into one line across a recording's rows and stopping
at the first and last ring's middle; the 10 pt gap between recordings and none inside one; the
playing row's 28 pt circle inside the 30 pt row without moving the times; the strip's labels
under the track, 00 and 24 at its ends, and the playing mark over the others; the level graph
loading as rows scroll into view and staying empty for a path the daemon cannot resolve here;
the EARLIER line's chevron turning and the day opening in place; a row's click playing, pausing
and resuming, and the circle, the row and the menu item all showing the pause from the mirror;
space pausing while the search field is not being typed into; Library ▸ Stop ending a paused
part and the live channel coming back; Play day walking a day's parts oldest first across
recordings; the place switch's raised segment beside the traffic lights; the inspector's
clipped Peak in `accentRec` and the sentence wrapping in 312 pt; the player's bare ⏮ and ⏭; and
the volume caption while a part plays and while it is paused.

### APP-8 `[ ]` The mark, the splash and the icon

The owner's brand files, 2026-09-25 (`../design/brand/leyline-mark.svg`, a 13 pt ring with a
dot; `leyline-splash.svg`, the mark, `leyline` in Space Grotesk 62 at −0.04 em, and `SOFTWARE
DEFINED RADIO` in mono between two rules). Both are drawn in code, not loaded: two circles and
two lines, in `accent` (`#E8814A`), `ink` and `inkMuted`; Space Grotesk is not bundled (M1), so
the wordmark is SF at 62 medium with the same tracking.

- **The mark in the title bar**, 13 pt in `accent`, then `Leyline` in `label` `ink`, as the
  first leading toolbar item before the place switch; the window's own title is hidden so the
  word is drawn once.
- **The splash**, "cool, but quick": on the first window's first appearance an overlay on
  `ground` fades the mark and wordmark in over 0.4 s, holds until the daemon is live or 1.2 s
  have passed, whichever is later (2 s at most), then, over 0.7 s with an ease-in-out: the
  wordmark and the rule line fade; the ring grows to the window's diagonal and thins to nothing,
  a ripple leaving the centre; the mark itself shrinks and travels to its place in the title
  bar (one `matchedGeometryEffect` between the splash's mark and the toolbar's), and the body is
  revealed under it by a mask that sweeps from the top down, the way a waterfall row lands. No
  splash on later windows or when the app was launched by a URL. `Reduce Motion` on: a plain
  0.3 s cross-fade.
- **The icon**: the mark in `accent` on `ground` inside the macOS icon shape, rendered at
  bundle time by `scripts/render-icon.swift` (CoreGraphics, macOS only) into every size
  `iconutil` needs, `AppIcon.icns` placed by `scripts/bundle-app.sh` and named in `Info.plist`;
  the same drawing at 1024 px is checked in as `../design/brand/leyline-icon.png` when first
  rendered on a Mac, so the docs have it. This closes the M1 handoff's open "An icon" item.

### M2-4 `[ ]` The lifecycle half of APP-6

The daemon not running and the radio unplugged already have empty-state messages in the window,
and an unplug is the `CAPTURE_DETACHED` transition the mirror keeps. Left for M2: the app starting
the daemon, which waits for APP-7's launchd job. Nothing to build until then; recorded so APP-6 is
not read as untouched.

### APP-5 `[x]` Recording from the window (E.5)

Start and stop over C.12 (`Jobs.StartJob(RecordConfig)`), the job rendered from the mirror's
`jobs`, reveal in Finder through `Resources.ResolveLocalPath`.

Designed 2026-09-24, from a survey of eight SDR applications and the scanner loggers, and the
owner's choices. The owner's ask: "monitor a channel, say a repeater, and leave ley recording.
Then come back and be able to see the chunks."

**The transport bar's button is the audio control.** Every desktop SDR app stops the whole
radio with its main button and mutes with a separate one; none freezes the waterfall. The
window's radio is the daemon's and shared, so the button keeps today's behaviour (pause detaches
the channel's sink, play attaches one) and is drawn as what it is: a speaker, `speaker.wave.2`
and `speaker.slash`, the help text "Mute: the channel's audio is detached; the radio keeps
running". The Tune menu gains **Stop listening (⌘.)**, `ley stop`'s act: the channel removed,
the capture this window made destroyed, the waterfall at its empty state. The waterfall never
pauses.

**A gated recording is the transcript with audio attached** (`../design/recording.md`), one part
per exchange on the sample timebase, and the inspector already lists the channel's transmissions.
So the chunks are the log's rows:

- **The record control is the inspector header's**: `Channel` on the left, a mini bordered
  `● Record` on the right. While recording, a `recording` dot, `12 min · 4 parts · 6.9 MB` (from
  `Job.status_detail`, the daemon's own words), and `■ Stop`. The job is the frequency form of
  `RecordConfig` with the channel's frequency, mode, width and squelch copied at the start, gated
  by squelch (pre-roll and hang at the daemon's defaults, no duration, no stop-after-quiet), so
  it owns its channel and outlives the window, a retune and a quit. A band switch degrades it
  (the daemon's "out of capture, will resume") and the header shows the job's `status_detail` in
  `caution` until it resumes. File menu: **Record Channel (⌘R)**, **Record Continuously** (gate
  none), **Stop Recording**, **Show Recordings in Finder**.
- **A recorded row plays.** The log's rows gain a trailing 16 pt column with `play.fill` in
  `inkTertiary` on a row whose transmission lies inside a part (same capture, part start ≤ the
  transmission's start, its end ≤ the part's end). Clicking starts `Control.StartPlayback` on
  the part's URI: the daemon plays it through the speakers; the window detaches the live
  channel's sink meanwhile and reattaches it after, so the clip is heard alone; the row shows
  `stop.fill` and a 2 pt `accent` progress line along its bottom from the playback's `position`
  over `samples` (the mirror's `playbacks`). One playback at a time; a clip replays from its
  start (pause and seek are the recording design's named additive fields, not this item).
- **Coming back.** The parts come from the recording's manifest, read through
  `Resources.ResolveLocalPath` and `recording.json` (the window is local, as `ley recordings
  show` is), re-read on every `Job` event for the job and once on adoption. On adoption with no
  live rows yet, the log is seeded from the newest recording on the tuned frequency, running or
  not: one row per part, with the part's wall time through its anchor, its length and its peak
  in the signal cell, so the chunks are there before any transmission arrives; live rows and
  part rows merge by sample time. The log's header names the recording (`recording since 18:09`).
- **Recordings in the sidebar**, a section under the bookmarks: newest first,
  `462.5625 NFM · Tue 18:09 · 12 min · 4 parts`, the running one first with its dot and live
  counters, from `Resources.ListResources(RECORDING)` re-read on job events. Click tunes there
  (band, frequency, mode) and the log shows its parts. Context menu: Reveal in Finder, Delete
  (with confirmation; `Resources.DeleteResource`, added 2026-09-24 with `ley recordings delete`
  as its mirror, refused while the job runs), Stop Recording on the running one.
- **Not in this item**: IQ recording (M4), pause and seek of a clip, a bottom drawer (the M3
  ladder row's band history and shared selection come later and may take the parts list with
  them), scheduled recording.

Lanes: the contract and daemon (`DeleteResource`, `ley recordings delete`, the MCP mirror),
the façade (a Swift `RecordingManifest` reader, the part-to-transmission match, tests), the
window (header control, log column and progress, sidebar section, transport glyph, menus).

Landed 2026-09-24 (contract and daemon). `Resources.DeleteResource(ResourceRef)` returns
`DeletedResource{uri, freed_bytes}`: `ResourcesService.deleteResource` over
`RecordingStore.delete`, which removes the job's directory and reports what it held on disk, the
same number `ListResources` gives as `size_bytes`. A part's URI is `INVALID_ARGUMENT`, a missing
recording `JOB_NOT_FOUND`, and a job still `RUNNING` or `DEGRADED` `FAILED_PRECONDITION` ("job_… is
still recording; cancel the job first, then delete it"). The table's generic code fits, since a
client has one precondition to act on here, so no code was added. Nothing is emitted on the event
plane and the job's entry is untouched, so the window re-reads `ListResources` after a delete. The
fake has the same RPC and refusals (and now lists `size_bytes` as the directory's size on disk, as
the daemon does), `go/pkg/leyline` has `DeleteRecording`, `ley recordings delete <id> [--yes]`
asks on a terminal and needs `--yes` from a script, and `ley mcp` has `delete_recording`.
Verified by `RecordingJobTests` (`testDeletingAFinishedRecordingRemovesItsDirectory`,
`testDeletingARunningRecordingIsRefused`, `testTheDeleteRefusals`), `TestRecordingsDelete*`,
`TestMCPDeleteRecording` and the help goldens. No eval scenario: `docs/dev/evals.md` has no rule
for destructive tools, and the unit test grades everything a scenario could. The façade and
window lanes are open, so the item stays `[ ]`.

Landed 2026-09-24 (façade and window), from the design above and the handoff written from it,
`../design/app-design-handoff-m3.md`, whose "Decided 2026-09-24" records where the build and
the design differ. With both lanes in, the item is `[x]`. Façade: `Recordings.swift`, with
`RecordingManifest` and `RecordingPart` (`recording.json` decoded with the daemon's defaults for a
missing key, NaN for an absent squelch, and `read(at:)` for the directory `ResolveLocalPath`
returns), `RecordingParts.match` (the containment rule on the part's capture, from the manifest's
one anchor capture or, across two captures, the part's sidecar), `RecordingParts.merge` (the
log's rows: each live transmission with its part, each part no live row lies inside as a row,
merged by start sample; chosen over a `TransmissionLog.seed` so the log stays a fold of squelch
edges alone), `Recordings.config` (the frequency form, gated by squelch or `NONE`),
`Recordings.activeJob`, `Recordings.statusWords` and `RecordingSummary` (a `ListResources` row).
Window: `AppSession`'s recording section (`startRecording(continuous:)`, `stopRecording`,
`recordingJob`, `recordingStatus`, `recording`, `recordings`, `logEntries`, `play(partURI:)`,
`stopPlayback`, `deleteRecording`, `revealInFinder`, `showRecordingsInFinder`, `stopListening`,
`toggleMute`, `isMuted`), the inspector header's `● Record` and running status with `■ Stop`,
the log's play column with its progress line and recording line, the sidebar's `Recordings`
with its context menu and delete confirmation, the speaker glyphs, File's four items and Tune ▸
Stop Listening (⌘.). Two things the design did not foresee: the daemon emits a playback's event
only at its start and its end, so the position is polled from `GetState` at 4 Hz as `ley play`
polls it; and a record job rides the window's capture (the allocator reuses a capture that
covers the frequency), so Stop Listening destroys the capture only when no other channel is on
it, or it would end the recording.

Verified in the container: `RecordingsTests` (11 cases: the manifest parsed from a hand-written
file and from its directory, two captures resolved through a sidecar, the match inside, on the
edges, outside and on another capture, the seeded rows newest first with the anchor's wall time,
the merge with live rows and with another capture's parts, the summary and its words, the
record config, the active job, the status words), and in `LeylineClientDaemonTests`
`testTheWindowsRecordingHoldsTheTransmissionsHeardLive`, which starts the window's record job on
`nfm_keyed.cf32`, reads the daemon's own manifest through `ResolveLocalPath`, finds the newest
live transmission inside a part, and deletes the finished recording; `make app-lint` passes.

Unverified until the first `make app-run` on a Mac, because nothing in `LeylineApp` compiles in
the container: every change in `AppSession.swift`, `InspectorView.swift`,
`InspectorGroups.swift`, `SidebarView.swift`, `TransportBarView.swift`, `LeylineApp.swift` and
`Theme.swift`. Named behaviours to check there: the header fits `Channel`, the dot, the status
and `Stop` in 280 pt (the status truncates, with the sentence as its tooltip); the degraded
detail in `caution` after a band switch; the play column's alignment with the column head and
the 2 pt line along the bottom of the playing row; the live sink detached for a clip and attached
again after it, including after a clip replaced by another and after a clip shorter than the
first poll; the recording line under the log's header and the log's row count with it; part
rows' times against the manifest's anchor; the two-line sidebar row, its running counters and the
delete alert's wording; a sidebar click tuning through the band and taking the recording's mode;
the speaker glyphs and their help; ⌘R and ⌘. in the menus, and ⌘. not caught by a text field;
Stop Listening's empty state, and a band, bookmark or recording click opening the radio again;
Reveal in Finder and Show Recordings in Finder.

Follow-ups 2026-09-24, the three departures the handoff's "Decided 2026-09-24" named. The daemon
publishes a playing playback four times a second with `position` current
(`SessionStore.playbackInterval`, the whole object each time, the tombstone unchanged), so
`ley play` follows its playback on the session's event stream and the window's progress line
reads the mirror's `playbacks`; both `GetState` polls are gone, and the fake publishes on the
same cadence. `DeleteResource` stops every playback of the recording's parts through
`StopPlayback`'s path before the directory goes (`SessionStore.stopPlaybacks(of:by:)`, and the
fake the same). `bandwidth_hz` joins a recording's frozen metadata keys, `RecordingSummary`
carries it, and a sidebar click tunes that width. `ley recordings` prints no width and its row is
left as it was, eight columns already. Verified by `RecordingJobTests`
(`testAPlayingPartIsPublishedWithItsPosition` and `testDeletingARecordingStopsItsPlayback`, which
play through a discarding sink the store takes in place of the audio device, so they run on a
host with none), `RecordingTests.testTheManifestCarriesTheFrozenResourceKeys`,
`TestPlayFollowsThePositionOnTheEventPlane`, `TestDeletingARecordingEndsItsPlay`,
`MirrorStateTests.testAPlaybacksPositionMovesInTheMirror`, `RecordingsTests` and the
daemon-backed recording case. Unverified until a Mac: `AppSession.swift`'s playback and
recording-row changes, the progress line moving from the mirror, and a clip ended by a delete
attaching the live sink again.

Revised 2026-09-24 by the owner's handoff (`../design/app-design-handoff-m3.md`, 8a and 8b, and
its "Decided 2026-09-24, read against the code"), which replaces this item's recording surfaces
under one rule: a transmission is heard, a recording is kept, and no surface offers to play what
is not on disk. Removed: the sidebar's `Recordings` section with its context menu and delete
confirmation (and `AppSession.recordings`, `sidebarRecordings`, `tune(recording:)`,
`deleteRecording`, `activeRecordJob`), the inspector header's `● Record` and running status (the
header reads `Channel` alone again), the log's rows made from a recording's parts
(`RecordingParts.merge`, `LogEntry`, `logEntries`) and its `recording since …` line, File ▸
Record Continuously and Stop Recording, and the façade's `continuous` option and
`statusWords`. Delete stays with `ley recordings delete` and the MCP tool until 8c. The IQ toast
the handoff names was never built. Added: the log's head row, `Record transmissions` and a
`.switch` toggle tinted `Theme.accentRec` (`#E5484D`, a new token; `recording` stays the clipping
red), with `Each transmission becomes a part, cut at dead air.` under it while off; the switch is
`Recordings.activeJob` on the tuned channel's frequency and mode, whoever started the job, and
holds only a click in flight (`recordSwitchOn`), so a `ley record` job shows the same. On, the
line is `Recordings.statusLine`: `Since 09:12 · 3 parts · 1.1 MB. Keeps going if you tune away.`
from the job's `created_at_ns` and the manifest, or the job's `status_detail` in `caution` while
degraded. The `now` row carries a 6 pt `accentRec` dot while the job runs and the squelch is
open. A closed row a part holds (`RecordingParts.match`, unchanged) is kept: time and length in
`ink`, ▶ in an 18 pt ring that becomes ■ while the part plays, the progress line and the held
live channel as before, and `Show in Finder` on its context menu (`ResolveLocalPath` of the part's
URI); a heard row is `inkTertiary` with no glyph. The manifest read is the running job's, else the
newest record job's on the channel that the mirror holds, re-read on each of its job events. A
bookmark row whose frequency and mode are recording has a 6 pt `accentRec` dot. `ClippedRows`
gains a second flag per slot and each slot's capture (`markKept`), set from the manifest's parts
on every read, and the shader paints the rightmost 3 device pixels of a kept row in
`accentRec` (`keptR`/`keptG`/`keptB`/`keptWidth` in both uniform layouts, the flags at buffer 3).
A band switch, the rail drag's release and a sample-rate change that would leave a running
recording outside the span ask first, with `Recordings.retuneWords` ("job_… is recording on this
radio; moving the radio would leave a gap in it.") from `Recordings.leftOut`, which finds the jobs
riding the capture by `ley`'s rule (`recordingsOn`: the job's own channel, owned by a job, with
`required_hz` its frequency), in an alert with Cancel and Move anyway; during a drag that has
left the recording the pill moves and the radio waits for the answer. File has `Record
Transmissions` (⌘R), a toggle item on the switch, and `Show Recordings in Finder`, which now
lists the store on demand.

Verified in the container: `RecordingsTests` (the record job copies the channel and is always
gated; the active job by frequency and mode, degraded included, a job or a bookmark without a
mode matching any; the status line, before a manifest, with another recording's manifest and
while degraded, and its time and size words; the jobs riding a capture, both forms; a move
inside, off the band, and narrowed off the channel's width, a job already outside, and the
question's words for one job and two), `ClippedRowsTests` (parts flag held rows on their own
capture only, a re-read replaces the bars, a reused slot starts unkept), and in
`LeylineClientDaemonTests` the recording case, which now finds the job by frequency and mode,
finds it riding the window's capture on the real daemon, asks about a move ten spans away and not
about one inside, and flags a waterfall row inside the newest transmission's part and not one
past the last part. `make app-lint` passes.

Unverified until the first `make app-run` on a Mac, because nothing in `LeylineApp` compiles in
the container: every change in `AppSession.swift`, `InspectorView.swift`, `InspectorGroups.swift`,
`SidebarView.swift`, `MainWindow.swift`, `LeylineApp.swift`, `SpectrumFeed.swift`,
`WaterfallView.swift`, `WaterfallShader.swift` and `Theme.swift`. Named behaviours to check
there: the `.switch` toggle at `.small` in the log region, its `accentRec` track when on, and
that it does not flick back while its job's event is in flight; the help and status lines
wrapping to two lines inside 280 pt and the log's row count with them; the ring glyph (▶ and ■
centred in an 18 pt circle in a 19 pt row) and the row's column alignment with the head; kept
rows white and heard rows grey; the context menu on a kept row and none on a heard row; the live
dot at the right of `now`; the bookmark dot beside the frequency; the shader compiling with the
second colour and buffer 3, and the 3 px bars at the right edge, including after a retune within
the span and after the ring is emptied by a new subscription; the alert's flow on a band click,
on a neighbour's name, on a rail drag's release (the pill parked off the radio during the drag,
Cancel putting it back and releasing the centre in flight) and on the sample-rate picker in the
device popover; File ▸ Record Transmissions' check mark and ⌘R. Moves the handoff does not list
(a click, a typed frequency or a bookmark outside the span, `Tune inside`) do not ask.

Screens 2026-09-24. The owner's exports of the handoff's screens (`tmp/recordings1.png` and
`2.png`, 8a and 8b) put chrome in every screen that the prose had filed under 8c or not drawn
(`../design/app-design-handoff-m3.md`, "The screens, read against the prose", and the bullets
this adds to its "Decided" section). Contract: `DaemonInfo.recordings_cap_bytes = 5`, the daemon's
`--recordings-cap` (`DaemonInfo` in `SessionStore.swift`, filled in `Daemon.init`), the fake
reporting leylined's 20 GiB default, and `ley state`'s first line ending `recordings 944 MB of
20 GB` when a cap is reported, the use summed from `ListRecordings` (`storeClause`,
`storeSize`); `ley mcp`'s `get_state` text leaves it out. Sidebar: a segmented `Radio |
Recordings` above BANDS (`AppSession.sidebarSource`, remembered in the defaults); Recordings
shows a search field and one row per frequency and mode from `ListResources(RECORDING)`
(`Recordings.channels`, `RecordingChannel`: the bookmark's name or the frequency in mono, `N
recordings · latest now|today|Wed`, the `accentRec` dot while one runs, running first then most
recent activity, a search over name, frequency and weekday); selecting a row covers the canvas
with `The channel page is coming; the files are in Finder.` until 8c; the store footer under both
sources (a 3 pt bar and `Recordings.storeWords`, used from the listing, the cap from the mirror's
`daemon`). `AppSession.recordings` is back, re-read on every record job change and on adoption.
Waterfall: the 5 s `TimeAxis` over the waterfall is gone for a 64 pt time gutter at the right on
`panel` with 10 s ticks (`WaterfallGutter`), the gutter column continuing beside the spectrum so
both charts keep one frequency axis; the kept bars are 3 pt `accentRec` at its left edge in a
`Canvas` (`KeptBars`), from `ClippedRows.keptRuns` over the manifest's parts, re-evaluated on each
row the feed counts. The shader's kept path (buffer 3, `keptR`…`keptWidth`) and `ClippedRows`'
kept flag and `markKept` are removed; the clipping marks stay. Transmissions: `TRANSMISSIONS` with
the day at the right (`Recordings.dayWords` through the anchor), no column head and no count, a
20 pt trailing column, and room for the switch's two-line status line. Volume: `playing GMRS
CH3`, `muted · GMRS CH3`, `playing a part · GMRS CH3 held` (`AppSession.listeningName`), the
output device in the tooltip. The bookmark's recording dot sits 6 pt left of the frequency.

Verified in the container: `DaemonTests.testGetStateCarriesTheRecordingsCap` and the cap in
`testGetStateEmptyWithDaemonInfo`; `TestState` (`recordings 0 B of 20 GB` against the fake),
`TestStateHeaderAndTables` (the clause with a cap and a use, and without either) and
`TestStoreSize`; `RecordingsTests` (grouping by frequency and mode, bookmark titles with and
without a matching mode, the sort, the subtitle's day words, the search, the footer's words and
fraction with and without a cap, the day words) and `ClippedRowsTests` (kept runs by age on the
part's capture only, moving as rows arrive); and in `LeylineClientDaemonTests` the recording case,
which now places a kept run from the daemon's own manifest, finds the recording's channel row
from the real listing, and reads a non-zero cap from the mirror. `make proto-check` shows only
the regenerated `DaemonInfo`; `make lint`, `make go-test`, `make app-lint` and `make app-e2e` pass.

Unverified until the first `make app-run` on a Mac: every change in `AppSession.swift`,
`SidebarView.swift`, `MainWindow.swift`, `WaterfallView.swift`, `WaterfallShader.swift`,
`SpectrumFeed.swift`, `InspectorGroups.swift`, `TransportBarView.swift` and `Theme.swift`. Named
behaviours: the segmented picker's look in `Theme` inks (a `.segmented` `Picker` may ignore
`.tint`); the search field and the rows at 236 pt; a row's selection and deselection, and the
sentence covering the canvas and taking its clicks while the Metal view keeps drawing
underneath; the footer's bar and line at the sidebar's foot under a long bookmark list; the
shader compiling without buffer 3; the 1 pt hairline beside the Metal view (a hosted view has
covered a line laid beside it before); the spectrum narrowed with the waterfall and the pointer's
hairline aligned across the seam; the tick labels at 10 s on a 2x and a 1x display; the kept
bars against the right rows as the waterfall scrolls, after a retune within the span and after a
new subscription empties the ring; the gutter redrawing at the row rate without slowing the
window; the Transmissions header's day beside `TRANSMISSIONS`, the rows fitting under the two-line
status line, and the 18 pt ring in the 20 pt column; the volume caption truncating at 142 pt
(`playing a part · 462.6125 MHz held` is longer than the block) and its tooltip; the bookmark dot
6 pt from the frequency. `docs/guide/using-ley.md`'s `ley state` transcript predates the
recordings clause and needs recording again on a radio.

8c landed 2026-09-24 (`../design/app-design-handoff-m3.md`, 8c, its 8c screen and the bullets
this adds to "Decided"). Façade, `RecordingPages.swift`: `RecordingGroup` (a card from the
listing's summary and, once read, the manifest: the parts' span through the anchors, their
lengths summed, the manifest's bytes, running, `ended_by`, and a `RecordingChip` per part in
part order), `Recordings.days` (today, yesterday, the day before by name, then `earlier`, the one
group that folds, past `collapseAfterDays` = 2; a running recording is today's top card),
`pageWords`, `channelWidth`, `partWords` (`Part 5 of Tuesday 14:02`, `16:11:04 · 10.0 s`, `0:03.8
of 0:10.0 · 2 overs` and the bar's fraction), `partTable` (Peak, Mean, Radio, Gain, Squelch,
Ended, Files), `endedWords`, `gainWords`, `deleteWords`, `deleteQuestion`, `deleteRefusalWords`
(the daemon's sentence), `lengthWords`, `RecordingPartRef`, `PlayQueue` and `FlowRows`. Window:
`RecordingsPage.swift` replaces the `RecordingsPagePending` sentence with the page (the 56 pt
header with the name, `462.6125 MHz · NFM 12.5 kHz · 4 recordings · 13.1 MB`, a Record
transmissions switch on the page's frequency and mode and `Tune`; day groups under
`SectionHeader`; cards on `panel` with an `accentRec` 40 % border while running; chips wrapping in
`FlowLayout`; folded cards opened by a click, `AppSession.openedRecordings`), and
`PartInspector.swift` replaces the whole panel while the Recordings source shows and a part is
selected or playing (`AppSession.inspectedPart`). Session: `pageManifests`, read through
`ResolveLocalPath` for each recording of the selected channel, re-read on each event of its job,
pruned with the listing; `selectedPartURI` (a chip's click selects and plays; another row
clears it); `playQueue` with `playAll`, advanced in `endPlayback` with the live sink held
detached between parts and cleared by a stop, a chip, a failed start or the delete;
`deleteRecording(uri:)` (`Resources.DeleteResource`, then the listing again) and
`tune(recordingChannel:)` (Radio, then the bookmark path with the newest recording's width). The
switch's click in flight is keyed by frequency and mode (`RecordSwitchClick`), so the page's
switch and the log's show one state when they name one channel; the page's switch starts the
frequency form with the daemon's auto squelch. The centre column keeps the page, with one
sentence, when every recording on the selected row has gone.

Verified in the container: `RecordingPagesTests` (a card's chips, range and counts through the
anchor, folded and open; a running card and one before its manifest; a chip without an anchor;
the day groups, their order and the fold, with a running recording three days old on top; the
header's words and width; the part's three lines, idle, playing and today; the table, running,
one stage and unmeasured; every `ended_by`; the delete line, question and refusal; the length
words; Play all's order and its clearing; a part URI taken apart; the wrap rule), and in
`LeylineClientDaemonTests` the recording case, which now has the real daemon refuse a delete
while the job runs in exactly `Recordings.deleteRefusalWords`, and builds a card, Play all's
first part, the ended word and the part's lines from the daemon's own manifest. `make app-lint`,
`swift test --filter LeylineClientTests` and `make app-e2e` pass.

Unverified until the first `make app-run` on a Mac: every change in `AppSession.swift`,
`RecordingsPage.swift`, `PartInspector.swift`, `InspectorView.swift`, `MainWindow.swift`,
`SidebarView.swift` and `Theme.swift`. Named behaviours: that `FlowLayout` compiles against the
SDK's `Layout` (isolation of its methods) and wraps the chips inside a card in a `LazyVStack`;
the page covering the canvas, the Metal view under it not drawing through or taking clicks (a
hosted view has drawn over SwiftUI before); the header at 56 pt with the name, the detail line,
the `.small` switch and the bordered Tune fitting the centre column's width; the page's switch
and the log's showing one state on the tuned channel and not flicking back in flight; the chips'
▶ and ■ glyphs, the playing chip's tint and the selected chip's `borderFocus` stroke; a folded
card opening and folding on its header, its chevron turning; Play all moving on at each
tombstone, the inspector following, the live sink not coming back between parts and coming back
after the last, a stop mid-way ending it; the part inspector replacing the whole panel and the
Channel panel coming back with nothing selected; the position bar and `0:03.8 of 0:10.0` moving
four times a second from the mirror; Delete's tooltip on the disabled button's wrapper (a
disabled button shows none of its own), the `.alert` overload with a `String` title, and the
page and selection refreshing after a delete; Show in Finder selecting the part's file; Tune
switching to Radio and tuning, with and without a radio open; the running card growing as
parts land.

Fixed 2026-09-25, three defects from the owner's first run of the recording build. **A gated
recording of a carrier that never stops wrote nothing** ("I have 2 0 s 0 B recordings now"):
the gate opened a part only on a squelch transition, and a broadcast holds the squelch open from
before the job starts, so none came and cancel finalised an empty recording. The runner now
seeds the gate from the first meter and after a coverage gap (`../design/recording.md`, "The
gate"). **A retune left the previous transmission open in the log** ("a GMRS transmission 'not
audible' and 2:48 in"): the window retunes by writing the same channel's offset, the daemon's
squelch stayed open across the new core, and `ChannelTelemetryFeed` reset its log only on a new
channel id. The daemon now closes an open squelch at every core swap and when the channel leaves
the capture (`ChannelTransmission`, `../dev/engine-internals.md`, "Squelch and meters"), and the
feed starts its `TransmissionLog` and last tone over when the channel's own offset event moves
its frequency (`ChannelFrequencyWatch`, which skips the capture's event, where the mirror briefly
holds the new centre with the old offset). `ley tune` makes a new channel per tune and was not
affected. **The channel page's Record transmissions switch did nothing**: `StartJob` answers
`RUNNING` before the radio is allocated, and a page whose channel lies outside the window's
capture is declined by the allocator's don't-disturb check (`DEVICE_BUSY`, "the app is listening
on …") after the call returned. The job's `FAILED` event was never read and the page covers the
notice strip, so the switch went back off after its three seconds with nothing said. The session
now watches every job either switch started and shows a failure as a notice
(`Recordings.failureNotice`, which tells a busy radio to tune there first), the page carries a
notice strip of its own, and the page's request is `Recordings.pageConfig`. Two daemon faults sat
behind it: the page's NaN squelch was read as "off" rather than auto, so its gate had nothing to
watch, and the auto squelch was the channel's own level plus 10 dB, above any carrier on it; a
gated recording now takes NaN as auto, and auto sits over the band's floor at the channel's width
(the meter's power less its SNR). Verified by `RecordingJobTests` (a gated `nfm_tone` cancelled
after 2 s is one part of about 2 s holding the tone, in the frequency and channel forms, and
with a NaN squelch; the `nfm_keyed` cases unchanged), `RecordingTests` (the seed and coverage
loss), `ChannelTests` (a core swap closes then reopens on a signal, closes only on a quiet one,
a coreless block closes once, and an offset write on `nfm_tone` closes and reopens through the
engine), `TransmissionsTests` (the watch), `RecordingsTests` (the page's request and the notice),
`TestGatedRecordOfACarrierHoldsOnePart` against the real daemon, and in
`LeylineClientDaemonTests` `testTheChannelPagesSwitchStartsARecordingThatRuns`, which starts a
recording from a channel row of the listing with no manifest and sees it running. Unverified
until a Mac: `AppSession.swift` (`noticeFailedRecordJobs`, the switch letting go on a failure),
`SpectrumFeed.swift` (the log starting over on a retune, the inspector's On air and time on air
with it), and `RecordingsPage.swift` (the notice strip at the page's foot, over the cards).

Fixed 2026-09-25 (second run), five items from the owner's second run of the recording build
(`../design/app-design-handoff-m3.md`, "Decided after the second run"). **One part held several
transmissions**: the window left `hang_ms` at the daemon's 5 s, so a simplex exchange of four
4 s overs was one 25 s part in the Library and one ▶ lit three of the log's four rows. Both
switches now send `hang_ms` 500 and `pre_roll_ms` 500 (`Recordings.config`, which
`pageConfig` calls), so each transmission is its own part, as the switch's line says; `ley
record` keeps the daemon's defaults. **Kept rows lost their ▶ when the switch went off and on**:
the rows were matched against one manifest, the running job's else the newest record job's, and
the new job's empty manifest replaced the old. The session's manifests are now one cache by job
id for the channel page and the tuned channel (`AppSession.manifests`), every recording on the
tuned frequency and mode is read (`Recordings.recordingIDs`, the running job first), and a row is
kept when any of them holds it (`RecordingParts.keptPartURI`); the gutter's bars take the same
parts. **Every row in the playing part showed ■**: the rows compared the playing URI only; the
session now keeps the clicked row's start sample (`playingRowStart`), cleared when the playback
ends. **Switching channel lost the transmissions**: the first fix of the day started the log over
on a retune; `ChannelTelemetryFeed` now keeps a `TransmissionLog` per frequency and mode for the
session (`TransmissionLogs`, 32 at most, the least recently tuned dropped), shows the tuned one
and folds edges into it only. The daemon's close on retune can reach the window after the retune's
event, so a log left on air takes the next close edge (several, in the order they were left),
and an open edge first drops the old transmission. **The place switch's unselected segment was
light**: `PlaceSwitch` is now `chrome` inside a 1 pt `border` stroke, the selected segment alone
on `border` in `ink`, and both Record transmissions switches are tinted `accentRec` only while
on. Verified by `RecordingsTests` (the config's gate, a match across two manifests, the tuned
channel's recording ids), `TransmissionsTests` (rows surviving a switch away and back, a mode as
its own log, the close after a switch, two quick switches, an open edge first, a new channel on a
known frequency, the bound), and in `LeylineClientDaemonTests`
`testTheWindowsRecordingHoldsTheTransmissionsHeardLive`, where the daemon's manifest carries the
window's 500 ms hang and pre-roll and a row the first recording kept still matches after a second
recording starts on the channel. Unverified until a Mac: `AppSession.swift` (the shared manifest
cache, `followTunedRecordings`, `playingRowStart`), `SpectrumFeed.swift` (the log switching on a
retune, On air and time on air following it), `InspectorGroups.swift` (■ and the progress line on
the clicked row only, the switch's conditional tint), `WaterfallView.swift` (`KeptBars` from every
recording's parts), `RecordingsPage.swift` (the page switch's tint), and `MainWindow.swift`
(`PlaceSwitch`'s grounds and stroke in the toolbar, and whether `.tint(nil)` leaves the system's
off track).

Fixed 2026-09-25 (third run), two items from the owner's third run of the recording build. **The
Record transmissions switch went grey, and clicking it restored it.** The app's log for the run
shows the switch's jobs matched throughout: the job started at 21:05:21 was found and cancelled
by the next click 0.8 s later, so neither the frequency match nor the click's hold was stuck, and
no `.disabled` depends on a click in flight (the log's switch is disabled only with nothing tuned,
the page's only while the daemon is not live). What changed in this build was the tint: the
second run's fix made both switches `.tint(on ? accentRec : nil)`
(`InspectorGroups.swift`, `RecordSwitch`; `RecordingsPage.swift`, the page's switch), so the
hosted control was re-tinted to nil in the same pass as its state flipped, and the flip itself
is drawn before the click's hold reaches the session. Both switches are now
`.tint(Theme.accentRec)` at all times, as before the second run: macOS paints the tint on the on
track only, so an off switch is the system's dark track, which is what the second run asked for.
Two guards landed with it. The match between a switch and a record job allows 1 Hz
(`Recordings.matchToleranceHz`, `Recordings.sameChannel`) and takes the mode only when the job
names one, and the click's hold moved to the façade as `RecordSwitchClick`, which the read
ignores once `holdSeconds` (3 s) have passed even if the session's expiry clock is late, so the
switch shows the job after 3 s at most. The session writes each change to what the log's switch
shows (`record: switch on (job_… running) at 462612500 Hz NFM`, `switch off, disabled (no record
job) at no tuned frequency`), every click, and every release with its reason; an expired hold
lists the active record jobs, so a job on a frequency the click did not match shows in
`tmp/leyline-app.log`. **The play buttons' tooltips were sentences**: a kept row's ▶ and ■ now
read `Play` and `Stop`, as do a part's chip on the channel page and the player's button;
the step buttons read `Previous part` and `Next part`, and Play all reads `Play all`. Verified by
`RecordingsTests` (`testTheSwitchMatchesAJobWithinOneHertz`,
`testAClickIsShownForAtMostThreeSecondsThenTheJob`). Unverified until a Mac: whether the
constant tint is what stops the grey (the container cannot draw the switch, and the grey was not
reproduced), `AppSession.swift` (the hold's release paths, `logRecordSwitch` and its lines),
`InspectorGroups.swift` and `RecordingsPage.swift` (the tint, the off track under it, the
tooltips), and `PlayerBar.swift` (the tooltips).

Fixed 2026-09-25 (markers), the owner's ask: "make sure that toggling a recording on and off
creates a transmission. treat it as a manual marker." **A recording of a carrier kept nothing in
the log.** The gate is seeded from the squelch, so over an FM station the part opened at the
switch, but the log's one transmission had begun long before and never closed, and no row lay in
the part. A record job on the tuned log's frequency and mode starting or ending now cuts the open
transmission at the feed's newest telemetry time (`TransmissionLog.mark`,
`AppSession.markRecordToggles`), whoever started the job; a squelch the meters report open with no
open edge seen is cut with nothing to close. A cut row has a 2 pt `accentRec` bar at its left.
The e2e run found the cut 20 ms before the part began, so `RecordingParts.match` lets a piece cut
by a recording's on start before that recording's first part, and one cut by its off end after
its last, when the part begins or ends inside the piece. Verified by `TransmissionsTests` (the
five `mark` tests and `testTheLogsCutTheCurrentLogOnly`), `RecordingsTests`
(`testAPieceCutByTheSwitchMatchesTheFirstAndLastPartsItOverhangs`) and `ClientDaemonTests`
(`testARecordingOverACarrierCutsTheLogAtItsToggles`, on `nfm_tone.cf32`). Unverified until a Mac:
`AppSession.swift` (`markRecordToggles` firing once per toggle, and not on a retune or a capture
move), `SpectrumFeed.swift` (`ChannelTelemetryFeed.mark`), and `InspectorGroups.swift` and
`Theme.swift` (the bar's place in the row's padding and its tooltip).

### APP-6 `[ ]` Lifecycle and the inspector (E.6)

The daemon not running (reported, with `ley daemon start` offered and, once APP-7 installs the
launchd job, started by the app); unplug and replug as the `CAPTURE_DETACHED` state transition
it already is; the layer 2 parameter inspector last.

### APP-7 `[ ]` Distribution (E.7)

`scripts/bundle-app.sh --with-daemon` is the layout; this item makes it install: the app
bootstraps `com.leyline.daemon` on its own `leylined` the way `ley daemon install` does, puts
`ley` and the decoders where a terminal finds them, and is signed with a Developer ID and
notarized (`../dev/release-checklist.md`). D3, the trademark check, gates the first public build.

## Backlog

- **The band rail's scrubber at a wide capture** (seen 2026-09-25). When the radio's sample rate
  spans more than the band (20 MSPS on GMRS, say), the rail draws the band's region over the
  whole capture and the scrubber's scale no longer matches the waterfall's: GMRS CH2 and CH3 sit
  closer together on the waterfall than on the scrubber. Which of the two should own the scale
  when the capture is wider than the band is undecided (`BandRailView.swift`, `select(band:at:)`,
  the region drag); the owner asked for it to be kept rather than guessed at.

## Open for the owner

- `[d]` **The handoff itself.** The terminal handoff was reconciled item by item against
  `cli-style.md`, and the guide stayed outside the repository. The same for the app: the tokens
  land in `Theme.swift`, the layouts in views, and the guide stays where it is unless a page of
  it is a contract the code must follow, in which case it becomes a section of `../dev/app.md`.
  The `/design-login` step authorises `DesignSync`, which pushes a component library *to* a
  Claude Design project; pulling the designs is the handoff document, as before.
- `[d]` **An icon.** An asset catalog as a package resource carries one; none exists. Wanted
  before APP-7, not before APP-2.
