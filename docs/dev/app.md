# App internals

How the Mac app is put together and what it promises, for anyone changing it. The app is a
peer client of the daemon over the same contract `ley` speaks (`AGENTS.md`, invariant 1); this
page is the contract for the Swift side of that, as `engine-internals.md` is for the daemon and
`cli-style.md` for `ley`. The plan, with what is built and what is next, is
`../plans/app.md`; the stories it answers to are V1a in `../plans/user-stories.md`.

## Module map

One SwiftPM package at `app/`, beside the engine's and never inside it:

| target | what | builds on |
|---|---|---|
| `LeylineClient` | the client façade: identity, the connection, the state mirror, the write coalescer, the stream decoders, errors; the bands seed file and the bookmarks store (`Bands.swift`, `Bookmarks.swift`); the folds over rows that `ley` already applies (`SpectrumFold.swift`: median floor, the peak rule, the auto squelch, max hold); the named failure states and the hold on them (`FailureState.swift`), and which waterfall rows were captured while the radio clipped and which a recording's parts hold (`ClippedRows.swift`); the transmissions log, one per frequency for the session, and the sample clock (`Transmissions.swift`, `SampleClock.swift`); the audio ladder's bands, scale and ballistics (`AudioLevels.swift`); recordings: the manifest reader, the part-to-transmission match, the window's `RecordConfig`, the switch's job and status line, the question before a move off a recording, a listing's summary, the Library's channel rows and search, the store footer's words and the day words (`Recordings.swift`); the channel page's cards, day groups and chips, the inspector's words for a part, the player's words and its previous and next part, the delete words and Play all's queue (`RecordingPages.swift`) | macOS and Linux |
| `LeylineApp` | the SwiftUI app: `AppSession` (the mirror copied, the selection, every action), the feeds (`SpectrumFeed`; `ChannelTelemetryFeed`, the tuned channel's meter, squelch edges and tones; `CaptureLevelFeed`, the radio's clipping count; `AudioLevelsFeed`, the tuned channel's audio spectrum in octave bands), the M1 views (sidebar, band rail, spectrum, the Metal waterfall with its shader as source, the mouse both charts share in `ChartMouse.swift`, transport bar, device menu), the M2 inspector (`InspectorView.swift`, `InspectorGroups.swift`, `AudioLevelsView.swift`), recording from the window (the log's Record transmissions switch and kept rows, the bookmark dot, the waterfall's time gutter and kept bars, the volume caption, the retune question, the File items; APP-5), the window's two places (`MainWindow.swift`: the toolbar's `Radio \| Library` switch and the two bodies; the Library in `LibraryView.swift`, its sidebar, store footer and inspector, with the channel page in `RecordingsPage.swift`, the inspector on a part in `PartInspector.swift` and the player in `PlayerBar.swift`; APP-5b), `Theme.swift` | macOS only; the manifest declares it under `#if os(macOS)` |
| `LeylineClientTests` | the façade's rules without a daemon: the fold, the coalescer, the decoders, the bands and bookmarks files, the spectrum folds, the transmissions log and the clock, the audio bands and their ballistics, a hand-written recording manifest, the part match, the switch's job and status line and the retune question, the channel page's cards and day groups, a part's words and table, and Play all's order | both |
| `LeylineClientDaemonTests` | the façade against a real `leylined --no-hardware` playing a fixture | both; skips itself without `LEYLINED_BIN` |

The package depends on the generated contract (`.package(path: "../swift/LeylineProto")`) and on
the same grpc-swift and swift-protobuf versions the engine pins; it does not depend on the engine
package at all. It never imports `EngineCore`, `CRTLSDR` or `LeylineDaemon`: the app is a separate
Apache-2.0 work beside the GPL daemon (`../decisions/D2-licensing.md`), and `make license-check` refuses
the import. DSP stays in the daemon (invariant 2); the app decodes bytes into pixels and nothing
more.

Why a package and not an Xcode project: `swift build` is the one build both CI hosts and the
container already run, a manifest diffs and merges, and Xcode opens `app/Package.swift` directly
(previews included). What a bundle needs beyond an executable, `scripts/bundle-app.sh` lays out.

## The façade

`LeylineClient` is the Swift counterpart of `go/pkg/leyline`: the same wire rules, so a feature
that works from the app works from `ley`, and the other way round.

**Identity** (`ClientIdentity`). Every RPC carries `leyline-client-id`, `-kind` and `-label`,
added by an interceptor on the connection. The id is an `app_` ULID minted once per process
(`ClientIdentity.process`), so the window and its coalescer are one client to the daemon and
`ley state` shows one row for the app. Tests mint their own with `.fresh(kind:label:)`.

**Connection** (`DaemonConnection`). One gRPC client over the Unix socket (`SocketPath.default()`:
`LEYLINE_SOCKET`, else the platform path the daemon uses), lazy like the Go client: nothing
connects until the first RPC, and a socket with no listener fails that RPC with `UNAVAILABLE`,
which maps to `LeylineError.daemonUnreachable`. The six typed service clients are properties;
`state()` is a sorted daemon-scoped `GetState`; `events(sinceSeq:)` and `telemetry(_:)` are
server streams as `AsyncThrowingStream`s. Ending the consumer cancels the RPC. Holding
`events()` open is what keeps the client's non-persistent channels alive (5 s grace after the
last open stream ends, `engine-internals.md`, "Client identity and ownership").

**Errors** (`LeylineError`). The daemon's `ErrorDetail` from the `leyline-error-bin` trailer:
`code` is the stable string from the "Error codes" table, `message` the daemon's sentence,
`target` the id it concerns. A call that never reached the daemon gets its status's name
(`UNAVAILABLE`, `CANCELED`), the same spellings as the Go library. Every façade call maps to it;
the generated clients throw `RPCError`, and `LeylineError(error)` converts either.

**The mirror** (`DaemonMirror`, `MirrorState`). `run()` takes a snapshot, subscribes with
`since_seq` set to the snapshot's `event_seq` and folds every event; on any failure it reports
`connection = .unavailable(error, retryIn:)` and retries after a backoff that stops at 5 s, so
a daemon that is not running is polled, not hammered, and the view has a state to show. The
fold is `ley`'s (`go/internal/session/session.go`): replace by id, because every event carries the
whole object (invariant 6); an object whose `state` is unset is the tombstone and leaves the
mirror; `CAPTURE_DETACHED` stays, because the radio rebinds on replug; a device is never
removed, only `DISCONNECTED`; a job is never removed, it finishes; an event at or below the
held `seq` is skipped, except a `WriteRejected`, which no snapshot could have carried. A `seq`
gap means the snapshot fell out of the daemon's 256-event window, and the mirror takes another
snapshot without leaving the stream (`snapshots` counts them, so a test can check that a resync
happened). `MirrorState` is a value with no daemon in it, and that is where the rules are tested.
The class is `@MainActor` because control events are a few a second, the mirror exists to be
rendered, and one actor means no hop per event. It imports no UI framework; `onChange` fires
after every change and the app's `@Observable` `AppSession` copies `state` and `connection` out
of it, so views hold one render's value and the façade serves AppKit, SwiftUI and the Linux tests
alike (Linux's Observation library does not link into a test bundle, which is how this rule was
found). Bulk rows and telemetry never pass through it.

**The coalescer** (`WriteCoalescer`, `PendingWrites`). A drag produces a frequency per frame;
the daemon keeps the last value per `(target, parameter)` every 20 ms, and so does this side:
`set` records the write and kicks a flush one tick (16 ms) later, so a frame's worth of writes
is one message and an idle coalescer sleeps on the kick, not a timer. Writes are fire-and-forget
inside one `WriteParams` stream (`../design/control-plane.md`, "Parameter writes"); the
confirmation is the state event the mirror folds, and a refusal is a `WriteRejected` event
carrying the write's tag, which `set` returned. A view previews its own write and reconciles
on the event; it never treats the write as done.

**Streams** (`Streams.swift`). `subscribe(_:)` is `Bulk.Subscribe` then `Bulk.Stream`;
`fft(capture:bins:rowsPerSecond:)` is the FFT of a band decoded to dBFS per bin against the
descriptor the daemon *answered* (the daemon may not grant what was requested, and DB_U8 decoded
as DB_F32 does not look obviously wrong). `fft(channel:tap:bins:rowsPerSecond:)` is the same
stream with a channel as its source: the spectrum of the channel's audio on the tap named, from
0 Hz to half the audio rate, DB_F32 by default because its bins are summed into bands
(`../design/audio-meters.md`, "The stream"). The client-side buffer keeps the newest few
frames, which is the plane's own latest-wins policy: a renderer that falls behind skips to the
newest frame. `BulkDecode`
holds the payload rules (`DB_U8` is `round((dB + 120) · 2)`; floats are little-endian; S16
divides by 32768) and they match `go/pkg/leyline/bulk.go` bit for bit, tested on both sides.
The shm ring is not built: the app draws over gRPC first and S1 decides
(`../plans/build-order.md`, "Closing the core").

**Transmissions and the clock** (`Transmissions.swift`, `SampleClock.swift`). `TransmissionLog`
is one channel's last fifty transmissions, newest first, folded from the telemetry plane's
squelch edges and nothing else: the daemon summarises a transmission on the close edge of a
`SquelchTransition` (`duration_samples` in *capture* samples, the peak SNR and audio level), so
the log times nothing itself and a client that subscribes mid-transmission still logs the one it
joined, its start read back from the close edge the way `ley mcp`'s `listen` does. The rules are
`ley tune`'s (`go/internal/cli/transmission.go`, `subaudible.go`): a close edge with no duration,
or one under a quarter second (a squelch near the floor opening on noise), is ignored, the CTCSS tone or DCS code reported while a transmission ran stays with it (`SubAudibleTone`, printed ` · PL 100.0` or ` · DCS 023`; a later report of the other kind replaces it), the 1 Hz heartbeat
that repeats a tone is not a new one, and a measurement between two standard tones is not reported
as a tone. `onAir` is the open transmission and `timeOnAir(at:)` its length at a `SampleTime`, so the
view asks with the newest time it has rather than a clock of its own. `TransmissionLogs` keeps
one such log per frequency and mode for the window's session, 32 at most with the least recently
tuned dropped, so a retune switches to the new frequency's log and coming back finds the rows
heard there; edges fold into the current log only, and a log left while its transmission was
open takes the next close edge, which is the daemon's close on retune arriving after the
retune's event (an open edge first drops the old transmission instead). Until the owner's second
run on 2026-09-25 a retune emptied the one log. A record job on the tuned log's frequency and mode
starting or ending is a manual marker (`mark`, `Transmission.startMarker` and `endMarker`): the
open transmission closes there, with its tone and the peaks its meters reached, and a new one
opens at the same sample with no tone yet, because the squelch is still open. A continuous carrier
(an FM station) holds the squelch open for as long as it is on the air, so without the cut its
one transmission began before the recording and never ended, no part held it, and nothing got ▶.
A squelch the meters report open with no open edge seen (a carrier on air before the log was
listening, a channel with its squelch off) is cut too, with nothing to close; a closed squelch has
nothing to cut, and a piece under a quarter second is dropped like any opening. The session cuts
from the job's state, not the click, so `ley record` from a terminal cuts the log as well
(`AppSession.markRecordToggles`), at the feed's newest telemetry time. That time is when the job's
event arrived, not the sample the gate opened at: over `nfm_tone.cf32` the cut came 20 ms before
the recording's first part began, so `RecordingParts.match` lets a piece that began at a
recording-on cut start before the recording's first part when that part begins inside it, and one
that ended at a recording-off cut end after the last part when that part ends inside it. A cut row
has a 2 pt `accentRec` bar at its left edge. `SampleClock` is the Swift
mirror of `leyline.AnchorWallTime` and `RecordWallTime`: a `SampleTime` becomes a `Date` through
a dated `CaptureAnchor` on the same capture that applies from a sample not past it, drift
applied as the anchor states it, and nil otherwise (a capture's anchor has host time 0 until its
first block), because without an anchor the daemon has no wall-clock time to give (invariant 5). The
mirror keeps each capture's newest anchor on the capture, and the daemon-backed tests fold
`nfm_keyed.cf32` into transmissions as long as the fixture keyed them and cut `nfm_tone.cf32`'s
carrier at a recording's on and off into a row its part holds.

**Failure states** (`FailureState.swift`). Problems the radio's numbers show, stated in words
rather than left as a dark waterfall (`../plans/user-stories.md`, V1a): the radio clipping, read from
the daemon's `CaptureLevel` (samples at the converter's rails, one in ten thousand raises it, half
that clears it; `CaptureLevelFeed` subscribes it per capture), with the gain as the suggested fix
(on auto, take it by hand; above the lowest, lower it, naming the stages above their lowest on a
radio with several, "Lower the LNA or VGA gain."; at the lowest, move the antenna). "The lowest"
means every continuous or table stage set by hand to its lowest; a two-value stage, the HackRF's
AMP, does not count (`../plans/app.md`, M2-10). A measured fact
with its number and one action; not a detector (invariant 12). `ley tune` reports the same state
from the same count and words (`go/internal/cli/failure.go`), held by the same rule
(`cliphold.go`) and said once when raised, and also warns once, in its banner at tune, when
nothing on the band is 15 dB above the floor. The window showed that warning too until 2026-09-21. It
was removed because repeating it every few seconds on a quiet band distracted more than it helped.
The daemon
not running, no radio and an unplugged radio are the mirror's states and live in
`AppSession.emptyWords`. The session folds every level reading, and every mirror change for the
gains, through `FailureHold`: clipping is raised after 1 s at or over the floor and cleared after
2 s under the exit fraction, on the capture's clock, because clipping comes in bursts of half a
second to two seconds and each burst used to show and clear the words. Each change is logged
after the hold. Clipping is drawn in three places and written in none (`../plans/app.md`, M2-8).
While the state holds, the toolbar's device chip has a `caution` dot with the headline and detail
as its tooltip, and the gain slider's knob is `recording`. The waterfall marks every row captured
during a reading at or over the floor, the raw reading rather than the held state, with 2 px of
`recording` at its left edge: readings arrive after the rows they cover, so
`WaterfallBuffer` keeps each row's sample index in `ClippedRows` and the reading flags the held
rows inside its interval, and the shader reads the flags as one byte per ring slot. A channel the capture no longer covers (`OUT_OF_CAPTURE`: another client narrowed or
moved the capture) is a `caution` line under the frequency in the inspector's identity, with the
width and centre the radio is capturing and a `Tune inside` button, which moves the centre the
way `AppSession.setSampleRate` places it (the channel keeps its absolute frequency, so only the
centre is written). It shows only once the mirror has reported the state for 1 s, because the
window's own retune writes the centre before the offset and the channel event between the two
reads out of capture for about 90 ms. Neither has a close control: each goes when its cause
clears. The window's own rate change never causes out of capture, because `setSampleRate`
re-places the centre for the tuned frequency at the new width and writes centre and rate in one
tick.

