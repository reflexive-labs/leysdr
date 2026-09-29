# Design: Bands, channels and bookmarks

Status: implemented 2026-09-29 as APP-9, from the plan
`../plans/2026-09-28-2037-feat-bands-channels-bookmarks-plan.md`; the `ley` side and the client
library are tested on Linux, the window's views are unverified on the Mac (`../plans/app.md`,
APP-9, "Unverified on the Mac"), and the audio-gone measurement below is still open. Companion to `app-design-handoff.md` ("Bands and bookmarks are files", which owns the seed
file and `bookmarks.json`), `scan.md` (which owns the sweep behind Scan band),
`decoders.md` (which owns the labels store this copies and the decoders a plan channel can name)
and `semantic-tier.md`. Work items are APP-9 in `../plans/app.md`; E.4 in
`../plans/build-order.md` is the milestone.

## The stories

> As a newcomer, I can pick a listening preset (FM Broadcast, NOAA Weather, Airband, 2m
> Repeaters, Marine VHF) and hear something real within seconds of first launch. (V1a)

> As a ham, I can import my CHIRP file and my radio's channel memories become named bookmarks and
> scan lists. (V1a)

> As an operator, I can bookmark a frequency with a name, and bookmarks appear in a sidebar I can
> click to jump. (V1a)

The third is built. The first two are what this document is for, and the question under both is
how the window organises everything a person can tune to without the sidebar becoming a list of a
hundred rows. A newcomer wants NOAA weather without knowing which of seven frequencies carries the
local transmitter, and GMRS channel 5 without knowing it is 462.6625 MHz. A ham arrives with a
CHIRP export of 120 memories and wants them where they belong, not in one column.

## Three kinds of frequency

The current window conflates three things that behave differently.

**A band is a range with defaults.** 2 m amateur is 144.000 MHz to 148.000 MHz, NFM, 12.5 kHz
wide, 5 kHz steps. The table lives in `go/pkg/leyline/bands.go`, reaches the app as `bands.json`,
and is drift-tested from Go (`TestBandsJSONResource`). Seventeen entries in frequency order.

**A plan channel is a public number inside a band.** WX3, GMRS 17, marine 16, CB 19. It is a fact
about the service, the same on every radio sold, and it is what a person means when they say
"channel 5". It is not user data. Today the plan channels Leyline knows are `ley`'s preset table
(`go/pkg/leyline/presets.go`): NOAA WX1 to WX7, GMRS 1 to 22 with the repeater aliases, marine 16,
the 2 m calling frequency and the aviation guard. `ley tune ch5` works and the app has no copy of
the table, so the window cannot do what the prompt can. Marine has one channel of its plan, CB has
none, and MURS is not in the band table at all.

**A bookmark is the user's own.** This repeater with its tone, that tower, the NOAA transmitter
that is actually audible from the house. `bookmarks.json` holds name, frequency, mode and width,
keyed by id, flat. No tone, no note, no grouping.

Keeping the second kind separate from the third is what keeps the sidebar short. A plan channel
never needs a row of its own: it is a tick on the band rail, an entry in the band's picker, a name
the window accepts where a frequency goes, and a label that appears beside any bookmark or tuned
frequency that lands on it. A bookmark is a row, and it sits under its band.

## Decisions for the app

### The plan is data in the band table

Each band gains a `channels` list: name, aliases, frequency, and a note. The `ley` preset table
becomes a view over the band table rather than a second table, so `ley tune ch5`, `ley monitor`'s
CHANNEL column, `ley scan`'s BAND cell and the app all read one source, and the drift test the seed
file already has covers the plans too. The shape, in `bands.json`:

```json
{
  "name": "NOAA weather",
  "aliases": ["noaa", "weather", "wx"],
  "min_hz": 162400000, "max_hz": 162550000,
  "mode": "nfm", "bandwidth_hz": 12500, "step_hz": 25000,
  "channels": [
    {"name": "WX1", "aliases": ["noaa1"], "hz": 162550000},
    {"name": "WX2", "aliases": ["noaa2"], "hz": 162400000, "note": ""}
  ]
}
```

