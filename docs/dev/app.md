# App internals

How the Mac app is structured and tested, for anyone changing it. The app is a
peer client of the daemon over the same contract `ley` speaks (`AGENTS.md`, invariant 1); this
page is the contract for the Swift side of that, as `engine-internals.md` is for the daemon and
`cli-style.md` for `ley`. The plan, with what is built and what is next, is
`../plans/app.md`; user-level acceptance criteria are in `../plans/user-stories.md`.

## Module map

One SwiftPM package at `app/`, beside the engine's and never inside it:

| target | what | builds on |
|---|---|---|
| `LeylineClient` | the client façade: identity, the connection, the state mirror, the write coalescer, the stream decoders, errors; the session's state machines, which hold no I/O so the Linux tests reach them (`HeldObject.swift`: the window's capture and channel until the mirror carries them; `RetuneQueue.swift`: one centre move at a time; `PartPlayback.swift`: the window's playback of a recorded part and Play all's queue); the bands seed file and the bookmarks store (`Bands.swift`, `Bookmarks.swift`); the folds over rows that `ley` already applies (`SpectrumFold.swift`: median floor, the peak rule, the auto squelch, max hold); the named failure states and the hold on them (`FailureState.swift`), and which waterfall rows were captured while the radio clipped and which a recording's parts hold (`ClippedRows.swift`); the transmissions log, one per frequency for the session, and the sample clock (`Transmissions.swift`, `SampleClock.swift`); the audio ladder's bands, scale and ballistics (`AudioLevels.swift`); recordings: the manifest reader, the part-to-transmission match, the window's `RecordConfig`, the switch's job and status line, the question before a move off a recording, a listing's summary, the Library's channel rows and search, the store footer's words and the day words (`Recordings.swift`); the channel page's cards, day groups and chips, the inspector's words for a part, the player's words and its previous and next part, the delete words and Play all's queue (`RecordingPages.swift`); a staged run's stage file and regions file (`ShotStage.swift`); the daemon's launch agent as the app owns it, which holds the decisions without ServiceManagement: what to do per `SMAppService` status, the Login Items words, and whether the daemon runs the bundle's build after an update (`DaemonAgent.swift`); the CLI link's path checks and restricted install command (`CommandLineTool.swift`); when the updater starts (`AppUpdates.swift`); Settings, AI as words: the key rows, the feature rows with what each choice sends to which host, the usage fold by UTC day and month, whether any AI feature can run, and the providers the pane offers (`AISettings.swift`); speech records folded onto a recording's parts and overs, one over's sample range, the search by words, the text and SRT exports and the transcription job (`SpeechRecords.swift`); the assistant panel's rows, usage line and failure words (`AssistantModels.swift`), its view tools, their parsing and the waterfall's view window (`AssistantViewTools.swift`), its side of one conversation and the view tool executor's protocol (`AssistantController.swift`), and who changed the tuned channel last (`ChangeNote.swift`); the rule that has the window follow a channel another client makes on its capture (`ChannelFollow.swift`) | macOS and Linux |
| `LeylineApp` | the SwiftUI app: `AppSession` (the composition root: the mirror copied, the selection, the façade's state machines it owns, every action), the feeds (`SpectrumFeed`; `ChannelTelemetryFeed`, the tuned channel's meter, squelch edges and tones; `CaptureLevelFeed`, the radio's clipping count; `AudioLevelsFeed`, the tuned channel's audio spectrum in octave bands), the views (sidebar, band rail, spectrum, the Metal waterfall with its shader as source, the mouse both charts share in `ChartMouse.swift`, transport bar, device menu), the inspector (`InspectorView.swift`, `InspectorGroups.swift`, `AudioLevelsView.swift`), recording from the window (the log's Record transmissions switch and kept rows, the bookmark dot, the waterfall's time gutter and kept bars, the volume caption, the retune question, the File items), the window's two places (`MainWindow.swift`: the toolbar's `Radio \| Library` switch and the two bodies; the Library in `LibraryView.swift`, its sidebar, store footer and inspector, with the channel page in `RecordingsPage.swift`, the inspector on a part in `PartInspector.swift`, the player in `PlayerBar.swift` and the speech lines and their actions in `SpeechViews.swift`), a staged run (`Staging.swift`, "Staged runs" below), the calls behind `DaemonAgent`'s decisions (`EngineAgent.swift`: `SMAppService` registration and status, opening Login Items, `launchctl kickstart -k`), the CLI link's administrator request and result dialogs (`CommandLineInstaller.swift`), Sparkle's updater and the Check for Updates… menu item (`Updater.swift`), the Settings window and its AI pane (`SettingsView.swift`, `AISettingsView.swift`; "Settings" below), the assistant's panel (`AssistantPanel.swift`; "The assistant panel" below), `Theme.swift` | macOS only; the manifest declares it, and its Sparkle dependency, under `#if os(macOS)` |
| `LeylineClientTests` | the façade's rules without a daemon: the fold, the coalescer and its write order, the session's state machines, the decoders, the bands and bookmarks files, the spectrum folds, the transmissions log and the clock, the audio bands and their ballistics, a hand-written recording manifest, the part match, the switch's job and status line and the retune question, the channel page's cards and day groups, a part's words and table, and Play all's order; the AI pane's rows, privacy sentences and usage fold | both |
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
which maps to `LeylineError.daemonUnreachable`. The nine typed service clients are properties;
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
happened). The fold also keeps, for each capture and channel, the newest event with a
`caused_by` that moved a setting, together with the object before it (`changes`; a tombstone
removes the entry), because an event carries the whole object and a
change is a diff of two copies, as `ley`'s change lines are (`go/internal/cli/change.go`). An
activity-clock stamp moves no setting, so the squelch write that caused it stays the newest
change. `MirrorState` is a value with no daemon in it, and that is where the rules are tested.
The class is `@MainActor` because control events are a few a second, the mirror exists to be
rendered, and one actor means no hop per event. It imports no UI framework; `onChange` fires
after every change and the app's `@Observable` `AppSession` copies `state` and `connection` out
of it, so views hold one render's value and the façade serves AppKit, SwiftUI and the Linux tests
alike (Linux's Observation library does not link into a test bundle, which is how this rule was
found). Bulk rows and telemetry never pass through it.

**The coalescer** (`WriteCoalescer`, `PendingWrites`). A drag produces a frequency per frame;
the daemon keeps the last value per `(target, parameter)` every 20 ms, and so does this side:
`set` records the write and kicks a flush one tick (16 ms) later, so a frame's worth of writes
is one message and an idle coalescer sleeps on the kick, not a timer. The setters are
synchronous and take a lock, so a write is recorded before the call returns and the last value
is the last one the caller asked for; a write wrapped in its own `Task` would not be, because
Swift does not run two unstructured tasks in the order they were made. Writes are fire-and-forget
inside one `WriteParams` stream (`../design/control-plane.md`, "Parameter writes"); the
confirmation is the state event the mirror folds, and a refusal is a `WriteRejected` event
carrying the write's tag, which `set` returned. A view previews its own write and reconciles
on the event; it never treats the write as done.