**The inspector** (`InspectorView.swift`, `InspectorGroups.swift`). The panel on the window's
right describes the tuned signal in words, and every word is a presentation of a number the
daemon measured: signal from `AppSession.overNoiseDB` through `SignalWord`, tuning and deviation
from the meter's `freq_error_hz` and `deviation_hz` through `TuningWord` and `DeviationWord`
(`Reading.swift`, where the thresholds live and are tested), time on air and the log of recent
transmissions from `ChannelTelemetryFeed`, which subscribes one channel's meter, squelch edges
and sub-audible reports and folds the last two into the tuned frequency's `TransmissionLog` in the
façade's `TransmissionLogs`, switching logs when `ChannelFrequencyWatch` reads a new frequency or
the channel's mode changes. The number is one click away
under each word, and a row whose measurement is NaN is hidden rather than dashed. Wall clock in
the log comes through `SampleClock` from the capture's anchor and is relative otherwise. The panel
keeps no state of its own; its one write is a bookmark's name, through `BookmarkStore`. The
failure strip read here from M2-3 until M2-6 retired it, and the transport bar's signal readout
left when the panel arrived, the one exception to the rule that no milestone moves a control an
earlier one introduced.

**Recording** (`Recordings.swift`; `AppSession`'s "Recording" and "Moving the radio over a
recording" sections). A recording is a record job's output
(`../design/recording.md`), and one rule decides every surface: a transmission is heard, a
recording is kept, and nothing offers to play what is not on disk. The log's head row is the
Record transmissions switch. On starts `Jobs.StartJob` in the frequency form of `RecordConfig`,
gated by squelch, with the tuned channel's frequency, mode, width and squelch copied
(`Recordings.config`) and a hang and pre-roll of 500 ms each (`windowHangMs`, `windowPreRollMs`),
so each transmission is its own part: the daemon's default 5 s hang folded a simplex exchange of
four overs into one part on the owner's second run (2026-09-25), and `ley record` keeps that
default; off is `CancelJob`; the job owns its channel and outlives the window. The
switch shows `Recordings.activeJob`, the running or degraded record job on the tuned channel's
frequency and mode in the mirror's `jobs`, whoever started it, and keeps only a click until that
job's event arrives (`recordSwitchOn`); File ▸ Record Transmissions (⌘R) is the same switch.
Its track is tinted `accentRec` only while it is on; off it has no tint, the system's own dark
track.
While it is on, the line under it is `Recordings.statusLine` (`Since 09:12 · 3 parts · 1.1 MB.
Keeps going if you tune away.`, from the job's `created_at_ns` and the manifest), or the job's
`status_detail` in `caution` while it is degraded. The store is read, not mirrored: a manifest
is `recording.json` read through `ResolveLocalPath`, because the window is local as `ley
recordings show` is, into one cache by job id (`AppSession.manifests`) that the channel page
shares. For the tuned channel every recording on its frequency and mode is read
(`Recordings.recordingIDs`: the running job first, then the listing, newest first), each once
and again on each of its job's events. The log's rows are the live transmissions only and never
back-fill from a recording. A closed row whose transmission lies inside a part of any of those
recordings (same capture, the part's start at or before the transmission's start, its end at or
before the part's end, with the allowance for a piece a recording's switch cut described under
"Transmissions and the clock"; `RecordingParts.match` and `keptPartURI`) is kept, so a row an earlier
recording kept keeps its ▶ after the switch goes off and on: its time and length in `ink`, ▶ in
a ring that plays the part through `Control.StartPlayback` while the live sink is detached, the
progress line from the mirror's `playbacks` (the daemon publishes a playing playback four times a
second), and Show in Finder on its context menu. ■ and the progress line are on the clicked row
only (`playingRowStart`, its start sample, cleared when the playback ends), since rows a short
gap apart share a part. A heard row is `inkTertiary` with no glyph. The
`now` row has an `accentRec` dot while the job runs and the squelch is open, a bookmark whose
frequency and mode are recording has one 6 pt left of its frequency in the sidebar. The
waterfall's time gutter (`WaterfallGutter`, 64 pt on `panel` at the right of both charts, so the
spectrum narrows with the waterfall and they keep one frequency axis) prints `now` and a tick
every 10 s, and draws 3 pt `accentRec` bars at its left edge against the rows a part holds:
`ClippedRows.keptRuns` walks the ring's own sample indices for the parts on each row's capture and
returns runs of row age, one device pixel a row, re-evaluated on each row the feed counts
(`KeptBars`). The shader draws only the clipping marks. A band switch, the rail drag's release and a sample-rate change that would leave a
running recording outside the span ask first with `Recordings.retuneWords`, `ley tune`'s
sentence, for the jobs `Recordings.leftOut` finds riding the capture by `ley`'s rule; tuning
inside the span never asks, and the daemon records the gap if the move goes ahead. The transport
bar's button is the mute (`toggleMute`, the sink detached), and the caption under the volume
slider says what is heard (`playing GMRS CH3`, `muted · GMRS CH3`, `playing a part · GMRS CH3
held`) with the output device as its tooltip. File ▸ Show Recordings in Finder opens the store.
Tune ▸ Stop Listening removes the channel and destroys the capture only when this window made it
and no other channel rides on it. The window was written in the container and is unverified until
it runs on a Mac (`../plans/app.md`, APP-5); the façade's rules are tested in `RecordingsTests` and
`ClippedRowsTests`, and against the daemon's own manifest by the daemon-backed suite.

