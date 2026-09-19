# Swift style guide

How Leyline's Swift is written: what a file looks like, what things are called, where state
lives, and which mistakes this codebase has already made and paid for. It covers the engine
package, the app package and the tests around both. Read it before writing Swift anywhere in the
repository, and read section 12 first if you are working from the Linux container, because most
of the Swift you will touch there is never compiled before you hand the work over.

Four things are not here because they have their own page. Prose — comments and log lines
included — follows [`../writing-guide.md`](../writing-guide.md). The engine's threads, hot path
and daemon lifecycle are [`engine-internals.md`](engine-internals.md), "Hot-path rules (invariant
4, enforced)" and after; nothing here relaxes them. Anything a `ley` user sees is
[`cli-style.md`](cli-style.md). The app's module map, what the façade promises and how to build
it are [`app.md`](app.md); this page is how the Swift inside it is written, not what it does.

## 1. The short list

Ten rules where a violation is a bug rather than a preference. Everything after this section is
judgement, and says "prefer".

1. **Every Swift file opens with its SPDX line.** `engine/` is GPL-3.0-or-later and everything
   else Apache-2.0, decided by path in `scripts/check-licenses.sh`, and `make license-check`
   fails the build without the line.
2. **The app never imports `EngineCore`, `CRTLSDR` or `LeylineDaemon`.** The licence boundary is
   a directory boundary (`../decisions/D2-licensing.md`); `app/Package.swift:14` says why and
   `make license-check` refuses the import.
3. **Generated code is never hand-edited** (CLAUDE.md, invariant 13). `swift/LeylineProto` comes
   from `make proto` and `app/Sources/LeylineClient/Resources/bands.json` from `make bands-json`;
   a Go test fails when the band table drifts.
4. **No view owns radio truth** (invariant 7). A view renders `AppSession`'s copy of the mirror
   and previews its own write until the event confirms it. There is no "my frequency" kept beside
   the daemon's.
5. **Every wait has a deadline.** A write the daemon never confirms and an id no event carries
   both happen; each wait names the seconds it gives up after
   (`app/Sources/LeylineApp/AppSession.swift:350`, `:902`).