**The session's state machines** (`HeldObject`, `RetuneQueue`, `PartPlayback`). `AppSession`
is the composition root: it owns these, does the I/O they describe, and forwards the names the
views already read. Each is in the façade so it is tested on Linux. A type a view renders through
is a value stored as one property of the observable session, so Observation sees each change;
`RetuneQueue`, which no view reads, is a main-actor class. `HeldObject` holds the capture or
channel the window made as its RPC returned it, from the response until the mirror's event, and
lets the id go only once the mirror had the object and lost it, or after 3 s when it never
arrives. `RetuneQueue` keeps one centre move in flight: a move asked for meanwhile waits, the last
one wins, and a superseded move's offset is never written. `PartPlayback` is the window's
playback of a recorded part, its end on the tombstone (or after 3 s unseen), Play all's queue,
and whether the live sink goes back on after the last part.

**The window follows the radio** (`ChannelFollow`, `AppSession.followOtherClients`). One radio,
one picture: when another client makes a channel on the capture the window shows (the assistant,
in the window's own panel or another client's conversation, a terminal's `ley tune`), the window
holds that channel, so the readout, the inspector, the rail's selection, the transmissions log and
the audio read it. The mirror keeps, for each channel, the event that first put it in the mirror
when that event named its cause (`MirrorState.made`: the client and the `seq`, for the channel's
life; a snapshot starts it empty, because it says who made a channel but not when). "Another client"
is any client id other than the window's (`ClientIdentity.id`), both as the creation's `caused_by`
and as the channel's `owner`, and never a job: a recording's or a scan's channel is not a tune. Of
several, the newest by `seq` wins, and only channels made after the window's own last tune count
(`floor`: raised by every frequency the window asks for, every channel it makes and every channel it
follows), so a channel the window moved away from is not followed again. The window does not take
ownership. It ends its own channel, unless a recording runs on it (a running record job that
borrowed the channel, or one on its frequency and mode, the frequency read before the move that took
it out of the capture): then the channel stays, the window's sink leaves it, the inspector says
`Your channel on 162.550 MHz stays open while it records.`, and the window ends it when the
recording stops. A recording counts only when it rides the window's capture or asks for its device;
one on another radio at the same frequency does not. The audio moves by sink, not by channel. A
`Sink` names no owner, so the window holds the id of the sink it attached (`heldSink`, a
`HeldObject` like the capture and channel), and mute, volume, a sweep's pause and a part's playback
act on that sink only, never on another client's. A sink the mirror says this client attached
(`sinkAttachedBy`) is the window's own whether or not it is held: one on the held channel is held
again when none is and the window is not muted, and any other is detached (`ChannelFollow.ownSink`,
`strayOwnSinks`), so a reply that came after the never-seen limit, an attach that overlapped
another, or a detach that failed never leaves a sink nothing can mute; a held sink is let go on its
tombstone, never before its detach, and one attach runs at a time. Mute is an intent the session
holds (`muted`, set by Mute and cleared by any attach), not the absence of a sink, because a channel
playing through another client's sink, a part playing and a channel just reconnected to have no sink
of the window's either. The window wants audio on the followed channel when it is not muted and no
recorded part holds the audio. It then waits `ChannelFollow.attachSettle` (1 s) and attaches its
sink, at the window's volume, only if it was not muted meanwhile and nothing plays the channel by
then, because the maker may attach its own a moment after making the channel: `ley tune` makes the
channel, measures the squelch from one spectrum row and then attaches, usually well inside the
second. A client that attaches its sink later than that doubles up only until the window sees it,
because two sinks on the held channel make the window detach its own (`redundantSink`), so the
channel plays through the other. While another client's sink plays the held channel and the window
has none, the inspector says so (`The audio plays through another terminal.`, named from the
mirror's `sinkAttachedBy`, the `caused_by` of each sink's first event), and the mute button and the
volume slider are disabled. A muted window stays muted. When the maker ends the channel (a
terminal's 5 s after its presence goes; `ley stop`), the held channel's `.lost` path makes the
window a channel of its own with the last copy's offset, mode, width and squelch. A capture another
client moved with no new channel is not followed: the out-of-capture caution under "Failure states"
covers it. Nothing is followed while the window makes a channel itself, sweeps, or has stopped
listening. A restarted daemon counts its `seq` from 0 again, so on every snapshot the mirror takes
(a connect, or a resync after a `seq` gap, which a fast restart can look like) the floor becomes the
snapshot's `seq`; `DaemonMirror` counts `snapshots` before it replaces the state, so the session
tells a replaced state from a folded event. A snapshot says who made a channel but not when, so a
channel another client made while the window was away is not followed by `seq`; instead `adopt()` on
reconnecting, when the window's own channel is gone or out of capture, takes the newest active
channel on the capture that is not a job's, newest by id because channel ids are ULIDs
(`ChannelFollow.stepOnConnect`, `adoptable`), and treats it as a follow. The first adoption at
launch prefers the same channel. The rule is tested in `ChannelFollowTests` and against the daemon
in `AssistantDaemonTests`.

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
The shared-memory ring is not implemented. The app reads bulk rows over gRPC and uses the returned
`StreamDescriptor` as the transport authority.

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
retune's event (an open edge first drops the old transmission instead). A record job on the
tuned log's frequency and mode
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
AMP, does not count. A measured fact
with its number and one action; not a detector (invariant 12). `ley tune` reports the same state
from the same count and words (`go/internal/cli/failure.go`), held by the same rule
(`cliphold.go`) and said once when raised, and also warns once, in its banner at tune, when
nothing on the band is 15 dB above the floor. The window does not show that warning, because
repeating it every few seconds on a quiet band distracts more than it helps. The daemon not
running, no radio and an unplugged radio are the mirror's states and live in
`AppSession.emptyWords`. The session folds every level reading, and every mirror change for the
gains, through `FailureHold`: clipping is raised after 1 s at or over the floor and cleared after
2 s under the exit fraction, on the capture's clock, because clipping comes in bursts of half a
second to two seconds and without the hold each burst would show and clear the words. Each
change is logged
after the hold. Clipping is drawn in three places and written in none.
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
signal readout is the panel's, not the transport bar's.

**Recording** (`Recordings.swift`; `AppSession`'s "Recording" and "Moving the radio over a
recording" sections). A recording is a record job's output
(`../design/recording.md`), and one rule decides every surface: a transmission is heard, a
recording is kept, and nothing offers to play what is not on disk. The log's head row is the
Record transmissions switch. On starts `Jobs.StartJob` in the frequency form of `RecordConfig`,
gated by squelch, with the tuned channel's frequency, mode, width and squelch copied
(`Recordings.config`) and a hang and pre-roll of 500 ms each (`windowHangMs`, `windowPreRollMs`),
so each transmission is its own part: the daemon's default 5 s hang folded a simplex exchange of
four overs into one part on a real radio, and `ley record` keeps that
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
it runs on a Mac; the façade's rules are tested in `RecordingsTests` and
`ClippedRowsTests`, and against the daemon's own manifest by the daemon-backed suite.

**Two places: the Radio and the Library** (`MainWindow.swift`, `LibraryView.swift`,
`PlayerBar.swift`). The toolbar's leading edge has a `Radio | Library`
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
typed into gets the key back (`TextFieldKeys`). Unverified until the Mac; the façade's rules are
tested in `RecordingPagesTests` and against the
daemon's manifest in the daemon-backed suite.

**The Library's speech** (`SpeechViews.swift`, the façade's `SpeechRecords.swift`). The speech
decoder's records (protocol `speech`, one per over) are read with `Decoders.QueryRecords`, one
query for a channel's unread recordings: protocol `speech` over their span with a minute either
side, because a record query has no filter on `clip_uri`, and `SpeechRecords.byRecording` sorts the
records to the recordings their `clip_uri` names (`AppSession.loadSpeech`, for the page's channel
and again on each event of a transcription job of a recording, never twice at once; a failed read
waits for the next listing). A read the daemon cut at its limit keeps its lines and the page adds
`(more words not loaded)`. Each recording's `RecordingSpeech` is built once and dropped when its
lines or its manifest change. `RecordingSpeech`
folds them onto parts and overs by `clip_uri` and `over`, dated through the manifest's anchors;
each over shows its newest transcription's line (job ids are ULIDs, so the greatest is the
newest), and the earlier ones stay (`versions`, `shown(job:)`), because records are immutable and
transcribing again adds records. Under each part row (`PartSpeechLines`) are its lines
(`SpeechLineView`: the text in `body`, the model and confidence in `footnote` `inkFaint`, the
callsigns as chips), each a button beside the row's, not inside it; a click plays that over alone
(`AppSession.play(part:over:)`): `RecordingManifest.read(at:reusing:)` reads, off the main actor,
the sidecar of each part whose squelch opened for its openings (`RecordingPart.squelchIntervals`),
and on a re-read only the sidecars of parts it did not have; `SpeechRecords.range` cuts the over's
segment by the daemon's own `Segmenter` rule with the speech decoder's pre-roll and hang (half a
second each unless its manifest says otherwise), not the recording's gate pre-roll, so what plays is
what was transcribed; `StartPlayback` takes it as a sample range, and `PartPlayback.playingOver`
marks the line playing. A part whose openings were not read plays whole and marks no line. On a recording's first row a running transcription shows `Transcribing · 3 overs
so far`, a held-up one the daemon's `status_detail` in `caution`, a failed one its reason in
`accentRec`. A part row's context menu and the part inspector hold Transcribe, Transcribe again…
and Export words… (`SpeechActions`). Transcribe asks `ley transcribe`'s question in a confirmation
dialog (the minutes from `squelch_open_ms`, else the sidecars, and the decoder's hosts), then starts
the kept decode job with `source_uri`; Transcribe again… first offers the speech model (the one in
use, then the catalogue's, or Custom… and typed), sets it as the speech feature's model, and puts
it back if the daemon refuses the job, clearing it when none was set before. Transcribe is absent while no speech decoder is installed or it needs a key and
none is set (`SpeechRecords.canTranscribe`), and on a recording with no openings. Export words…
writes the shown lines through `NSSavePanel`: plain text, `[14:03:20] text (W6ABC)` a line, or SRT
timed from the recording's first sample through each part's capture's anchor, so the gaps between
parts are kept; a line nothing dates is left out of the SRT and counted in the log. The sidebar's
search also matches what was said: while the field holds words each channel's unread speech is
read, one query a channel, and a channel matches when one of its shown lines holds the words
(case-blind), and a row's click or Return selects the part and the over, opens its day if it is
under EARLIER, and scrolls the page to the line (`selectedOver`). Unverified until the Mac; the fold, the ranges, the search and both exports
are tested in `SpeechRecordsTests`.

**The audio ladder** (`AudioLevelsView.swift`, `AudioLevelsFeed`). Between the reading and the
log, the panel draws the meter `ley levels --watch` draws:
the demod tap's spectrum at 1024 bins and 20 rows a second, one subscription per channel and only
while the panel is shown, summed into nine octave bands by the façade's `BandLevels` and moved by
`LevelBar`'s ballistics on the capture's sample clock. Its rms and peak are the meter's
`audio_dbfs` and `audio_peak_dbfs`, and a closed squelch leaves every bar unlit, because the
demod tap carries the discriminator's noise between transmissions. The view was written in the
container and is unverified until it runs on a Mac.

## Settings

The app menu's Settings… (⌘,) is SwiftUI's `Settings` scene, which `LeylineApp` declares beside
the window with the same `AppSession` in its environment. `SettingsView` is the window: a tab per
pane, one today, AI. It is forced dark with `.preferredColorScheme(.dark)`, as the main window is,
whatever the system's appearance: `Theme`'s colours are literals drawn for a dark ground, and a
Settings window that followed a light system would put that ink on a light ground. Giving every
token a light value is the larger change and waits for a pane that needs it.

**The AI pane** (`AISettingsView`) renders the mirror's `ai` and `usage` through the façade's rows
in `AISettings.swift` and writes through four session calls, each one unary RPC as recordings and
bookmarks write (the coalescer carries parameter writes only): `addKey`, `checkKey`, `removeKey`
and `setFeatureModel`. A row changes when the daemon's `ai` or `usage` event arrives, so a key
`ley ai add` stored appears at once and one the pane added appears the same way. The outcome of
each call is one line, `settingsNotice`, at the top of the pane; the window's own `notice` shows
over the waterfall, where a person in Settings would not see it. The key typed into the
`SecureField` is held in the form's state until the daemon has it and in `addKey`'s request,
and nowhere else: not in the session, not in a log line. The field clears the moment Add is
pressed and gets the key back only if the daemon did not store it, so a mistyped key can be
corrected. It also clears when a window closes, on `NSWindow.willCloseNotification`, because
`onDisappear` is not reliably sent to a `Settings` scene's content when its window closes.

The pane has three groups. **Keys** lists each key with its provider, label, last four characters,
when it was added, last used and last checked, the check's outcome (`good` accepted, `recording`
rejected, `caution` unavailable) and the provider's words, with Check and Remove; Remove asks
first, because the daemon ends every job and conversation using the key. The Add form takes the
provider from `ProviderCatalog`, a label, the key and, for an OpenAI-compatible server, its
endpoint. **Features** has a provider picker and a model picker per feature (a field for a
provider whose models are typed), and under them what the shown choice sends to which host, so a
choice is read before it is made: for the assistant, the conversation and the tool results,
which include frequencies, decoded records and speech text; for speech, the squelch-open audio;
the endpoint's host when the key has one; and "nothing leaves the Mac" for an on-device engine.
**Usage** is a table by UTC day since the day 30 days back (`ley ai usage`'s default) or by month
over the whole ledger, summed over jobs and conversations as `ley ai usage` sums them, its empty
columns left out, with a total row and the note that the numbers are what the workers reported.

With no key and no on-device engine set, the pane shows what each feature does and would send,
and the Add form, and nothing else; `AppSession.hasAnyAI` is that flag, and any AI control
outside Settings shows only while it holds (`../design/ai.md`, "Context"). The catalog lists
Anthropic with its three models and an OpenAI-compatible server; no speech provider is listed
until one is chosen by measuring the candidates on receiver audio (`../design/ai.md`,
"Providers").

On Linux the rows, the privacy sentences, the flag and the usage fold are tested in
`AISettingsTests`, and the calls the session makes against the daemon in
`AISettingsDaemonTests`; the pane itself and the scene are never compiled there.

## The assistant panel

The assistant's conversation is daemon state (`../design/ai.md`, "The assistant"), and the panel
is one client of it, as the test harness `ley ask` is another: it renders the conversation and moves
it only through the `Assistant` RPCs. It is a column of `Theme.Layout.assistantPanel` on the
window's right, beside the inspector, shown while `AppSession.assistantShown` (the toolbar's toggle
beside the inspector's, and View ▸ Show Assistant, ⇧⌘A; remembered in the defaults) and `hasAnyAI`
both hold, so the panel and its toggle appear only once a key or an on-device engine is set; the
menu item is disabled until then rather than left out, because a `Commands` body is not
re-evaluated. The window's minimum width (`Theme.Layout.windowMinWidth`) grows by the column's while
it shows, so the canvas keeps its room beside the sidebar, the inspector and the column. The column
is in `MainWindow` beside both places' bodies rather than inside each, so a switch of place, the
assistant's own `show_place` included, leaves the transcript, its scroll and the field alone.

**The conversation** (`AssistantController`, in the façade, with the RPCs behind `AssistantCalls` so
its rules are tested without a daemon). The window starts a conversation with `StartConversation`,
declaring the app's view tools and naming no provider or model, so the daemon uses the assistant
feature's; the first message starts one when none is going, and New Conversation ends the one shown
and empties the panel. `SendMessage`, `ResolveAction` (Allow, Allow for this conversation, Decline),
`StopTurn` and `EndConversation` are the other calls. The controller holds the newest copy of the
conversation by `seq`, from the replies, from a `WatchConversation` stream that resumes from the
`seq` it holds after a drop, and from the mirror's `conversation` events, which the session passes
on. A refusal is a notice: `CREDENTIAL_MISSING`, `CREDENTIAL_REJECTED` and a start's
`FAILED_PRECONDITION` (no model chosen) point to Settings with an Open Settings button; a
`FAILED_PRECONDITION` on any other call means the conversation moved on first and says nothing; an
unknown id marks the conversation gone, deleted by another client or dropped by the daemon's
retention; a daemon restart does not, because the daemon keeps conversations on disk. A deleted
conversation stays in the mirror, last seen `ENDED`, until the next `GetState` snapshot, since the
contract sends no event for the deletion itself. The session copies the controller's state out on
every change, as it copies the mirror's.

**The rows** (`AssistantModels.swift`). `ConversationView` turns the conversation into turns, a
user's right-aligned in `inkMuted` and the assistant's text in `inkSecondary`, under its steps
(`ink`, the brightest, is kept for the field's typing), and each tool call into a step:
`→ tool arguments` on one line (a single argument is its value alone, several are `name value`
pairs, cut at 80 characters), a state word (`running`, `done`, `failed`, `asks`, `in the app`,
`declined`, `stopped`) and the result's first line; opened, the step shows the arguments as indented
JSON, the whole result and its JSON. While the assistant is on a turn and no step of its newest
turn is `running` (`ConversationView.isWaitingOnModel`), the model is thinking, and a waiting row
under the turns says so: a small spinner and `thinking…`, with the seconds from three on
(`thinking… 4s`), counted from the conversation's `last_turn_at_ns`, so the count starts again
after each step (`cli-style.md`, "A wait says so, and leaves nothing behind"). As that rule asks,
it is drawn only once the wait has gone on for 300 ms, so an answer that comes straight back does
not flicker it; unlike a terminal's progress line, it has a spinner, which a window can draw
without redrawing text. A running step is its own sign, so the row is absent then, and
nothing of it stays once the turn moves on. A call waiting for approval is a card with the
question, the gate's reason (`assistant.md`, "The gate") and a button per answer the call offers
(`PendingQuestion.offers`): Decline, Allow for this conversation when the call can be granted for
the rest of the conversation (never a delete or a cancel of another client's job), and Allow, none
on Return. Once one is pressed all three are disabled, and a click meanwhile is dropped, until the
daemon replies to that answer, so a second click sends no second answer; a question still pending
after a failed answer can be answered again. The app starts every conversation in the default mode,
in which questions are asked; the panel has no switch for the mode that asks nothing. Stop shows
while the assistant thinks and while it waits on one of the app's view tools. The usage line under
the transcript is the mirror's usage lines whose scope is the conversation, summed: `3 requests,
1.2k in, 400 out`, with the tokens the provider's cache served when there were any; never a price.
The field is never disabled, so the next message can be written while the assistant thinks or
waits. Return sends only when the daemon would take the message: the conversation is idle, over
or lost (an over or lost one is replaced by a new one), and no message is on its way. Otherwise
Return does nothing and the text stays, and while the field holds text a line under it says what
Return waits for (`AssistantWords.returnWaits`): `Return sends once the assistant is done.`, or
`Return sends once you have answered.` while a question card shows. Return does not queue the
message: once the turn ends, Return sends it. The field also keeps its own flag from Return until
the daemon replies, because `assistantSending` reaches the view only once the controller's change
is copied to the session, and a second Return in that gap would send the message twice. A message
the daemon did not take goes back into the
field, above anything typed while it was on its way. `TuningKeyGuard` keeps Space and the arrows
in the field.

**The view tools** (`AssistantViewTools.swift`). The app declares three, each named by the
worker's rule (1 to 64 letters, digits, `_` or `-`, no radio tool's name; `assistant.md`, "The
tools"): `show_band` (`{band}` by name or alias, or `{from_hz, to_hz}`), `select_recording`
(`{recording, part?}`, an id or a `ley://recordings/` URI) and `show_place` (`{place: radio |
library}`). The daemon routes each call to the app as a call awaiting the client; the controller
performs each call id once: the input is parsed, and a bad one is an error answer the model reads,
never a crash; the session performs the rest on the main actor (`ViewToolPerformer`) and the answer
goes back with `AnswerViewTool`, prose and JSON. An answer that does not reach the daemon is kept
and sent again after the watch's backoff, without performing the call again; a
`FAILED_PRECONDITION` means the conversation moved on and ends it. None of them moves the radio. `show_band` fits the
part of the range inside the span the radio captures, at the highest zoom whose window holds it,
and centres the window there (`ViewWindow.fit`; the session's `viewFocus`, which `visibleRange`
reads through `ViewWindow.visible`). The session clears the focus after every mirror change in
which the tuned frequency is no longer the one it was set against, and when the zoom returns to 1
(`ViewFocus.kept`), so any tune, from any client, puts the window back on the tuned frequency; a
range the span does not reach is an error answer
saying to tune, because retuning goes through the radio tools and their don't-disturb check.
`select_recording` goes through `AppSession.selectRecording(id:part:)`, which sets the place, the
Library's channel row and the part URI as the Library's own clicks do, and is the one way to
select a recording from outside the Library's views. `show_place` sets the place.

**Attribution** (`ChangeNote.swift`). The inspector's identity has one line under the channel's
frequency and mode when another client changed the channel or its radio last, from the mirror's
`changes`: "The assistant set the squelch to -45 dBFS.", "Another terminal set the mode to AM and
the width to 25.0 kHz." A channel another client made, which the window follows, reads as a tune
from the mirror's `made`: "The assistant tuned to 162.400 MHz NFM.", and with the squelch the
same client set right after, "The assistant tuned to 162.400 MHz NFM and set the squelch to -42
dBFS." The words and the names are `ley`'s change lines (`whoChanged`): the
assistant is the MCP client labelled `assistant`, as the worker's tool server dials. A change is
shown only while the channel and its radio still hold the values it set, so an unattributed
change since (the daemon's own) never leaves the note naming a stale value, and the line goes as
soon as this window changes the channel.

On Linux the rows, the view tools' parsing and answers, the view window, the focus rule and the
attribution fold are tested in `AssistantModelsTests`, `AssistantViewToolsTests` and
`ChangeNoteTests`; the controller's rules (the watch resuming from its `seq`, a forgotten
conversation, a call performed once and its answer sent again, another conversation ignored) in
`AssistantControllerTests` against a fake `AssistantCalls`; and the conversation against the
daemon in `AssistantDaemonTests`; the panel, the toggle and the session's
side are never compiled there.


## Palette and type

Every value below is in `Theme.swift`, under the names given here, and a view uses no colour or
font that is not one of them. `make app-lint` runs `scripts/check-theme.sh`, which fails on a
colour, system font or hex value anywhere else in `LeylineApp`, a shorthand system colour
(`.black`, `.secondary`) passed to `foregroundStyle`, `fill`, `background` and the like or listed
in a gradient's `colors:` included. `PaletteTests` fails when the
palette table and `Theme.swift` disagree, and when an ink falls under its WCAG contrast floor on
`ground`, `chrome`, `panel`, `raised` or `selected`: 4.5:1 for `ink`, `inkSecondary` and
`inkTertiary`, 3:1 for the three fainter inks. Two pairs are under it and recorded in the test as
known exceptions: `inkFaintest` on `chrome` (2.98:1) and on `selected` (2.84:1).

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
| `border` | `#23282C` | a divider between regions, a control's edge; a pop-up's ground inside the chrome |
| `borderStrong` | `#2A3034` | a control that accepts a drag; a popover's ground edge |
| `borderFocus` | `#3A4044` | the tuning field, an open popover |
| `ink` | `#E7E9EA` | primary text, the tuned frequency |
| `inkSecondary` | `#C5CACD` | a row's label, the assistant's reply in its panel |
| `inkTertiary` | `#9BA1A6` | a value beside a label, a descriptive clause |
| `inkMuted` | `#7A8185` | a unit, a subtitle |
| `inkFaint` | `#6B7276` | a section header |
| `inkFaintest` | `#5F656A` | a footnote under a control |
| `inkDisabled` | `#4A5054` | the sub-kHz digits of the tuning field |
| `accent` | `#E8814A` | the tuned channel, and nothing else |
| `good` | `#2FB6A3` | squelch open, a connected device, a bookmarked frequency |
| `caution` | `#C9C06A` | off tune, overdeviating, the radio clipping, a channel outside the capture; the ramp's fourth stop |
| `recording` | `#B8483C` | the radio clipping: the waterfall's clipped-row marks, the gain slider's knob |
| `meterWell` | `#000000` | the left end of the squelch meter's container, fading to the ramp's first stop |
| `accentRec` | `#E5484D` | what is being kept: the Record transmissions switch, the live row's dot, a recording bookmark's dot, the time gutter's kept bars |