**Two places: the Radio and the Library** (`MainWindow.swift`, `LibraryView.swift`,
`PlayerBar.swift`; decided 2026-09-25). The toolbar's leading edge has a `Radio | Library`
switch (`PlaceSwitch`, two plain buttons on the toolbar's `chrome` inside a 1 pt `border`
stroke, styled as a segmented control: the place showing raised on a `border` ground 2 pt inside
the stroke in `ink`, the other on none in `inkTertiary`; View ▸ Radio ⌘1 and Library ⌘2), which
sets `AppSession.place`, remembered in the defaults. `MainWindow` switches its whole body under
the toolbar on it: `RadioBody` is the window above, with the sidebar holding only bands and
bookmarks, and `LibraryBody` is what has been kept. The radio runs the same in both, because the
capture, the channel, the sink and the feeds are the session's; the Radio's Metal view is made again
on the way back and draws the feed's rows, and the audio ladder unsubscribes while the Library
shows. The Library's sidebar (`LibrarySidebar`, 236 pt) is a search field, one row per frequency
with no section header (`Recordings.channels` over `AppSession.recordings`, the
`ListResources(RECORDING)` listing re-read on every record job change and on adoption; a mode or
width change does not split a channel, and the row takes the newest recording's mode), titled by the
matching bookmark or the frequency, running rows first and then by most recent activity, and the
store footer, which draws the used fraction of the daemon's cap (`DaemonInfo.recordings_cap_bytes`)
and `3.3 GB of 20 GB · oldest go first` (`Recordings.storeWords`). With nothing kept its body is
one sentence. The first row is selected on arrival and whenever the listing arrives with none
selected, and a click on a row always selects it, so the centre is never blank. The centre is
that channel's page (`RecordingsPage`): a header with a Record transmissions switch on the
page's frequency and mode (one job state with the log's switch, the click in flight keyed by
frequency and mode) and Tune, which goes to the Radio by the bookmark path; then the parts as
rows by the day each started (`Recordings.dayRows`): `today`, `yesterday` and the day before by
name, each with its head, `Play day` (the day oldest first, through `PlayQueue.start(parts:)`) and
a 24-hour strip (`DayStrip`, a `Canvas`), then `EARLIER` with one line a day that opens in place
(`AppSession.openedDays`). A row (`PartRowView`) is the ring, the gutter's bracket for a
recording of several parts, the start, the length, a level graph (`LevelBars` over
`LevelGraph.columns`, the part's WAV read once off the main actor through `ResolveLocalPath`
and cached in `AppSession.levelGraphs`), the peak (`accentRec` when `clipped_ms` > 0) and the
size (`PartRow.words`). The rows come from each recording's manifest, read through
`ResolveLocalPath` into the session's `manifests` and read again on each of its job's events; a
recording with no parts, or no manifest read yet, has no row. A row's click selects the part and
plays it by the log's playback path, and on the playing row pauses or resumes it
(`AppSession.clickRow`, `pausePlayback`, `Control.SetPlaybackPaused`; `isPaused` is the mirror's
`Playback.paused`); Play all and Play day queue parts and start each on the tombstone of the one
before (`PlayQueue`), with the live sink held detached until the last ends. The page has no
notice line of its own: a refusal made there is the session's notice, which the Radio shows. The
inspector (`LibraryInspector`) is the part selected or playing (`PartInspector`, its words from
`Recordings.partInspectorWords`: the part's place, time, Peak, Mean, Overs and the clipped
sentence; the recording's Span, Ended, Radio, Gain, Squelch and Files with `Play all 4`; Show in
Finder, and Delete recording…, `Resources.DeleteResource` on the whole recording, disabled with
the daemon's refusal while its job runs), else the channel's lines (`ChannelSummary`: name,
frequency and mode, recordings and size, Show in Finder for the newest recording). The player
(`PlayerBar`) takes the transport bar's place: ⏮, the circle and ⏭. The circle pauses and
resumes the window's playback while one exists and otherwise plays `AppSession.player` (the part
playing, else the selected one, else the page's first row); ⏮ and ⏭ move within that recording
(`Recordings.neighbourPart`, disabled at the ends; while a part plays the neighbour starts, and a
Play all walks on from it through `PlayQueue.start(_:at:)`); the two lines (`GMRS CH3 · Today`,
`14:03:20 · part 4 of 4`) and the track's ends are `Recordings.playerWords`, and the volume
caption reads `GMRS CH3 · live` between parts and `live radio held while this plays` while one
plays or is paused. The Library menu puts Play, Pause or Resume on space, Previous/Next Part on ←
and →, and Stop with no key; the Tune menu's bare arrows and space are disabled in the Library,
both menus act through `pressSpace`/`pressArrow` for the place showing, and a text field being
typed into gets the key back (`TextFieldKeys`). Unverified until the Mac (`../plans/app.md`,
APP-5b and APP-5c); the façade's rules are tested in `RecordingPagesTests` and against the
daemon's manifest in the daemon-backed suite.

**The audio ladder** (`AudioLevelsView.swift`, `AudioLevelsFeed`). Between the reading and the
log, the panel draws the meter `ley levels --watch` draws:
the demod tap's spectrum at 1024 bins and 20 rows a second, one subscription per channel and only
while the panel is shown, summed into nine octave bands by the façade's `BandLevels` and moved by
`LevelBar`'s ballistics on the capture's sample clock. Its rms and peak are the meter's
`audio_dbfs` and `audio_peak_dbfs`, and a closed squelch leaves every bar unlit, because the
demod tap carries the discriminator's noise between transmissions. The view was written in the
container and is unverified until it runs on a Mac (`../plans/app.md`, M2-7).

## Palette and type

Every value below is in `Theme.swift`, under the names given here, and a view uses no colour or
font that is not one of them.

### Palette

| token | value | used for |
|---|---|---|
| `ground` | `#0B0D0F` | the window's ground, spectrum and waterfall backing |
| `chrome` | `#17191C` | titlebar and transport bar |
| `panel` | `#101315` | the sidebar |
| `panelHeader` | `#0E1113` | the band rail, and any strip that labels a panel |
| `raised` | `#14181B` | a control's ground inside the chrome; a selected row's ground |
| `selected` | `#1A1E21` | a selected sidebar row |
| `hairline` | `#1C2125` | a divider inside a panel |
| `border` | `#23282C` | a divider between regions, a control's edge; a pop-up's ground inside the chrome (2026-09-19) |
| `borderStrong` | `#2A3034` | a control that accepts a drag; a popover's ground edge |
| `borderFocus` | `#3A4044` | the tuning field, an open popover |
| `ink` | `#E7E9EA` | primary text, the tuned frequency |
| `inkSecondary` | `#C5CACD` | a row's label |
| `inkTertiary` | `#9BA1A6` | a value beside a label, a descriptive clause |
| `inkMuted` | `#7A8185` | a unit, a subtitle |
| `inkFaint` | `#6B7276` | a section header |
| `inkFaintest` | `#5F656A` | a footnote under a control |
| `inkDisabled` | `#4A5054` | the sub-kHz digits of the tuning field |
| `accent` | `#E8814A` | the tuned channel, and nothing else |
| `good` | `#2FB6A3` | squelch open, a connected device, a bookmarked frequency |
| `caution` | `#C9C06A` | off tune, overdeviating, the radio clipping, a channel outside the capture; the ramp's fourth stop (2026-09-20) |
| `recording` | `#B8483C` | the radio clipping: the waterfall's clipped-row marks, the gain slider's knob (M2-8) |
| `accentRec` | `#E5484D` | what is being kept: the Record transmissions switch, the live row's dot, a recording bookmark's dot, the time gutter's kept bars (2026-09-24) |

`recording` and `accentRec` are never on one element, so red on a control always means kept and
red on the waterfall's edge always means clipped.

The level ramp keeps the terminal's hue order (`cli-style.md`, "3a. The level ramp") and runs
cold to hot for the app's dark ground, six stops from near-black to cream:

```
#10262B  #14555A  #2FB6A3  #C9C06A  #E8814A  #F6E6DA
 cold end                          cold end + 40 dB
```

**The hot end is 40 dB over the cold end, fixed** (decided 2026-09-23, replacing the
2026-09-19 rule that it was the loudest level on the band, held and let go at 1 dB a second).
Every row on screen is coloured with the current ramp on every frame, so a hot end that moved
recoloured the whole history: a transmission already drawn dimmed when something louder keyed
up anywhere in the capture, off screen included, and brightened again as the peak decayed after
it. With a fixed reach a row keeps its colour while it scrolls, and only a squelch change
recolours it. Six stops over 40 dB is about 8 dB a stop; anything 40 dB over the cold end is
cream. The cost is that a weak band no longer stretches to reach the last stop.

**The ramp's cold end is the squelch** (decided 2026-09-19): the channel's threshold converted
to a level per bin (`squelch − 10·log10(bandwidth / bin width)`, the auto squelch's scaling in
reverse), so dragging the marker up darkens the noise and only signals above the squelch have
colour. Under the squelch the waterfall fades from the first stop to `ground` over 6 dB and
stays there (decided 2026-09-19): bins below the squelch go almost black, a clip rather than a
rescaled ramp, so the scale above the squelch is unchanged. With the squelch off, or before a
floor is known, the cold end is the floor plus 6 dB (`SpectrumFeed.noiseHeadroomDB`): noise
spreads a few dB either side of the median, and with the cold end on the median half of it had
colour and the picture was a teal haze. The floor is held (`HeldFloor`): it falls as soon as the
smoothed median is 4 dB under it, rises only after the median has stayed 4 dB over it for 5 s on
the capture's clock (decided 2026-09-23), and is re-taken at once after a retune or a gain
change. The rise waits because a keyed handheld that clips the radio lifts the whole band's
median with overload spurs for as long as it transmits, and a floor that followed it recoloured
every row on screen at each press of PTT.

`accent` and the ramp's fifth stop are the same orange, so the tuned channel matches the top of
the ramp. As a result **nothing else in the window may use orange**, or the tuned channel becomes
hard to find. Check on a real waterfall that a strong signal inside the tuned band is still
visibly inside it before treating the value as final; if the fill does not show it, the band's
1 pt edges must.

### Type

SF for the interface and SF Mono for anything a person compares digit by digit. **No font is
bundled**: Space Mono and Space Grotesk are not on macOS, and bundling a font for one small role
costs a package resource and a licence entry, so section headers are SF Mono and the channel's
name is SF, each at the size and tracking the role calls for.

| role | token | face | size | notes |
|---|---|---|---|---|
| tuned frequency | `frequency` | SF Mono | 29 | tabular figures, `-0.02em` tracking |
| the channel's name in the inspector | `name` | SF | 21 medium | `-0.015em` tracking (2026-09-20) |
| signal readout | | SF Mono | 21 | tabular |
| body, control labels | `body`, `label` | SF | 12.5–13 | |
| a value beside a label | `value`, `valueSmall` | SF Mono | 10.5–11.5 | tabular wherever it changes |
| section header | `section` | SF Mono | 9.5 | uppercase, `0.14em` tracking (was `0.16em`; a step down, 2026-09-19) |
| a table's column head | `columnHead` | SF Mono | 8.5 | the inspector's log (2026-09-20) |
| a clause under a sentence | `aside` | SF | 11.5 | (2026-09-20) |
| footnote under a control | `footnote` | SF | 10.5 | |

Every number that changes while you watch it uses tabular figures, without exception, so a
frequency does not change width while tuning.

## Brand

The mark and the splash are the owner's SVGs in `../design/brand/`, drawn in code rather than
loaded, so they take `Theme`'s colours at any size (`../plans/app.md`, APP-8). `BrandMark` is the
ring and dot at a `size` in `accent`, its ring's outer edge on the box; the toolbar's first leading
item is the 13 pt mark and `Leyline` in `label`, and the window's title is removed from the toolbar
with `.toolbar(removing: .title)` so the word is drawn once while the Window menu still lists the
window as Leyline. The first window of a launch opens under `SplashView`, whose clock is
`MainWindow.playSplash`: the 26 pt mark, `leyline` and `SOFTWARE DEFINED RADIO` fade in over
`Motion.splashFadeIn` (0.4 s); the splash holds until the daemon is live, at least `splashMinHold`
(1.2 s) from its first frame and at most `splashMaxHold` (2 s); then, over `splashExit` (0.7 s,
ease-in-out), the words fade, a ring grows from the mark to the window's diagonal while its line
thins to nothing, the mark flies to the toolbar's and shrinks to its size, the toolbar's items fade
in, and the splash's ground is swept away from the top down. The flight is an offset and a scale
measured in the window's coordinates (`WindowFrameProbe`), not a `matchedGeometryEffect`, because a
toolbar item is hosted outside the content's view tree; the toolbar's ground is hidden while the
splash shows so the mark can reach it. With Reduce Motion on, the exit is a `splashReducedFade` (0.3
s) cross-fade. Every size is a `Layout.splash*` or `brand*` token read off the SVGs. The icon is
drawn by `scripts/render-icon.swift` at bundle time (the mark on `ground` in the macOS icon tile, 16
to 1024 px, then `iconutil`), and `bundle-app.sh` puts `AppIcon.icns` in `Contents/Resources`, which
`Info.plist` names as `CFBundleIconFile`; `make app-run` runs no bundle and shows the generic icon.

## Building and running

On the Mac (Xcode 26, the same as the engine):

```sh
make app          # swift build in app/: the façade and the app
make app-run      # the window, straight from the package: no bundle, no signature
make app-bundle   # app/dist/Leyline.app, ad-hoc signed; --with-daemon via BUNDLE_ARGS
open app/Package.swift   # or: Xcode, with previews; Product > Run runs LeylineApp
```

`make app-run` runs the bare executable, which SwiftUI accepts (a window, the menu bar, the
process name in the Dock). The bundle adds `Info.plist` (identifier `com.leysdr.app`, the
version from `VERSION`), resource bundles beside the binary, and a signature; with
`--with-daemon` it carries `leylined`, `ley` and the decoders under `Contents/Helpers`, which is
the shape a distributed build has (APP-7) and nothing installs yet. `CODESIGN_IDENTITY` signs
for real; notarization is `release-checklist.md`'s step.

The waterfall's shader is Swift source compiled at launch, not a `.metal` resource: APP-2 tried
the resource path and `swift build` does not produce the `default.metallib` Xcode does, so the
source lives in `WaterfallShader.swift` and a compile failure is a sentence in the window rather
than a dark panel (`swift-style.md`, "AppKit and Metal").

In the container and on Linux CI, `make app` builds the façade and `make app-test app-e2e` runs
both suites against the Linux-built daemon; the SwiftUI target does not exist there. `make app-format` runs swift-format over the package with the
configuration in `app/.swift-format` (`swift-style.md`, "Files"); run it before a commit. Anything
under `#if canImport(SwiftUI)`, `Metal` or `AppKit` is never compiled on Linux, the same trap
`setup.md` records for Accelerate: a green Linux run does not compile any view.

## Logs

The app writes one line per thing the window did (`AppLog.swift`): dialling and the daemon's
state, the capture and channel it made or adopted, every tune with the offset and any centre
move, band crossings and the mode-and-width pairs they write, every gain write, every rate change
with the centre it moved to, rejections with the write's tag, every message the window shows as it is shown (the notice, the error, the words over
the waterfall, the out-of-capture words, each under `shown`), the failure state named or cleared,
the meter's numbers every thirty seconds,
the FFT subscription's descriptor and a row count every thirty seconds, the audio ladder's
subscription, its end or failure and a row count every thirty seconds, whether the shader
compiled, the inspector shown or hidden, every bookmark added, renamed or removed, every
recording started, stopped or refused, each manifest read with its part count, the store's
listing when its count changes, and every retune question asked and answered (`record`), every clip played, stopped or ended and the live sink detached and attached around it
(`playback`), and Stop Listening with whether the radio was freed. The line goes to the file, to stderr and to the unified log under `com.leysdr.app`.
`LEYLINE_APP_LOG` names the file; the default is `~/Library/Logs/Leyline/app.log`, rotated once
to `.1` at launch past 5 MB. `make app-run` points it at `tmp/leyline-app.log` in the checkout,
which the Moat container's bind mount sees, so the log of a run on the Mac can be read from the
container with no copying. If the log cannot explain a behaviour, add a log line where it happens
rather than guessing.