6. **Colours, fonts and fixed dimensions come from `Theme`.** No `Color(red:)`, no
   `.font(.system(size:))` on text (an SF Symbol's glyph size is the one inline size allowed),
   no system or white colours: the window owns a dark ground, and the handoff is meant to be
   one file's worth of edits.
7. **Only `Sendable` values cross into `MainActor.assumeIsolated`.** An `NSEvent` is not
   `Sendable`; the scalars it yields are, and are extracted first
   (`app/Sources/LeylineApp/TransportBarView.swift:308`).
8. **`@unchecked Sendable` carries a comment naming what makes it safe.** There is one in the
   tree, `AppLog`, and the comment on its writes names the lock
   (`app/Sources/LeylineApp/AppLog.swift:12`, `:60`).
9. **A negative or non-finite number is never converted blind.** `UInt64(someInt64)` traps below
   zero and `Int(Double.nan)` is fatal (`app/Sources/LeylineClient/DaemonMirror.swift:148`,
   `app/Sources/LeylineApp/Theme.swift:64`).
10. **Every contract addition ships with its `ley` mirror** (CLAUDE.md, Conventions). A field the
    app reads that `ley --json` cannot show is not done.

## 2. Files

**A file opens with SPDX, a blank line, then a `//` block that says what it is and why it
exists**, citing the document that owns its rules by path and heading. The what is one clause;
the why earns the lines. `app/Sources/LeylineClient/DaemonMirror.swift:3` is the model: the
fold's whole rationale — invariants 6 and 7, the tombstone rule, the seq-gap rule — before a
single declaration. `WaterfallShader.swift:3` and `Streams.swift:3` are the same shape for a
shader and a decoder, and `app/Package.swift:3` proves it holds for a manifest.

**One concern per file, and the leading comment is the test.** If the comment needs two
paragraphs about two unrelated things, the file is two files. `Theme.swift` holds colours,
`Theme.Font`, `Theme.Layout`, `SectionHeader` and `Color(hex:)`; `Frequency` moved to its own
file and `Comparable.clamped(to:)` to `Scale.swift` on 2026-09-19.

**Doc comments are `///`.** Never `/** */`, never a block comment where a doc comment belongs.

**Formatting is swift-format's, pinned in `app/.swift-format`**: the toolchain's defaults with
four-space indentation and 100 columns, adopted 2026-09-19 in one commit of its own. `make
app-format` rewrites the app package in place and `make app-lint` only reports; run the first
before a commit that touches Swift there, so a review diff is the change and not the formatter's
opinion of it. The engine package is not formatted yet: its diff would be large and its
Accelerate half cannot be compiled here, so that is its own commit on a Mac. Do not reformat
by hand as part of a feature change either way, because the diff buries the change inside it.

## 3. Naming

The base is the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
clarity at the point of use over brevity at the declaration, omit words that only restate the
type, booleans read as assertions. On top of that, this project's own:

- **Types are nouns, and an enum with no cases is the namespace for pure functions.**
  `SpectrumFold`, `Bands`, `BulkDecode`, `Frequency`, `SocketPath` and `WaterfallShader` are all
  caseless enums holding static functions, which is how the façade says "this has no state".
- **Three verb families, each meaning exactly one thing.** `ensureX` creates the thing if it is
  absent, writes it if it is present, and returns it (`AppSession.swift:473`, `:503`, `:532`).
  `followX` subscribes and resubscribes when the thing it follows changes
  (`app/Sources/LeylineApp/SpectrumFeed.swift:103`, `AppSession.swift:828`). `setX` is one
  coalesced parameter write and nothing else (`AppSession.swift:917` through `:979`). A function
  that does something else takes a different verb, because these three are read as promises.
- **A unit is part of the name, never a comment.** `centerHz`, `offsetHz`, `bandwidthHz`,
  `stepHz`, `peakDecayDBPerRow`, `updatedNs`. A bare `frequency`, `width` or `rate` is a review
  comment: the contract has several of each and they are not interchangeable.
- **Decibels are `DB`, except where the name mirrors a proto field.** `floorDB`, `medianDB`,
  `peakAboveFloorDB`, `rampRangeDB` are the spelling to use. `squelchDb`, `powerDbfs` and
  `WriteCoalescer.squelchDb` keep the generated spelling of `squelch_db` and `power_dbfs`,
  because a name that shadows a wire field should be greppable from either side. Names that
  mirror nothing and are lower-cased anyway are in section 13.
- **Ids are `String`s carrying their prefix** (`cap_`, `chan_`, `app_`), spelled as the generated
  message spells them: `captureID`, `channelID`, `deviceID`, `sinkID`. A type that holds two ids
  never calls either of them `id`.
- **Do not abbreviate anything the documents spell out.** The writing guide's word table is the
  naming table: a capture is not a session, a row is not a frame, a peak is not a signal. Locals
  in a short body may shorten to what the surrounding line already names (`cap`, `ch`, `geo`);
  stored properties, parameters and anything `public` spell the word out.

## 4. Comments

**A comment says why; the code says what** (`../writing-guide.md`, "Commit messages and
comments"). The leading file comment is the largest instance of this rule, and the same applies
to a three-line note over a guard.

**Doc comments are whole sentences in the writing guide's voice**, the rule and its reason in one
breath. `SpectrumFold.swift:19` is the shape: the 15 dB constant, why it is 15, and the Go
function it mirrors. There are no `- Parameter` blocks anywhere in `app/`; a parameter that needs
explaining is explained in the sentence.

**No bullet fragments.** A comment that wants a list of four things wants four sentences or a
table in the doc it should be citing instead.

**A number in a comment says where it came from** — a fixture, a measurement, the Go function
that already decided it — because a number without a source is a guess (`../writing-guide.md`,
"Voice"). `SpectrumFeed.swift:57` onward names every threshold as a documented `static let`.

**A rule decided on a date or in a document cites both**, as `cli-style.md`'s ramp stops do —
especially a finding that only the Mac could have produced, which the container cannot
rediscover.

**A comment changes in the same commit as the code it describes.** A comment promising behaviour
the code does not have is a bug, and the v1 review found several.

## 5. State and data flow in the app

**The session is a `@MainActor @Observable final class` whose stored state is `private(set)`.**
`AppSession.swift:15` declares all three; every mutation is a method on the same class, so there
is one place to read to learn how a value can change. A view that needs to write takes a binding
the session exposes deliberately (`AppSession.swift:81`).

**The mirror is copied, not shared.** `DaemonMirror` is `@MainActor`, imports no UI framework,
and publishes through `onChange`; `AppSession.mirrorChanged` copies `state` and `connection` out
of it, so a view holds one render's value and the façade still serves the Linux tests, where
Observation does not link into a test bundle. This is invariant 7 in code, and `app.md`, "The
façade" carries the rest of the reasoning.

**Views hold ids; objects are read back from `state`** through the derived lookups at
`AppSession.swift:101`. An object held across a render is a stale copy, because the fold replaces
whole objects by id on every event (invariant 6).

**Presentation-only state is allowed and lives on the session**, clearly not from the daemon:
max hold, zoom, the pointer frequency, which sheet is up (`AppSession.swift:81`). A view's own
`@State` is for what is transient to that view alone — hover, an in-progress edit — and is always
`private`. Anything two views agree about is the session's.

**A view previews its own write and reconciles on the event.** `requestedHz`
(`AppSession.swift:52`) is what the field shows until the daemon confirms the tune, so two quick
presses do not both start from the frequency before the first; `request(_:)`
(`AppSession.swift:350`) arms the clock that clears it. The write itself is never treated as
done.

**The response arrives before the event, so hold what the RPC returned.** A capture or channel
this app just made is kept beside the mirror until the mirror carries it, and an id is dropped
only once the mirror *had* it and lost it — a "seen" flag, because an id never seen and an id
deleted look identical otherwise (`AppSession.swift:34`, `:248`).

**Every wait has a deadline, and the deadline is in the doc comment.** An id never seen is
released after three seconds, `requestedHz` expires after two, a busy device gets two, the auto
squelch gives up after three and leaves the squelch off. `confirmed(within:_:)`
(`AppSession.swift:902`) is the one helper; use it rather than a bare sleep.

**One move in flight at a time.** A second centre move waits in `nextRetune`
(`AppSession.swift:63`, `:648`) rather than racing the first, because two at once leave the
coalescer holding the last centre and the first offset written against a centre that never
applied. A drag is rate-limited the same way: at most an eighth of a span every 300 ms.

**All writes go through `WriteCoalescer`**, which keeps the last value per
`(target, parameter)` and flushes one tick later, so a drag's frame of writes is one message
(`app/Sources/LeylineClient/WriteCoalescer.swift:96`). It returns the write's tag, which a
`WriteRejected` event echoes: that is how a refusal reaches the control that caused it.

## 6. Concurrency and isolation

The app package builds in Swift 6 language mode (`app/Package.swift:81`); the engine is still
`.v5`, where an isolation mistake is a warning rather than an error (`setup.md`). Do not lean on
the engine's build to catch one.

**`View` is `@MainActor @preconcurrency`** in Apple's own declaration, so everything in a view is
main-actor isolated by inference. Anything inside a view that must not run on the main actor has
to say so explicitly; nothing in the app currently needs to.

**`nonisolated` states what is already true, and only that.** A constant any context reads is
`nonisolated` (`SpectrumFeed.swift:57`, read by `Rows.columns(width:)` off the actor); the pure
folds in `LeylineClient` are free functions on caseless enums and need no isolation at all; a
protocol method AppKit calls off the actor is `nonisolated` and hops back
(`app/Sources/LeylineApp/WaterfallView.swift:278`).

**`MainActor.assumeIsolated` is the bridge from a callback already on the main thread**, and it
appears exactly three times: a `DispatchSource` on `.main`, an `NSEvent` monitor, and
`MTKViewDelegate.draw(in:)`. If you cannot say in one sentence why the callback is on the main
thread, it is not, and `assumeIsolated` will trap.

**Task capture follows the task's lifetime.** A fire-and-forget write inside a `@MainActor`
method captures `self` strongly and inherits the actor; the cycle ends when the round trip does
(`AppSession.swift:1051`). Anything that outlives the call — a subscription, an expiry clock, the
mirror's callback — takes `[weak self]` (`SpectrumFeed.swift:116`, `AppSession.swift:353`).
Inside an `actor`, `Task {}` inherits that actor's isolation, which is why
`WriteCoalescer.start()` calls back into itself without an `await`.

**A `Task` that owns a stream is paired with `continuation.onTermination`** so ending the
consumer cancels the RPC (`app/Sources/LeylineClient/DaemonConnection.swift:133`,
`Streams.swift:146`). A stream left running after its reader is gone is a channel the daemon
keeps alive for nobody.

**Express what is true now; resist refactoring.** The Swift migration guide's own rule, and the
one most at odds with how an agent behaves under an isolation warning: add the isolation the code
already has — usually one `@MainActor` or one `nonisolated` — rather than restructuring the type.
Making a payload `Sendable` to silence a warning about a function that immediately hops to the
main actor fixes the wrong thing. `nonisolated(unsafe)` is the last resort, after `let` and after
actor restriction, and needs the comment rule 8 asks for.

## 7. SwiftUI and layout

These are the facts the compiler cannot catch, each one paid for by a fix commit.

**Read observable state in `body`; hand a closure a value.** Reads inside a `Canvas` drawing
closure are not tracked by Observation, so a canvas that reached into the session drew the old
band until the next row happened to arrive. `SpectrumView.swift:22` reads everything in `body`
and passes one `Rows` struct (`:72`) to `draw`. The same holds for a `GeometryReader` child and
for any escaping closure that renders.

**`@Bindable var session = session` at the top of a `body`** is how a binding is taken from an
`@Environment(AppSession.self)` object (`SpectrumView.swift:202`).

**`.offset` does not contribute to layout.** A `ZStack` whose children are positioned by offset
must be framed `alignment: .topLeading`, or the frame centres whatever is left and the content
lands somewhere else entirely (`app/Sources/LeylineApp/BandRailView.swift:154`).

**Overlay first, offset second.** An `.overlay` added after `.offset` is placed on the un-shifted
frame (`app/Sources/LeylineApp/ChartMouse.swift:179`).

**`GeometryReader` only where the size is an input to something.** The charts need the pixel
width to map frequency to a column, so they use one; a layout that only wants to fill its parent
does not.

**`Canvas` draws the traces**, and a trace is a line, not a filled area — the same rule
`cli-style.md`, "Layout rules" states for the terminal, for the same reason: filling under a
flat noise floor makes a mass with no shape.

**Colour and type come from `Theme` only**, using the handoff's tokens
(`../design/app-design-handoff.md`, "Palette"). A line between two panels is `Theme.border`; a
divider inside a panel is `Theme.hairline`. A control takes the token the handoff names for it,
not the nearest-looking one.

Prefer a separate `View` struct over a computed property when the extracted piece has
dependencies of its own, so it becomes its own invalidation boundary.

## 8. AppKit and Metal

**`NSViewRepresentable` follows the pattern in `ChartMouse.swift`:** SwiftUI owns the frame and
the representable never sets one, the coordinator carries events back out, and nothing expensive
happens in the struct's `init`, which runs on every parent body pass. Prefer native SwiftUI
until the capability only exists in AppKit; each bridge is one file.

**A hosted AppKit view draws over its SwiftUI neighbours**, so anything that must sit on top of
it is drawn inside it. The seam between spectrum and waterfall is a rectangle inside the
waterfall, over the Metal view (`WaterfallView.swift:42`).

**The shader is Swift source compiled at launch**, not a `.metal` resource: `swift build` does
not produce a `default.metallib` the way Xcode does, and a shader that silently fails to load is
a dark panel with no words. A compile failure is a sentence in the window
(`WaterfallShader.swift:3`, `WaterfallView.swift:243`).

**Uniforms are scalars.** Pack what the shader needs as plain numbers in one struct, so nothing
whose memory layout has to be guessed crosses that boundary.

## 9. Numbers

**Frequencies are `UInt64` Hz, as the contract spells them.** Arithmetic that can go negative is
done in `Int64` and converted back only behind a `>= 0` guard: a channel below 0 Hz is not a
frequency and is reported absent rather than trapping the render that reads it
(`DaemonMirror.swift:148`).

**Guard `isFinite` before `Int(...)`, and clamp before a `UInt` conversion.** `Double.clamped`
keeps NaN and `Int(Double.nan)` is fatal, so a measured value is checked first (`Theme.swift:64`).

**A threshold is a named constant beside the feed that uses it, with a doc comment saying why it
is that number** (`SpectrumFeed.swift:57` onward). Never write the same number twice: a string in
the UI that quotes a threshold reads the constant.

## 10. Foundation on two platforms

**An atomic file write is `write(to: tmp, options: .atomic)` then `rename(2)`.**
`FileManager.replaceItemAt` unlinks the original first, so a failure there loses the file the
temp was meant to protect; `go/pkg/bookmarks` does the same thing with `os.Rename`, and the two
clients own the same file (`app/Sources/LeylineClient/Bookmarks.swift:163`).

**Anything under `#if canImport(Accelerate)`, `#if canImport(AppKit)` or `#if os(macOS)` is never
compiled on Linux.** A vDSP kernel needs its portable twin and a row in `KernelParityTests`, or
it is untested here and unverified there (`setup.md`, and the same trap `app.md`, "Building and
running" records for views).

**Xcode's type checker is stricter than the Linux one.** A four-term shift chain the container
accepted was refused on the Mac; one `loadUnaligned` per sample is the idiom both decoders use
(`Streams.swift:51`). Expect the Mac to reject expressions the container compiled, and write the
simpler form first.

**When Swift and Go both read a file or decode a payload, they take the same shape**, because
they are tested against each other (`BulkDecode` against `go/pkg/leyline/bulk.go`).

## 11. Tests

**New tests are XCTest, and their names are claims in sentences.**
`testTombstoneRemovesAndDetachedStays`, `testMalformedFileIsNeverWrittenOver`,
`testFFTRowsDecodeAgainstTheAnsweredDescriptor`: the name is the promise, so a failure names the
broken promise. All 46 cases in `app/Tests` are XCTest. Swift Testing is in the toolchain and
unused; keep one framework until there is a reason to move all of them, because a `@Test` in an
XCTest target reports its own zero-test line that nobody reads.

**Logic that can live in `LeylineClient` lives there.** That target is the only Swift in the app
package Linux compiles, so a rule tested there is a rule the container can prove: the fold, the
coalescer's last-value rule, the decoders, the bands and bookmarks files, the spectrum folds.

**A change ships with its test where one is possible.** `make app-test` is the façade alone;
`make app-e2e` is the façade against a real `leylined --no-hardware` with a fixture as the radio,
and its suite skips itself without `LEYLINED_BIN`. A view's behaviour, when it has any worth
testing, goes against that same harness (`app.md`, "Testing").

## 12. Working as an agent on this repository

**The container builds and tests the façade, and nothing else of the app.**
`cd app && swift build` builds `LeylineClient` only, because `app/Package.swift:55` declares
`LeylineApp` inside `#if os(macOS)`. `make app-test` runs the façade's 41 cases in about a
quarter of a second; `make app-e2e` runs its five here too, given `LEYLINED_BIN`, fixtures and an
`LD_LIBRARY_PATH` that includes the stub `librtlsdr` (`setup.md`).

**Only the Mac catches the rest.** Every file in `app/Sources/LeylineApp` — the SwiftUI, AppKit,
MetalKit, CoreAudio and `os` imports — is untouched by a green Linux run. So are the engine's
Accelerate kernels, the engine's actor-isolation mistakes while it stays in Swift 5 mode, Xcode's
stricter type checker, shader compilation and texture formats, and every layout and interaction
fact in section 7.

**Before handing over, read the diff by eye for the five things the compiler would have caught.**
Is every `static let` that a value type or an off-actor closure reads marked `nonisolated`? After
extracting a helper, does every identifier still resolve — a body moved into a new function kept
a `press.key` that no longer existed? Does every `guard let` binding get used? Is every
`UInt`/`Int` conversion of a value that can be negative or NaN guarded? Does anything crossing an
AppKit closure carry only `Sendable` values? Then check the layout rules: offset against frame
alignment, overlay before offset, and what a hosted view covers.

**Say what was not compiled.** Name the files and the behaviours that are unverified — layout,
gestures, the shader — in the hand-off message and in the commit body. The repo's own follow-up
fixes ("from the Mac", "the first run on the Mac") are what happens when that is left unsaid.

**Small diffs, and only the change that was asked for.** No speculative abstraction: a layer
added for a use that has not arrived is a cost the next reader pays for nothing. No reformatting
drive-by, for the reason section 2 gives, and a refactor nobody asked for is its own commit.

**Do not fix what you did not break.** `make license-check` is currently red on main for eight Go
dependency rows the MCP adapter added; that is not a Swift change's business, and repairing it
inside an unrelated diff hides both. Flag it and move on.

Commit subjects, bodies and sign-off are in CLAUDE.md and `../writing-guide.md`, "Commit messages
and comments", not here.

## 13. To fix

Recorded so they are pending rather than forgotten. None of these is urgent; each is a small
commit of its own. The rest of this section's findings were landed on 2026-09-19: frequency
formatting, `Frequency.parse`, `Theme.swift`'s concerns, the dB suffix, the three inline font
sizes and `AppSession`'s inlined numbers.

- **Two of the four affine maps remain separate.** `SquelchTrack` and `GainSlider` mapped a
  clamped `Double` both ways and now share `Scale.swift`. `SpectrumView`'s `Columns.x(of:)`/
  `hz(atX:)` and `BandRailView`'s `BandRail.x(of:)`/`hz(atX:)` map a `UInt64` frequency instead,
  do not clamp the forward direction, and `BandRail.hz(atX:)` snaps its result to the band
  afterward; folding them into `Scale` would mean adding a clamp neither one has today, which is
  a behaviour change and wants its own review, not a mechanical rename.