`recording` and `accentRec` are never on one element, so red on a control always means kept and
red on the waterfall's edge always means clipped.

The level ramp keeps the terminal's hue order (`cli-style.md`, "3a. The level ramp") and runs
cold to hot for the app's dark ground, six stops from near-black to cream:

```
#10262B  #14555A  #2FB6A3  #C9C06A  #E8814A  #F6E6DA
 cold end                          cold end + 40 dB
```

**The hot end is 40 dB over the cold end, fixed**, not the loudest level on the band. Every
row on screen is coloured with the current ramp on every frame, so a hot end that moved
recoloured the whole history: a transmission already drawn dimmed when something louder keyed
up anywhere in the capture, off screen included, and brightened again as the peak decayed after
it. With a fixed reach a row keeps its colour while it scrolls, and only a squelch change
recolours it. Six stops over 40 dB is about 8 dB a stop; anything 40 dB over the cold end is
cream. The cost is that a weak band no longer stretches to reach the last stop.

**The ramp's cold end is the squelch**: the channel's threshold converted
to a level per bin (`squelch − 10·log10(bandwidth / bin width)`, the auto squelch's scaling in
reverse), so dragging the marker up darkens the noise and only signals above the squelch have
colour. Under the squelch the waterfall fades from the first stop to `ground` over 6 dB and
stays there: bins below the squelch go almost black, a clip rather than a
rescaled ramp, so the scale above the squelch is unchanged. With the squelch off, or before a
floor is known, the cold end is the floor plus 6 dB (`SpectrumFeed.noiseHeadroomDB`): noise
spreads a few dB either side of the median, and with the cold end on the median half of it had
colour and the picture was a teal haze. The floor is held (`HeldFloor`): it falls as soon as the
smoothed median is 4 dB under it, rises only after the median has stayed 4 dB over it for 5 s on
the capture's clock, and is re-taken at once after a retune or a gain
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
| the channel's name in the inspector | `name` | SF | 21 medium | `-0.015em` tracking |
| signal readout | | SF Mono | 21 | tabular |
| body, control labels | `body`, `label` | SF | 12.5–13 | |
| a value beside a label | `value`, `valueSmall` | SF Mono | 10.5–11.5 | tabular wherever it changes |
| section header | `section` | SF Mono | 9.5 | uppercase, `0.14em` tracking |
| a table's column head | `columnHead` | SF Mono | 8.5 | the inspector's log |
| a clause under a sentence | `aside` | SF | 11.5 | |
| footnote under a control | `footnote` | SF | 10.5 | |
| an SF Symbol in a control | `glyph`, `transportGlyph`, `arrowGlyph`, `closeGlyph`, `checkGlyph`, `fieldGlyph`, `buttonGlyph`, `editGlyph`, `panelGlyph`, `toolbarGlyph` | SF Symbols | 6–16 | one token per role: a chevron, the × on a banner, a search field's glass |