## Testing

`make app-test` is the façade without a daemon: the fold's rules, the coalescer's last-value
rule, the decoders, the ULID, the error mapping. `make app-e2e` is the façade against the
product: it builds `leylined`, generates the fixtures, and `LeylineClientDaemonTests` starts a
`leylined --no-hardware` on a temp socket with `nfm_tone.cf32` attached as a looping file
device. The suite covers the app's guarantees, one test each: a second client's capture and channel
reach the mirror and its tombstone leaves it (the story "the CLI changes the tuning and the UI
reflects it"); a burst of offsets in one tick lands as one confirmed value and an out-of-capture
offset comes back as a `WriteRejected` with its tag; an FFT subscription's rows decode against
the answered descriptor with the fixture's tone in the upper half of the row; a daemon error
keeps its code; a socket with no listener is `UNAVAILABLE` and the mirror keeps trying; and on
`nfm_keyed.cf32`, the window's record job rides the window's capture, so a move off it asks and
one inside does not, writes a manifest the façade reads, whose newest part holds the newest
transmission heard live and flags the waterfall row inside it, and the finished recording
deletes.

A bare `swift test` in `app/` runs the daemon suite too and skips it silently without
`LEYLINED_BIN`, which is why the Makefile names the suites: `app-test` skips it, `app-e2e` is
the only place it runs. Same rule as `go/internal/e2e`.

A view's tests, when views have behaviour worth testing, go against the same daemon: the
harness in `Tests/LeylineClientDaemonTests/DaemonHarness.swift` is the one to reuse, and a
fixture stands in for the radio. Nothing in the app's suites may need hardware.

## Rules for new work

- **Every contract addition ships with its `ley` mirror** (`../plans/build-order.md`, Milestone
  E). A field the app reads that `ley --json` cannot show is not done.
- **The daemon is authoritative.** A view renders the mirror and previews its own writes until
  the event confirms them. No cached "my frequency" beside the daemon's.
- **Signposts on the render path from the first row.** S1 is measured antenna to pixels with
  `os_signpost` on both ends (`../plans/build-order.md`, spike S1); a waterfall without them
  cannot be measured later without being rewritten.
- **Colours and type come from `Theme.swift`** and nowhere else, so a design change is one
  file's worth of edits. The tokens and the six-stop ramp are listed under "Palette and type"
  above; `cli-style.md` shares hue order with the ramp and nothing else.
- **The band table is Go's; the app reads a generated copy.** `bands.json` under
  `LeylineClient/Resources` is `ley bands --json` checked in, `make bands-json` regenerates it
  and a Go test fails when the two drift. Never edit it by hand, and never add a band in Swift.
- **Bookmarks are a file both clients own.** `bookmarks.json` beside `labels.json`, the shape in
  `../design/channels.md`, "Bands and bookmarks are files": `{name, hz, mode, bandwidth_hz,
  updated_ns}` per entry, plus `tone`, `note`, `tags`, `offset_hz` and `duplex` on the entries
  that have them, and any key a client does not know kept as it was read. The app and `ley
  bookmarks` read and write the same file, a bookmark that only one of them can see is a bug, and a
  tone is validated by the same rule in both (`leyline.ParseTone`, `Tone.parse`), refused with the
  same sentence.
- **Prose in the window follows `../writing-guide.md`**: the daemon, a radio, a capture, a
  channel; "the daemon is not running" and what to type, never a spinner with no words.