A plan is a list, never `min_hz + n × step_hz`. CB's forty channels skip 20 kHz at five places
and number 23 to 25 out of frequency order; marine's duplex channels have a ship and a coast
frequency each; GMRS 8 to 14 sit in the 467 MHz half between the repeater inputs. A channel may
carry `mode` and `bandwidth_hz` where they differ from the band's (MURS 1 to 3 are 11.25 kHz
wide, 4 and 5 are 20 kHz), and `decoder` where the channel is a data channel the daemon has a
decoder for (APRS on 144.390 MHz, AIS on marine 87B and 88B, SAME under every NOAA channel), so
that tuning it can offer the decoder. A group's plan hangs off the group, because GMRS numbering
spans both halves.

A channel's `name` is what the service's radios print: `WX3`, `16`, `19`, `1`; GMRS keeps `ch17`
and its repeater aliases, because scripts and the MCP tool descriptions already use them. Every
entry also carries a plan-prefixed alias (`marine16`, `cb19`, `murs1`, `gmrs17`, `wx3`), and that
form is what resolves globally: at the prompt, in MCP, and in the CHANNEL column `presetAt`
fills. A bare numeric name resolves only in band context, the tuned band in the app and `--band`
at the prompt, so `16` is never ambiguous and never a frequency. Marine's duplex pairs are two
entries named `24` (ship) and `24 coast`, so one plan never holds two entries with one name.

MURS is defined as GMRS is: `MURS 151 MHz` (151.820 MHz to 151.940 MHz, padded half a channel)
and `MURS 154 MHz` (154.570 MHz to 154.600 MHz), with a `murs` group carrying the five-channel
plan. One band from 151.820 MHz to 154.600 MHz would label the 2.6 MHz of business, itinerant
and public-safety spectrum between the two clusters as MURS, centre the band view at 153.2 MHz
where no channel is, and have Scan band report hits under MURS that no channel names.

The plans in the alpha table, all from the public allocations, each to be checked against the
FCC or ITU listing when the table is written:

| band | plan | count |
|---|---|---|
| NOAA weather | WX1 to WX7, as the preset table has them | 7 |
| GMRS (the group) | 1 to 22, the repeater aliases RPT1 to RPT8, 15RP to 22RP and 23 to 30 kept; FRS is an alias of the group, the plan being the same | 22 |
| MURS (the group; two new bands, 151 MHz and 154 MHz) | 1 to 5 | 5 |
| marine VHF | the ITU channels with the US A and B variants; a duplex channel is two entries, ship and coast | about 100 |
| CB | 1 to 40 | 40 |
| 2 m amateur | calling 146.520, APRS 144.390 with `decoder: aprs` | 2 |
| airband | guard 121.500; the rest of the band is local, and unnumbered | 1 |
| 70 cm, 6 m, 1.25 m, the HF bands, FM broadcast, AM broadcast | none | 0 |

Repeater offsets (2 m ±600 kHz, 70 cm +5 MHz, GMRS +5 MHz) are notes on the entries for now; a
paired input frequency on a bookmark is a later feature and its file field is reserved below.

The table stays US and the page says so. PMR446, the European marine and airband channelisation
(8.33 kHz) and every other region are the content layer's business (`../plans/v1-release.md`,
R-22), which will ship them as packs into the same shape. Two amateur bands the table lacks and an
RTL-SDR reaches, 6 m and 1.25 m, are added with no plan.

### Bands are the spine of the sidebar

The sidebar is one list, ordered by frequency as it is now, because that is the order the band
rail's neighbours follow and the one a person who knows the spectrum expects. Each band row
expands to what is inside it; the rest is collapsed.