Every number that changes while you watch it uses tabular figures, without exception, so a
frequency does not change width while tuning.

## Brand

The mark and the splash are the SVGs in `../design/brand/`, drawn in code rather than loaded,
so they take `Theme`'s colours at any size. `BrandMark` is the
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
`--with-daemon` it carries what a distributed build ships: `leylined`, `ley` and the decoder
programs under `Contents/Helpers`, which holds code only (codesign refuses any other file there);
the decoder manifests under `Contents/Resources/decoders` and the licence texts under
`Contents/Resources/licenses`; the driver libraries under `Contents/Frameworks`, with
`drivers.json` in `Contents/Resources` (`../decisions/S3-usb-posture.md`); and the daemon's
launch agent, `com.leysdr.daemon.plist`, under `Contents/Library/LaunchAgents`. The agent's
source is `app/Sources/LeylineApp/com.leysdr.daemon.plist`, excluded from the target; it runs
`Contents/Helpers/leylined --log-file ~/Library/Logs/Leyline/leylined.log`, because launchd
expands no `~` and the daemon expands it itself. On launch the app registers it through
`SMAppService` unless `~/Library/LaunchAgents/com.leysdr.daemon.plist` exists (a source build's
`ley daemon install` owns the label) or `LEYLINE_SOCKET` is set (`DaemonAgent`).

