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
| `LeylineClient` | the client façade: identity, the connection, the state mirror, the write coalescer, the stream decoders, errors; the bands seed file and the bookmarks store (`Bands.swift`, `Bookmarks.swift`); the folds over rows that `ley` already applies (`SpectrumFold.swift`: median floor, the peak rule, the auto squelch, max hold); the named failure states (`FailureState.swift`); the transmissions log and the sample clock (`Transmissions.swift`, `SampleClock.swift`) | macOS and Linux |
| `LeylineApp` | the SwiftUI app: `AppSession` (the mirror copied, the selection, every action), the feeds (`SpectrumFeed`; `ChannelTelemetryFeed`, the tuned channel's meter, squelch edges and tones), the M1 views (sidebar, band rail, spectrum, the Metal waterfall with its shader as source, the mouse both charts share in `ChartMouse.swift`, transport bar, device menu), the M2 inspector (`InspectorView.swift`, `InspectorGroups.swift`), `Theme.swift` | macOS only; the manifest declares it under `#if os(macOS)` |
| `LeylineClientTests` | the façade's rules without a daemon: the fold, the coalescer, the decoders, the bands and bookmarks files, the spectrum folds, the transmissions log and the clock | both |
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
fold is `ley`'s (`go/internal/cli/session.go`): replace by id, because every event carries the
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
as DB_F32 does not look obviously wrong). The client-side buffer keeps the newest few frames, which
is the plane's own latest-wins policy: a renderer that falls behind skips to the newest frame.
`BulkDecode`
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
`ley tune`'s (`go/internal/cli/transmission.go`, `subaudible.go`): a close edge with no duration
is ignored, the CTCSS tone reported while a transmission ran stays with it, the 1 Hz heartbeat
that repeats a tone is not a new one, and a measurement between two standard tones is not reported
as a tone. `onAir` is the open transmission and `timeOnAir(at:)` its length at a `SampleTime`, so the
view asks with the newest time it has rather than a clock of its own. `SampleClock` is the Swift
mirror of `leyline.AnchorWallTime` and `RecordWallTime`: a `SampleTime` becomes a `Date` through
a dated `CaptureAnchor` on the same capture that applies from a sample not past it, drift
applied as the anchor states it, and nil otherwise (a capture's anchor has host time 0 until its
first block), because without an anchor the daemon has no wall-clock time to give (invariant 5). The
mirror keeps each capture's newest anchor on the capture, and the daemon-backed test folds
`nfm_keyed.cf32` into transmissions as long as the fixture keyed them.

**Failure states** (`FailureState.swift`). Problems the radio's numbers show, stated in words
rather than left as a dark waterfall (`../plans/user-stories.md`, V1a): the radio clipping, read from
the daemon's `CaptureLevel` (samples at the converter's rails, one in ten thousand raises it, half
that clears it; `CaptureLevelFeed` subscribes it per capture), with the gain as the suggested fix
(on auto, take it by hand; at the lowest manual gain, move the antenna). A measured fact
with its number and one action; not a detector (invariant 12). `ley tune` reports the same state
from the same count (`go/internal/cli/failure.go`), and also warns once, at tune, when nothing
on the band is 15 dB above the floor. The window showed that warning too until 2026-09-21. It
was removed because repeating it every few seconds on a quiet band distracted more than it helped.
The daemon
not running, no radio and an unplugged radio are the mirror's states and live in
`AppSession.emptyWords`. The session re-evaluates the state on every level reading and every mirror
change, logs each change, and the inspector's Region 2 shows it until the count clears or the
user closes it (a closed state stays closed until a different one is raised). A channel the
capture no longer covers (`OUT_OF_CAPTURE`: another client narrowed or moved the capture) is
reported the same way from the mirror, with the width and centre it would need; the window's own
rate change never causes it, because `AppSession.setSampleRate` re-places the centre for the
tuned frequency at the new width and writes centre and rate in one tick.

**The inspector** (`InspectorView.swift`, `InspectorGroups.swift`; the design is
`../design/app-design-handoff-m2.md`). The panel on the window's right describes the tuned signal
in words, and every word is a presentation of a number the daemon measured: signal from
`AppSession.overNoiseDB` through `SignalWord`, tuning and deviation from the meter's
`freq_error_hz` and `deviation_hz` through `TuningWord` and `DeviationWord` (`Reading.swift`,
where the thresholds live and are tested), time on air and the log of recent transmissions from
`ChannelTelemetryFeed`, which subscribes one channel's meter, squelch edges and sub-audible
reports and folds the last two into the façade's `TransmissionLog`. The number is one click away
under each word, and a row whose measurement is NaN is hidden rather than dashed. Wall clock in
the log comes through `SampleClock` from the capture's anchor and is relative otherwise. The panel
keeps no state of its own; its one write is a bookmark's name, through `BookmarkStore`. The
failure strip reads here since M2, and the transport bar's signal readout left when the panel
arrived, the M1 handoff's one named exception to "nothing moves".

## Building and running

On the Mac (Xcode 26, the same as the engine):

```sh
make app          # swift build in app/: the façade and the app
make app-run      # the window, straight from the package: no bundle, no signature
make app-bundle   # app/dist/Leyline.app, ad-hoc signed; --with-daemon via BUNDLE_ARGS
open app/Package.swift   # or: Xcode, with previews; Product > Run runs LeylineApp
```

`make app-run` runs the bare executable, which SwiftUI accepts (a window, the menu bar, the
process name in the Dock). The bundle adds `Info.plist` (identifier `com.leyline.app`, the
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
the FFT subscription's descriptor and a row count every thirty seconds, whether the shader
compiled, the inspector shown or hidden, and every bookmark added, renamed or removed. The line goes to the file, to stderr and to the unified log under `com.leyline.app`.
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
keeps its code; a socket with no listener is `UNAVAILABLE` and the mirror keeps trying.

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
- **Colours and type come from `Theme.swift`** and nowhere else, so the design handoff is one
  file's worth of edits. The tokens and the six-stop ramp are the handoff's
  (`../design/app-design-handoff.md`, "Palette"); `cli-style.md` shares hue order with it and
  nothing else.
- **The band table is Go's; the app reads a generated copy.** `bands.json` under
  `LeylineClient/Resources` is `ley bands --json` checked in, `make bands-json` regenerates it
  and a Go test fails when the two drift. Never edit it by hand, and never add a band in Swift.
- **Bookmarks are a file both clients own.** `bookmarks.json` beside `labels.json`, the shape in
  the handoff ("Bands and bookmarks are files"); the app and `ley bookmarks` read and write the
  same file, and a bookmark that only one of them can see is a bug.
- **Prose in the window follows `../writing-guide.md`**: the daemon, a radio, a capture, a
  channel; "the daemon is not running" and what to type, never a spinner with no words.