- **A band row** shows its name and mode as today, and a click on it tunes the band as today: a
  newcomer who clicks FM broadcast hears it, and FM broadcast has no plan and no bookmarks, so
  a click that only expanded the row would leave a sweep as the only way in. Expanded, the row
  shows its range line, then a compact action strip with `Scan band` and, where the band has a
  plan, `Channels…`. The raised, bordered controls distinguish actions from the bookmark rows
  below them. A sweep's progress or hits sit beneath the strip, followed by the bookmarks. The
  band the tuned frequency is in is the expanded one, following the rule that
  selection reflects state rather than causing it (`app-design-handoff.md`, "Decided
  2026-09-21: the sidebar"), so the click expands the row by tuning it; a disclosure chevron at
  the row's edge expands or collapses without tuning, for a ham looking through 70 cm while
  listening on 2 m, and a row opened that way closes on the next tune elsewhere. A band whose
  plan has 24 channels or fewer also draws them as faint ticks on the band rail; marine's
  hundred stay in the picker, because at 25 kHz spacing across 6 MHz the ticks would read as
  texture.
- **A group is one row.** The sidebar lists plain bands today (`Bands.plain`) and the band
  lookup never answers a group, so a plan that hangs off GMRS would have no row. A group
  replaces its parts in the sidebar: the `GMRS` row spans both halves, its picker lists 1 to 22,
  its bookmarks are those whose frequency lies in either half, Scan band sweeps the group, and
  picking a channel tunes through `select(band:at:)` on the half that contains it, which is what
  a neighbour crossing does already. The halves stay in the table for `ley`, for the rail, which
  keeps showing the half the capture is on and draws only the group's channels inside it, and
  for the band lookup; `Bands.plain` gains a sidebar-facing sibling that folds parts into their
  group. On the Go side `presetAt` and `ResolvePreset` walk the groups' plans as well as the
  bands'. That a pick in the other half moves the capture is to be seen on the Mac.
- **The plan picker** is a popover from the `Channels…` action, the shape the mode and width
  pop-ups use, sized to about twelve rows and scrolling past that. A row is the channel's name,
  its frequency, and its note in `inkTertiary` where there is one; the order is the plan's own,
  channel number first, so marine's ship and coast entries sit together. A filter field at the
  popover's top narrows the rows for the plans that need it (marine, CB), and the arrow keys and
  Return move and pick, so a channel is reached without the mouse: it opens with the tuned
  channel highlighted when the plan has it, else the first row; Up and Down move the highlight
  without wrapping; the filter puts it back on the first row; Return picks and Escape closes.
  A pick tunes and closes.
- **A bookmark row** sits under the band its frequency is in and keeps every affordance it has
  today: the dot, `changed`, the recording dot, the editor, the context menu. A bookmark on a
  plan channel shows the channel's name in the frequency's place (`ch17`, `WX3`), which is what
  `ley monitor` prints in its CHANNEL column, so the two clients agree on what a frequency is
  called. A bookmark in no band goes under a final `Other` header. Moving a bookmark with
  `Replace with …` moves the row to the new band, and the row is selected there, so the move is
  visible.
- **Out-of-range bands collapse to one line.** An RTL-SDR user sees seven HF rows they can
  never click. They become `7 bands below what this radio tunes`, one dim line at the top, which
  expands to the rows on click; `outside` when they lie on both sides of what the radio tunes.
  The line counts bands, not their bookmarks, which the filter still lists as disabled rows.
  The rule and its words already exist (`Bands.outOfRangeWords`).
- **A filter field at the top** flattens everything. Typing narrows the list to bands,
  bookmarks and plan channels whose name or alias matches, as one flat list with the band named
  on each row. A match is a case-insensitive prefix of a name or an alias, so `5` finds channel
  5 and not `ch15`. The order is the tuned band's matches first, then the sidebar's frequency
  order, a bookmark before a plan channel on one frequency; a band the radio cannot tune is
  listed disabled, with its bookmarks, and is never the Return target. This is the "all my
  bookmarks" view and the "where is ch16" view, and Return on the first row tunes it: a
  bookmark or plan channel to its frequency, a band as a click on its row would. When nothing
  matches, the list is replaced by one line, `No matches for "…"`, on the Library's pattern
  (`LibraryView.swift`, the search's empty line). Escape clears the field and drops its focus.
  The frequency field is a digit editor and stays one; a name goes in the filter, and `Go to…`
  (⌘G) in the Tune menu focuses it.
- **A new bookmark is named after the channel it sits on.** ⌘D, the inspector's pencil on an
  unnamed frequency, a scan hit's ＋ and a CHIRP row with no name all use one rule: the plan
  channel's name when the frequency is within 6 kHz of one, else the frequency. Both clients
  answer "which channel" the same way: the nearest within 6 kHz, the tolerance `presetAt` uses
  today, and two entries at equal distance resolve to the earlier in plan order, which marine's
  US variants make common (`22A` and `22` share 157.100 MHz), so a US variant is entered before
  the ITU entry that shares its frequency.
- **A name resolves inside the tuned band first, then globally.** `16` on marine is channel 16;
  `16` on GMRS is channel 16; `ch16` anywhere else is whichever plan has it, GMRS, and the row
  says so. A name two plans share and neither is tuned shows both matches.

The alternative, two sections as today with bookmarks grouped under band headers past about ten,
was considered and not taken: it keeps two places to look for what is at 462 MHz and a CHIRP
import is still every row at once. Lists (user-named sets such as Home or Boat, a CHIRP import
becoming one, scan lists falling out of them) are the ham story and are deferred, with the file
shape chosen so they can be added without a migration.

### Scan the band

The newcomer story is a scan for the services that are always on the air. NOAA is seven plan
channels of which one or two are audible from any given house; FM broadcast has no plan at all
and every station is local; marine's coast stations and weather are continuous. A one-shot
sweep finds only what is transmitting throughout its dwell (`scan.md`: what is sitting on the
band, not what keyed up during the sweep), so it does not serve the two intermittent presets in
the story, 2 m repeaters and airband, which key up for seconds an hour. In alpha those come from
bookmarks and CHIRP import; a band watched over time is the band-watching plan's occupancy
work. The band row's
context menu and the expanded row carry **Scan band**, which runs the sweep `ley scan --band`
runs (`ScanConfig{range: the band, once: true, take_over: true, device_id: the window's
capture's device}`; the device id is what makes the take-over take over the window's own radio
and not a second one a watch or another window is using) and puts the detections on the
rail as ticks with their SNR in the help text, strongest first in the expanded row for the
sweep's duration and until the next tune. One click on a hit tunes it; the plan channel nearest
within half a step names it, as `presetAt` names a detection in `ley scan`; `＋` on a hit makes
the bookmark, named after the channel when there is one. A NOAA newcomer therefore clicks the
band, clicks Scan band, and clicks the loudest row. A sweep that finds nothing replaces the
progress text with one line, `Nothing on the air right now; repeaters and towers key up
briefly`, and leaves the rail without hits; a previous sweep's hits stay until the next sweep
or the next tune elsewhere. A job that fails shows its status detail in `caution` where the
progress text was, and the channel is recreated regardless; a `covered` range narrower than the
band appends `ley scan`'s coverage note under the hits. Hits in the gap between a group's halves
are dropped, for the reason MURS is two halves, and the rail shows the tuned half's hits.

While a sweep runs, the rest of the window keeps its rules. A recording riding the window's
capture would hear every hop, so Scan band asks first, on the alert a band move over a
recording already shows, with Sweep anyway and Cancel. Any tune while the row reads `Sweeping…`
(a band, a bookmark, the rail, the waterfall, the filter, a pick) cancels the job and proceeds
once its terminal event has restored the centre; the row's item reads Stop meanwhile and does the
same; Scan band on another band cancels the first sweep and starts its own after the terminal
event. With no capture at all (after Stop listening) the job runs on the radio the window would
pick, the daemon opens and destroys its own capture, and the band is selected afterwards, as a
bookmark click after Stop listening selects one.

A sweep takes the radio. The allocator's policy (`scan.md`, "Don't-disturb") declines a capture
with a live sink or an interactive write in the last 60 s, and the window always has both, so the
window passes `take_over`. With it the allocator borrows the window's capture rather than opening
one (`SessionCaptureAllocator`, the reuse step): the capture keeps its id, is marked swept, is
retuned step by step under the window's channel, and on release is retuned to the centre it had
with its gain restored. Nothing is destroyed and no tombstone arrives, and while the capture is
swept every write to it is refused with `DEVICE_SWEEPING`. So the window owns the pause: before it
starts the job it detaches its sink and destroys its channel, the Stop listening path, keeps the
last tuned frequency as the display, and ignores the borrowed capture's centre events until the
job's terminal event; then, with the centre back, it recreates the channel and the sink through
the path a band select uses and re-applies the bookmark's or the band's settings. The row says
`Sweeping 2 m, 7 steps…` while it runs, from the job's `status_detail` (`step k/n, m found`),
and the transport bar's meter reads nothing, which is what is happening. The sweep of 144 MHz to
148 MHz at 2.4 MSPS is seven steps (`scan.md`, "Geometry") at 218 ms settling plus the dwell,
so a band sweep is a few seconds; a 20.5 MHz FM broadcast band is about five times that. The
row's progress is the job's, from the event stream, the way `ley scan` follows it.

Scan band is not a watch and does not repeat. A band being swept on a schedule is the
band-watching plan's occupancy work (`../plans/band-watching.md`), not this.

### Bookmarks gain three fields

Additive, in `bookmarks.json`, all optional, unknown keys preserved by both readers so an older
`ley` never strips a newer app's fields:

| field | holds | why now |
|---|---|---|
| `tone` | the tone the repeater requires on its input: a CTCSS tone in hertz or a DCS code as `D023N`, as CHIRP writes them | a repeater's tone is the first thing a ham writes beside its frequency; the inspector shows the tone heard on the air beside it, and never calls a difference a mismatch, because a repeater's output tone is not its input tone |
| `note` | free text | CHIRP's Comment column; where the offset and the club name go until offsets are fields |
| `tags` | a list of strings | the hook lists hang off later: a CHIRP import tags its rows with the file's name, and a later `Lists` section is a saved filter over tags |

`offset_hz` (signed, hertz) and `duplex` (`+`, `-`, `split`, `off`, as CHIRP spells them) are
written by the CHIRP import and read by nothing yet: recording a repeater's input as data is not
transmitting, and a sentence in `note` could not become a field later without parsing prose. The
inspector's identity region edits `tone` and `note` beside the name; `tags` are edited nowhere in
alpha and shown as words under the name when present. Neither client gates audio on `tone`: tone
squelch is the engine's separate decision (`control.proto`, `ChannelConfig`'s reserved field 13),
and a
bookmark's tone stays a record of what the repeater uses.

### CHIRP import

`File > Import CHIRP…` and `ley bookmarks import <file.csv>` read CHIRP's CSV export into the same
file. The mapping: `Name` to name, `Frequency` (MHz) to hz, `Mode` FM and NFM to NFM with the
width 25 kHz or 12.5 kHz, AM to AM, else the band's default; `tone` by the `Tone` column's mode:
`Tone` takes `rToneFreq`, `TSQL` takes `cToneFreq`, `DTCS` takes `DtcsCode` with the first letter
of `DtcsPolarity`, `Cross` takes the transmit side of `CrossMode`, and anything else leaves the
field unset; `Comment` to `note`; `Duplex` and `Offset` to the `duplex` and `offset_hz` fields;
the file's basename to a tag. A row whose frequency is already bookmarked under the same
name updates that bookmark; otherwise a new one. An update sets only the fields the row
carries: a blank column never clears a value typed in the inspector, and `tags` is a set the
basename joins once. A blank `Name` takes the naming rule above; a frequency rounds to whole
hertz; USB, LSB, CW and WFM map directly and any other mode falls to the band's default; a row
whose frequency does not parse is skipped and counted. The verb prints what it added, updated
and skipped, `--dry-run` prints the same without writing, and a file with no `Frequency`
header is refused with nothing written. The app shows the same counts as one notice and opens
no row. Both parsers, Go's and Swift's, are held to one fixture CSV and one expected bookmarks
file under `fixtures/chirp/`, the way the seed file is held to the band table. Nothing is
exported in alpha: `ley bookmarks --json` is the export.

Imported rows land under their bands, so 120 memories are 2 m and 70 cm rows collapsed until
opened, which is the reason the spine is bands.

### What is remembered where

- **The band table and its plans**: the Go table, `bands.json` in the app, drift-tested. Users
  never edit it; a pack replaces it later.
- **Bookmarks**: `bookmarks.json`, both clients, `ley bookmarks` the mirror.
- **Which bands the sidebar shows**: every band the table has, the out-of-range ones folded to
  their line. Nothing is remembered; a per-band choice is deferred below.

## The second pass: engine and CLI

Everything above is client-side by the build order's decision ("Bookmarks, presets, scan lists
and CHIRP import" are interpretation state), so the daemon changes not at all for alpha. The pass
is over what the CLI must mirror, what the contract already carries, and what the engine would be
asked for next.

### The daemon

- **No proto change.** Bands, plans and bookmarks stay client tables; the daemon never learns
  that 462.6625 MHz is channel 5, as it never learned a preset's name. D6 in the v1 plan asked
  whether bookmarks should be daemon state under invariant 7; the build order took the other
  answer, and this document does not reopen it. What would reopen it: a second machine wanting
  the same bookmarks, or an agent over MCP needing to write one. The MCP adapter runs in `ley`
  and reads the same file, so the agent case is covered without the daemon.
- **Scan band uses the scan job as it is.** `take_over` exists for exactly this, and the
  capture id survives the sweep: the allocator never destroys a capture it did not create, so the
  window's mirror sees the same capture retuned and restored, never a tombstone. One thing to
  measure before the item is ticked: how long the window's audio is gone for a 2 m sweep at
  2.4 MSPS on the owner's dongle, observable from the event stream, and the answer belongs in the
  plan item.
- **Tone squelch stays undecided.** A bookmark carrying a tone is the first client feature that
  would want the daemon to mute audio when the tone is absent. The proto comment on field 13
  says why it is not done: a missed tone mutes audio with no sign of why. The design for that is
  its own document, and the bookmark field costs nothing if it is never built.
- **Decoder on a plan channel is a client convenience** over `ley decode`'s existing job: tuning
  APRS offers `Start decoding` and starts the job on the window's channel. No engine work; the
  app-side item waits for the decoders plan's app surface.
- **The engine's own tables are untouched.** `DemodMode.defaultBandwidthHz` remains the one
  engine default the client tables mirror; a plan channel's width is a channel write like any
  other.

### The CLI

- **`ley presets` and `ley help presets` become views over the plans.** The order and wording of
  the goldens change: the table gains a BAND column and lists by band, the descriptions come from
  the plan entry's name and note. `ResolvePreset` walks the plans; `presetAt` walks them with
  the same half-step tolerance it has. The `ch1` to `ch22` names, `rptN`, `NNrp`, the Baofeng
  numbers, `noaa`, `wx1`, `calling`, `marine16` and `guard` keep resolving, because scripts
  and the MCP tool descriptions name them; `TestPresetsTable` gains a case that pins every name
  and alias the table has today. Both lookups walk the groups' plans as well as the bands', and
  the plan-prefixed alias is the form that resolves without a band.
- **A name resolves in a band's context at the prompt too.** `ley tune 16 --band marine` is
  marine 16; bare `16` stays 16 MHz, because a bare number is a frequency everywhere in `ley`
  (`freq.go`, the rule aliases are never accepted where a frequency is). `ch16` without a band
  is GMRS, as today.
- **`ley bands --json` grows `channels`**, the shape above, and `make bands-json` regenerates
  the resource. `ley bands` prints a CHANNELS count column; `ley bands <name>` prints the plan.
- **`ley bookmarks`** gains `import`, the `tone`, `note` and `tags` columns when any bookmark
  has them, `--tag` on the list, and `add --tone --note --tag`. The JSON shape grows the three
  fields. The help golden and `bookmarks.golden` change.
- **`ley monitor` and `ley scan` name channels from the plans** instead of the preset table,
  which they do through `presetAt` already; the marine and CB plans mean those bands gain a
  CHANNEL column they did not have. `monitor_layout_test.go`'s "a band with no named channels
  has no column" case stays on FM broadcast, which still has none.
- **MCP.** The `tune`, `listen_summary` and `scan` tools already say "a preset name such as
  noaa, calling or ch1"; the description gains "or a plan channel such as wx3, marine16 or
  cb19" once those resolve. No new tool: an agent reads the bookmarks file through
  `ley bookmarks --json` today, and a `bookmarks` tool is deferred below.
- **The app and `ley` must read each other's files under either version.** A bookmarks file
  with `tone` read by a `ley` built before this document must round-trip it: `go/pkg/bookmarks`
  decodes into a struct today and would drop the field on save. The Go store and the Swift store
  both keep unknown keys per entry (`json.RawMessage` on the Go side, a `[String: JSON]` extra
  on the Swift side) before either writes a new field. This is the one change to land first.

### Sequence

1. Unknown-key preservation in both bookmark stores, so nothing later loses data.
2. Plans in the band table, `ley bands --json` and the seed file, `ley presets` as a view,
   MURS, 6 m and 1.25 m added, the goldens re-recorded.
3. The sidebar on the spine: nesting, the collapsed out-of-range line, the filter field, the
   picker and the rail ticks, channel names on rows.
4. Scan band over the scan job, with the audio-gone measurement above recorded.
5. `tone`, `note` and `tags`, in the inspector and `ley bookmarks`.
6. CHIRP import, both surfaces.

## Deliberately not in alpha

- **Lists and scan lists.** `tags` is the hook; a `Lists` section, a scan across a list and a
  list-aware `ley scan` are the ham story's second half and come after the app is in hands.
- **Repeater pairs.** `offset_hz` and `duplex` are written by the import and read by nothing.
  The inspector showing the input
  frequency, and a bookmark that tunes the input when a key is held, wait for TX to be a concept
  at all (invariant 11).
- **A `Bands…` sheet** with a checkbox per band and a switch for the out-of-range group. With
  every band collapsed to one row and the out-of-range bands to one line, an RTL-SDR user sees
  about thirteen rows, so a second length control is not needed until a user with a wide radio
  asks to hide bands.
- **Usage ordering and a Recent section.** Frequency order is the sidebar's; the Tune menu and
  the filter field are where a recent frequency is reached. Reconsider when a user asks.
- **Regional plans.** US only; packs later (R-22).
- **An MCP `bookmarks` tool** (list, add) and its eval scenario (`../dev/evals.md`). No story
  asks for an agent writing bookmarks; the file is readable through `ley bookmarks --json`, and
  the tool comes with the first agent session that wants to keep a frequency.
- **Editing the band table in the app.** A user who wants a band Leyline lacks bookmarks its
  edges; a band editor is a pack editor, and that is the content layer's.
- **Bookmarks in the daemon.** See D6 above.

## Open questions

- **Marine's plan size**, decided 2026-09-28: the full ITU plan with the US A and B variants
  and ship and coast entries, in the data, the picker and `ley bands marine`, because the
  picker's filter copes with a hundred rows and a boater's dozen is a subset of it.
- **The Scan band measurement** in "The daemon": how long the audio is gone.