The app links Sparkle 2, which SwiftPM downloads as a binary target only when the manifest is
evaluated on macOS; the committed `Package.resolved` is the macOS graph. A distributed bundle
carries `Sparkle.framework` in `Contents/Frameworks`. `Info.plist` names the feed (`SUFeedURL`,
`https://leysdr.com/updates/appcast.xml`) and the EdDSA public key (`SUPublicEDKey`), and the
updater starts only in a `.app` bundle with that key and without `LEYLINE_SOCKET` or a stage
file (`AppUpdates`), so `make app-run` and the screenshot runs check for nothing. Sparkle compares
`CFBundleVersion`, so it is a number that only grows; the `git describe` string is the
`LeylineBuild` key. `CODESIGN_IDENTITY` signs for real; `make release` signs with the hardened
runtime, notarizes and builds the disk image (`release-checklist.md`, "The signed build").

The waterfall's shader is Swift source compiled at launch, not a `.metal` resource: `swift
build` does not produce the `default.metallib` Xcode does, so the
source lives in `WaterfallShader.swift` and a compile failure is a sentence in the window rather
than a dark panel (`swift-style.md`, "AppKit and Metal").

In the container and on Linux CI, `make app` builds the façade and `make app-test app-e2e` runs
both suites against the Linux-built daemon; the SwiftUI target does not exist there. `make app-format` runs swift-format over the package with the
configuration in `app/.swift-format` (`swift-style.md`, "Files"); run it before a commit. Anything
under `#if canImport(SwiftUI)`, `Metal` or `AppKit` is never compiled on Linux, the same trap
`setup.md` records for Accelerate: a green Linux run does not compile any view.

## Staged runs

`LEYLINE_APP_STAGE` names a stage file, and the app then sets its window to it for the site's
screenshots (`../plans/site-shots.md`, "App shots") and for check runs. `leyshots` writes the
file. It holds JSON that `ShotStage` decodes, and every key is optional:

| key | what the app does |
|---|---|
| `window` | `{"width":1440,"height":820}`: sets the window's frame to this many points, toolbar included, keeping its top-left corner. The frame is not autosaved. `leyshots` launches the app with `-ApplePersistenceIgnoreState YES`, so no saved window is reopened. |
| `inspector` | shows or hides the inspector |
| `select_bookmark` | tunes the first bookmark with this name, as a click on its sidebar row does |
| `import_chirp` | an absolute path to a CHIRP CSV, imported through File ▸ Import CHIRP…'s code path, so the notice prints the import's real counts |
| `expanded_band` | opens this sidebar row (`2m`, the id in `bands.json`), as its chevron does |
| `place` | `radio` or `library`, as the toolbar's switch sets it |
| `select_part` | selects this part of the Library's selected channel without playing it, counted from 0 down the page's recent days |
| `play_part` | with `select_part`, plays that part for 0.4 s and pauses it, as a click and a second click do, because the Library draws only the playing row as current |
| `assistant` | shows or hides the assistant's panel, as its toolbar button does; the panel draws only while an AI provider is set up |
| `channels_picker` | opens this sidebar row's Channels… popover |
| `settle` | the seconds the window keeps drawing after the stage is applied, before the regions are measured |
| `on_air` | after `settle`, waits up to 30 s for an over to start and keep the tuned channel's squelch open through 1.5 s, so the readings and audio meters are live in the shot with the rest of the over to come; an over already on the air when the wait begins, or one that ends sooner, is passed over for the next. The scene needs a squelch level set |
| `focus_filter` | after `settle`, gives the sidebar's filter field the focus, as Go to… (⌘G) does |
| `zoom` | the spectrum and waterfall's zoom, as the band rail's − and + set it: 1, 2, 4 or 8, centred on the tuned frequency |
| `scan_band` | with `expanded_band`, presses that row's Scan band as a click does and waits up to 60 s for the sweep to end before `settle` starts, so its hits show |

A staged run shows no splash, so its first frame is the window. It writes nothing to
UserDefaults and does not reopen the last band, so a staged run neither changes nor depends on
the person's own settings. AppKit writes some keys of its own all the same (a window's frame
under `NSWindow Frame …`), so `leyshots` never launches the bundle it is given: it launches a
copy in `tmp/staged-app/` whose `CFBundleIdentifier` is `com.leysdr.app.staged`, ad-hoc signed
again and remade only when the source's executable or `Info.plist` changes. Its defaults, saved
state and window frames are that copy's, never the person's app's. Nothing in the app keys on the
identifier: Sparkle does not start in a staged run, the launch agent is not registered when
`LEYLINE_SOCKET` names a socket, and the CLI link is only made from its menu item. The stage is applied once, in the order of the table, after the daemon
is live and the window has its channel, or 5 s after that if no channel arrives. A scene
therefore starts with a capture already tuned (`ley tune`), as it would be for someone who has
the radio running. Without one, the app opens FM broadcast, as a first launch does. The stage changes only what the window's own controls
change, and the daemon's state is changed only by the tune a click would make (invariant 7).

A staged run puts its window on the screen with the menu bar (`NSScreen.screens[0]`), its top-left
corner 40 pt in from that screen's visible frame, before the stage sizes it, and draws it in sRGB,
and `window.png` is converted to sRGB before it is written. A window draws in its screen's colour
space, so the same frame on two displays differed in every pixel (7 % of a picture between two
Dell monitors), and macOS moves a popover to fit the screen it opens on. Forced onto the other
display once, the window gave the same picture to the pixel.

A staged run draws the same frame twice (`DeterministicFrames.swift`), so two pictures of a still
scene differ only where the radio moves them. SwiftUI's animations are disabled by a transaction
at the window's root; window and scroll animations are off and the text caret does not blink,
through registration defaults that are never written to disk; and the window draws as the key
window whatever has the focus, so its traffic lights are coloured even while the person at the
Mac works in another app. What still moves is the spectrum, the waterfall (which runs on), the inspector's live readings
(the signal, tuning and deviation figures, the time on the air and the audio ladder) and its
log's rows and their day, and the tone last heard; they are the regions `spectrum`, `waterfall`,
`readings`, `transmissions`, `log_day` and `heard`, and a check masks them all. The heard tone and
the day are laid out at their full width when blank, so their first appearance moves nothing.

`settle` seconds after the stage is applied (and, with `on_air`, once an over is on the air), the
app clears the text focus. Without a command file it then brings the window to the front and
waits 1 s, because Stage Manager draws a window that is not in front as a small tilted thumbnail
in its strip and `screencapture -l` takes the thumbnail; `leyshots` refuses a capture that is not
the window's size at 1×, 2× or 3×. It then writes `window.png` and `regions.json` beside the stage
file, the picture first, each replaced atomically:

```json
{"window_number": 4242, "scale": 2,
 "regions": {"window": {"x": 0, "y": 0, "width": 1440, "height": 820},
             "toolbar": {"x": 0, "y": 0, "width": 1440, "height": 52}, "sidebar": {…}}}
```

`window.png` is the whole window, title bar and toolbar included, drawn by the app itself at the
backing scale, so it needs no Screen Recording permission and does not depend on the focus. The
app draws the window's frame view with `cacheDisplay(in:to:)`. A Metal layer draws nothing
there, so the waterfall's renderer draws one more frame into an offscreen texture and that
image is laid over the Metal view for the draw, under what SwiftUI draws over the waterfall.
Against `screencapture -o -l` of the same window the picture differs at the window's four rounded
corners, which `screencapture` leaves transparent. A text field's system placeholder is dimmed
only by vibrancy, which `cacheDisplay` does not apply, so the sidebar filter draws its own
placeholder in `inkFaint`.

`window_number` is the `NSWindow` number that `screencapture -l` takes, and `scale` is the
window's backing scale, the pixels per point in `window.png`. Each region is a rectangle
in points from the top-left corner of the window's frame, toolbar included, because
`screencapture -l` captures that whole frame. The regions are `window`, `toolbar`, `sidebar`,
`inspector`, `spectrum`, `waterfall`, `notice` (the one-line notice over the bottom of the waterfall, while one shows), `library` (the Library's whole body), `parts` (the Library's page of the selected channel),
`readings` (the inspector's Signal, Tuning, Deviation and On air rows and its audio ladder),
`transmissions` (the rows of the inspector's log, which gain one whenever an over ends),
`log_day` (the day over those rows, blank until the first) and `heard` (the tone the channel last
heard, beside the bookmark's Tone, which shows once one has been measured). In the Library, `sidebar` and
`inspector` are the Library's own. A region that is not on screen is left out of the file. Each
region except `window` and `toolbar` is measured by a `WindowFrameProbe` under its view. The
toolbar is hosted outside the content's view tree, so its region is the strip above the window's
`contentLayoutRect`. Every step is logged under `stage`. If the daemon is not live within 15 s,
or the stage file cannot be read, the app applies nothing and writes no regions, and the log
says why.

### The command file

`LEYLINE_APP_CONTROL` names a directory through which `leyshots check` drives the window
(`../plans/mac-loop.md`, "The protocol", has the client's side). It stages the run as a stage file does,
with or without one. It first removes what an earlier run left there (`ready.json` and `out/`)
and skips the lines `commands.jsonl` already holds, so a reused directory replays nothing; a
`commands.jsonl` that shrinks is read again from its start. Once a stage file given at launch has been applied and has settled, or
once the daemon is live and the window has its channel when there is none, the app writes
`ready.json` there:

```json
{"ok": true, "pid": 123, "window_number": 456, "scale": 2, "error": ""}
```

`ok` is false, with the reason in `error`, when the daemon was not live within 15 s; commands are
still taken. The client then appends one JSON object per line to `commands.jsonl`. The app reads
new complete lines every 100 ms and runs them one at a time, in order. Each has an integer `id`,
unique in the run, and a `cmd`, and each is answered in `out/<id>.json`, written to a temporary
file and renamed, so a reader never sees half an answer:

```json
{"id": 7, "ok": true, "error": "", "files": ["out/7.png"], "result": {…}}
```

Paths in `files` are relative to the directory, and `result` is `{}` for a command with nothing
to return. A line the app cannot parse or run is answered `ok:false` with the reason in `error`,
and the next line still runs; a line with no `id` has no answer file, so it is only logged.

| `cmd` | fields | answer |
|---|---|---|
| `stage` | `stage`: a stage object as above (`settle` is slept, `window` resizes) | `result.applied`: the steps, as the log lines give them |
| `snapshot` | `settle`: seconds to wait first, default 0 | `out/<id>.png`; `result`: `scale`, `width_pt`, `height_pt` and `regions`, as `regions.json` gives them |
| `state` | | `result`: `place`, `tuned_hz`, `mode`, `bandwidth_hz`, `channel_id`, `capture_id`, `band`, `bookmark`, `open_rows`, `filter_query`, `inspector_shown`, `assistant_shown`, `zoom`, `focused` (the focused control's identifier, else its role and label), `notices` (every message the window shows), `popover` (`channels:<row>`, `device_menu` or empty), `selected_recording_channel`, `selected_part`, `heard` (the tone the tuned channel last heard, as the inspector writes it: `PL 100.0`), `hits` (the last sweep's hits as its row lists them, strongest first); every key is present, `null` when it has no value |
| `ax` | `window`: `main` (the default; its popovers and sheets are in its tree) or `settings` (the Settings window, while it is open: the key `cmd+,` opens it) | `out/<id>.ax.txt`: the window's accessibility tree, one element per line indented two spaces a level: role, `id=` and the identifier when there is one, the label, `value=` when there is one (quoted, with `\`, `"` and newlines escaped), the frame in points from the window's top-left corner as the regions are measured (a text field's left edge and width only, `(38,– 161×–)`, because its AppKit view keeps the height of whichever field it was first made for, 13 or 15 pt, from launch to launch while its pixels stay put), `enabled` or `disabled`; `result`: as `snapshot`'s, so a reader can tell which elements lie in which region, and `{}` for the Settings window |
| `key` | `keys`: `cmd+g`, `shift+cmd+left`, `escape`, `return`, `down`… | a key down and up |
| `type` | `text` | a key down and up for each character |
| `press` | `identifier` | AXPress on the first element with that accessibility identifier, or the focus for a text field, which has no press; `ok:false` when none has it |
| `wait` | `seconds` | answered after that long |
| `quit` | | answered, then the app quits |

Keys are posted to the app's own event queue, as a keyboard's arrive, so a menu's key equivalent,
the filter field's key monitor and the focused field all see them, and nothing is typed into
another app. A modifier is `cmd`, `shift`, `opt` or `ctrl`; a key is one character or one of
`return`, `escape`, `tab`, `space`, `delete`, `forward_delete`, the four arrows, `home`, `end`,
`page_up` and `page_down`. Each key's answer is written 150 ms after the key, so a key that moves
the focus has moved it before the next command. A command-file run never activates the app or
brings its window forward, so the person at the Mac keeps the focus; the window is made key
within the app, which is where a field's focus lives. The tree comes from the accessibility API
on the app's own process, which SwiftUI answers in full only when the process is allowed to use
that API: the bundle `leyshots` launches (`tmp/staged-app/Leyline.app`, under
`com.leysdr.app.staged`) is added once in System Settings > Privacy & Security > Accessibility.
Its designated requirement is its identifier, so the permission holds for every later copy. A
process without it is answered with the application's element wherever a window should be, and
`ax` answers `ok:false` saying so.

### Accessibility identifiers

The views the checks name carry an accessibility identifier, which `ax` prints after `id=` and
`press` takes. An identifier is lowercase words joined by dots, the area first; a row of a list
ends in its data, a name slugged by `ViewIdentifier.slug` (`Club repeater` is `club-repeater`),
so the identifier stays the same from one run to the next while the data does. The views give
them and nothing else: an identifier changes no layout and no behaviour.

| prefix | views |
|---|---|
| `toolbar.` | `place.radio`, `place.library`, `device` (the chip), `inspector`, `assistant` |
| `sidebar` | the Radio's sidebar; `.filter`, `.add` (＋), `.list`, `.outofrange`, `.band.<id>` (a band row by its id in `bands.json`) with `.chevron`, `.scan` and `.channels` under it, `.bookmark.<name>`, `.hit.<label>` (a sweep's hit, by the name or frequency it shows, because the frequency it measured moves from run to run; a label two hits share is `-2`, `-3` on the second and later by frequency) with `.add` (its ＋), `.match.<id>` (a row of the filtered list) |
| `planpicker` | the Channels… popover; `.filter`, `.row.<channel>` |
| `devicemenu` | the device chip's popover; `.rate`, `.gain.<stage>` and `.gain.<stage>.auto`, `.device.<id>` |
| `rail` | the band rail; `.track`, `.below`, `.above`, `.zoom.out`, `.zoom.in`, `.channel.<channel>` and `.hit.<label>` (the ticks on the track; a hit's as the sidebar names it) |
| `spectrum.` | `maxhold`, `clear` |
| `tuning.` | `field` (the frequency's digits), `up`, `down` |
| `transport` | the bar under the Radio; `.mute`, `.mode`, `.width`, `.squelch` with `.squelch.track`, `.volume` |
| `inspector` | the Radio's inspector; its groups `.header`, `.identity`, `.readings`, `.audio`, `.log`, `.measurements`; its controls `.rename`, `.tone`, `.note`, `.revert`, `.save`, `.tuneinside`, `.record`, `.measurements.toggle` |
| `library.` | `sidebar`, `search`, `channel.<hz>`, `page`, `page.record`, `page.tune`, `day.<day>` (an EARLIER day's line) and `day.<day>.play`, `part.<n>` (counted from 0 down the page, as `select_part` counts), `inspector`, `inspector.playall`, `inspector.finder`, `inspector.delete` |
| `player` | the Library's bar; `.previous`, `.play`, `.next`, `.volume` |
| `assistant.` | `panel`, `new`, `input`, `stop`, `settings`, `decline`, `allow`, `allow.conversation` |
| `settings.ai` | the Settings window's AI pane; `.key.<provider>` with `.check` and `.remove`, `.add` with `.add.provider`, `.add.label`, `.add.key` and `.add.endpoint`, `.feature.<feature>` with `.provider` and `.model`, `.usage.period`, `.notice.close` |

A region or a row is made an element of its own before it is named (`identifiedGroup`, in
`AccessibilityTree.swift`), because an identifier on a stack that is not an element is given to
every element inside it, over their own. That adds a group to the tree and draws nothing. A
pop-up's identifier is on both of its elements, the value and the chevron, and `press` takes the
first. An accessibility press does not reach a tap gesture, so a row clicked through one (a
sidebar band, bookmark, hit or match, the out-of-range line, a Library channel, an EARLIER day, a
plan picker row, a tick on the rail) is also an accessibility button whose action is the tap's own
closure (`pressableGroup`, `pressable`): VoiceOver and `press` activate it as a click does.
Popovers are in the main window's tree, under the element that opened them; the Settings window
is `ax` with `window: settings`.

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
rule and write order, the session's state machines, the decoders, the ULID, the error mapping.
`make app-e2e` is the façade against the
product: it builds `leylined`, generates the fixtures, and `LeylineClientDaemonTests` starts a
`leylined --no-hardware` on a temp socket with `nfm_tone.cf32` attached as a looping file
device. The suite covers the app's guarantees, one test each: a second client's capture and channel
reach the mirror and its tombstone leaves it; a burst of offsets in one tick becomes one confirmed
value and an out-of-capture
offset comes back as a `WriteRejected` with its tag; an FFT subscription's rows decode against
the answered descriptor with the fixture's tone in the upper half of the row; a daemon error
keeps its code; a socket with no listener is `UNAVAILABLE` and the mirror keeps trying; and on
`nfm_keyed.cf32`, the window's record job rides the window's capture, so a move off it asks and
one inside does not, writes a manifest the façade reads, whose newest part holds the newest
transmission heard live and flags the waterfall row inside it, and the finished recording
deletes. `AISettingsDaemonTests` starts its daemon with `--data` in the test's own directory and
`--ley` naming a script that accepts the test's key as the check worker, so no key reaches the
keychain: a key added reaches the mirror as its last four characters and never its text, and
leaves it when removed; a feature's model round trips; usage reported over the socket folds into
the pane's day and month rows. `AssistantDaemonTests` names as `--ley` a script that runs the
engine's `leyline-fake-worker` (built beside `leylined`) on a script of its own, and drives
`AssistantController` through a refused start, a message with a tool step, a question allowed, a
`show_band` call, then `select_recording` and `show_place` in one turn, each answered by a test
performer, Stop and End; its second case writes the squelch
as a client labelled `assistant` and reads the inspector's note from the app's mirror; its
third has that client make a kept channel on the app's capture, and the follow rule takes it,
the app's own channel ends, the note says "tuned to", a sink on the other client's channel is
refused for no reason but the host's audio, and the channel's end hands the window its last
copy. That test drives the fold and the held ids by hand, as `AppSession` would, because
`AppSession` does not compile on Linux.

A bare `swift test` in `app/` runs the daemon suite too and skips it silently without
`LEYLINED_BIN`, which is why the Makefile names the suites: `app-test` skips it, `app-e2e` is
the only place it runs. Same rule as `go/internal/e2e`.

A view's tests, when views have behaviour worth testing, go against the same daemon: the
harness in `Tests/LeylineClientDaemonTests/DaemonHarness.swift` is the one to reuse, and a
fixture stands in for the radio. Nothing in the app's suites may need hardware.

## Rules for new work

- **Every contract addition ships with its `ley` mirror.** A field the app reads that `ley
  --json` cannot show is not done.
- **The daemon is authoritative.** A view renders the mirror and previews its own writes until
  the event confirms them. No cached "my frequency" beside the daemon's.
- **Signposts cover the render path from the first row.** Antenna-to-pixel latency uses
  `os_signpost` at both ends; a waterfall without them cannot be measured later without being
  rewritten.
- **Colours and type come from `Theme.swift`** and nowhere else, so a design change is one
  file's worth of edits. The tokens and the six-stop ramp are listed under "Palette and type"
  above; `cli-style.md` shares hue order with the ramp and nothing else.
- **The band table is Go's; the app reads a generated copy.** `bands.json` under
  `LeylineClient/Resources` is `ley bands --json` checked in, `make bands-json` regenerates it
  and a Go test fails when the two drift. Never edit it by hand, and never add a band in Swift.
- **The app and `ley` share the bookmarks file.** `bookmarks.json` beside `labels.json`, the shape in
  `../design/channels.md`, "Bands and bookmarks are files": `{name, hz, mode, bandwidth_hz,
  updated_ns}` per entry, plus `tone`, `note`, `tags`, `offset_hz` and `duplex` on the entries
  that have them, and any key a client does not know kept as it was read. The app and `ley
  bookmarks` read and write the same file, a bookmark that only one of them can see is a bug, and a
  tone is validated by the same rule in both (`leyline.ParseTone`, `Tone.parse`), refused with the
  same sentence.
- **Prose in the window follows `../writing-guide.md`**: the daemon, a radio, a capture, a
  channel; "the daemon is not running" and what to type, never a spinner with no words.
