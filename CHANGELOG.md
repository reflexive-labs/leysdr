# Changelog

What changed for someone using Leyline, newest first. Each released version has a dated section;
`## Unreleased` collects what the next one will carry.

## Unreleased

- **Fixed: a failing radio was opened again and again.** A dongle that stopped answering (empty
  USB descriptors, register writes timing out) was re-opened every 2 to 60 s, and each open could
  make the driver reset it, which can stall other devices on the same USB hub. After three
  failures in a row the radio now reads `NOT_ANSWERING` in `ley devices`, `ley state` and the
  app's device menu, with what to do: "unplug it and plug it back in, ideally into a port on the
  back of the Mac". Leyline leaves it alone until it is replugged. A radio another program holds
  still reads `IN_USE` and is checked again as before.
- **Fixed: a capture whose radio stopped sending samples still read `active`.** After 5 s with no
  samples a capture now reads `STALLED`, "no samples from <radio> for 5 s", and goes back to
  active when samples return. After 30 s Leyline closes and reopens the radio once; a radio that
  still sends nothing is marked not answering.
- **Speech on a channel that never goes quiet.** A transmission longer than 30 s is cut into
  pieces at the quietest moment near each 30 s, with nothing lost between them, so FM broadcast, a
  NOAA weather station or a channel with the squelch off is transcribed rather than dropped after
  ten minutes. A continuous recording, which has no squelch openings, can be transcribed now: `ley
  transcribe` and the Library's Transcribe count every minute of it. Each piece after the first
  is marked `continues`.
- **The cost of that is stated first.** Such a channel sends all of its audio, 60 minutes an hour.
  `ley decode speech` and `ley watch speech` on FM or AM broadcast or NOAA weather say so before
  they start and ask; `--yes` skips the question.

## 0.3.1 (2026-11-04)

- **Fixed: the Decoders map jumped around.** It re-fitted itself to every aircraft several times a
  second, so it zoomed as aircraft appeared, moved and aged out. It now frames once, afterwards
  only zooms out when an aircraft would leave the view, and never moves when one disappears. Once
  you pan or zoom it stays where you put it; **Fit All** in its corner frames everything again.
  An aircraft not heard for half its silence window draws dimmed before it goes.
- **Fixed: decoded transmitters vanished and came back.** Leaving the Decoders place, switching
  decoder or a reconnect rebuilt the table from only the last 1000 records, so a transmitter whose
  records had scrolled out disappeared until it was heard again. The table now lasts the session
  and new history merges into it.
- **Fixed: `--for` recordings ran long or short.** On a busy Mac a `ley record --for 1s` could
  hold 1.1 s of audio, or stop a few milliseconds early by the clock, and a gated part could hold
  a few milliseconds more audio than its span. A duration is now cut at exactly its sample count,
  and audio is dated where its samples belong.

## 0.3.0 (2026-11-03)

- **ADS-B.** A new decoder hears aircraft on 1090 MHz: `ley decode aircraft` prints each
  identification, position and velocity, and `ley track aircraft` keeps a table of aircraft by
  callsign. Its recipe sets the gain to 40 dB: on an R820T dongle over `rtl_tcp` (2026-11-02),
  30 dB decoded nothing and 40 dB decoded 19 messages in 9 s. An aircraft leaves the table after
  120 s with no message.
- **The Decoders place (⌘3).** A third place beside Radio and Library: a sidebar of installed
  decoders and their running jobs, and for each a log of records, a table of transmitters, a map
  when records carry a position, and an inspector for the selected record. The inspector names a
  transmitter, and `ley label` reads the same name. A decoder started here keeps running after
  the app quits, until Stop.
- **Starting a decoder says where it will run.** The page shows whether a decoder runs beside
  what you hear, takes an idle radio, or needs the radio from you; in that case Start asks "Take
  the radio?" naming your channel. A decoder no radio can hear has Start switched off and says why.
- **Notify Me.** A decoder's page builds a watch from its fields (SAME's county, an APRS
  callsign, a place and radius for anything with a position) and posts a macOS notification on
  each match. The daemon runs the watch, so it notifies with the app closed. The sidebar lists
  each watch with its condition and a Stop.
- **Decode With.** The Library's context menu and a recording's inspector run any installed
  decoder over an audio or IQ recording. The inspector's Decoded row says how many records each
  decoder found, with a link to its page. `ley decode <decoder> --recording <id>` does the same.
- **Decoding from the Radio.** A row per running decoder tops the Radio sidebar with its count
  and opens its page, and the waterfall tags an APRS or other audio decoder's transmitter by name
  on the row it was heard in. View > Show Decoded Names turns the tags off.
- **Changed: `ley tune` will not pause a decoder.** `ley tune`, `ley set freq`, `ley spectrum`,
  `ley waterfall` and the other verbs that retune a radio refuse a move that would pause a running
  job (a decoder, a watch, a recording or a scan) and list it: `retuning to 150.000 MHz would
  pause the aprs decoder on 144.390 MHz; --retune moves it anyway`. Before, only recordings and
  other clients' channels stopped a retune.
- **Changed: the app asks before it moves a radio a job uses.** "Move the radio?" lists every job
  the move would pause, for a click or a typed frequency outside the span, a band, a narrower
  width or Scan band; a drag asks once. Cancel leaves the radio where it is.
- **A radio comes back.** When a decoder, a scan or a take-over moved the radio and ends, the
  radio returns to the tuning it found, unless you moved it since. A job paused by a move says
  who moved it ("paused: the app tuned NESDR SMArt v5 to 146.520 MHz"), and the Radio inspector's
  Claims group lists who is using the radio, "paused by the app at 14:05" among them.
- **Who uses a radio.** `ley state` lists each capture's users: channels, jobs, views and you.
  `--dry-run` on `ley decode`, `ley record` and `ley scan`, and `dry_run` on the MCP tools, say
  where a job would run and what it would pause, and start nothing. Several decoders share one
  capture, and an IQ recording starts a new part each time its radio is retuned.
- **Readable records everywhere.** Each decoder's manifest carries display templates, so `ley
  decode`, `ley records`, `ley watch`, `ley track` and the MCP tools print one line a person reads.
  AIS static reports and SAME alerts, which printed raw bytes, now read as text. Fields have
  labels ("Transmitter", "Callsign", "County"), which `ley track`'s column heads, `ley watch`'s
  banner and the app use.
- **Changed: `ley track` lists rows by name.** Rows were newest-heard first, so a live ADS-B
  table moved on every redraw; `--sort heard` keeps that order. `--json` and the MCP
  `list_entities` tool follow.
- **`--gain` on `ley decode` and `ley watch`**, and on the MCP decode and watch tools, overrides
  a recipe's gain when the job sets up the radio. A job on a radio it shares keeps that radio's
  gain and says which.
- **The decoder list** leaves out `speech-scripted` and `iqstat`, which exist for tests.
- **Fixes.** `ley decode`, `ley watch` and `ley track` end with the reason when the daemon
  declines their job, where they waited forever. `ley watch --detach` reports a decline rather
  than "left running", and the MCP `watch` and `start_decode_job` tools return it. A relative
  `--socket` reaches the daemon. The decoder inspector's values line up in one column. Renaming a
  bookmark added from a scan hit on a bookmarked frequency edits that bookmark.
- **Fixed: a decoder started just after another program released the dongle ran at 0 dB.**
  A daemon that started while `rtl_tcp` (or SDR++, GQRX) held the dongle never learned its gain
  table, so a decoder that opened the dongle afterwards asked for 40 dB and got 0 dB, and heard
  nothing. Opening the dongle now reads its tuner and gains, a fixed gain on a stage with no table
  is refused rather than set to 0 dB, and the `ley decode` banner names the gain. A decode job
  whose radio stops delivering samples for 5 s now says so (`no samples from … for 5 s`).
- **Fixed: a transcription of a recording lost overs.** A recording of more than nine overs came
  back with most of them missing and no warning. The engine now waits for the speech decoder
  instead of dropping an over, and a finished job's detail says how many overs have no record
  (`3 of 20 overs have no record`).
- **The Library lists transmissions, not files.** A row is one transmission with its transcript
  line under it, and a file that holds several overs (any recording made before this release, or
  with a long `--hang`) is a row for each, which plays that over alone. The inspector describes
  the transmission and its recording. When a transcription leaves some transmissions without
  words, the page says how many, with Transcribe again beside the count. Show in Finder moved to a
  row's context menu.
- **Changed: a recording is one file per transmission.** A gated recording now closes a file
  500 ms after the key-down in `ley record`, the MCP `record` tool and a live speech job's clips,
  as the app's record button already did; it was 5 s, which put an exchange of several overs in
  one file. `--hang 5s` (MCP `hang_ms`) keeps the old behaviour.
- **Changed: `ley record` skips the dead air.** With no `--gate`, an NFM or AM recording with a
  squelch set is gated, so a repeater is recorded only while it is keyed; WFM, IQ and `--squelch
  off` still record continuously, and `--gate none` asks for that on any channel. The banner
  names the gate the daemon chose. The daemon also removes, at start, recordings that hold no
  file and were left from before an empty recording was discarded.

## 0.2.0 (2026-10-23)

Leyline 0.2 adds AI on your own provider key: an assistant in the app that runs the radio from
plain requests, and speech-to-text for each over on a recording or a live channel.

- **The assistant.** A column beside the inspector (the toolbar's Assistant button, or View >
  Show Assistant, ⇧⌘A, once a key is added) takes plain requests and runs the radio with
  `ley mcp`'s tools: it tunes, sets the squelch, scans, records, keeps bookmarks, and moves the
  window to a band, the Library or a recording. Each step opens to its arguments and result. A
  call that takes the radio from another listener, deletes a recording, starts a kept job or paid
  transcription, imports or removes bookmarks, or follows text received over the air asks first,
  in words, with Decline, Allow in this chat and Allow. Stop ends a turn. Conversations are kept
  across a restart of the engine. The assistant never hears the audio.
- **AI on your own key.** Settings > AI and `ley ai` add, check and remove a key for Anthropic,
  OpenAI or an OpenAI-compatible server, choose the provider and model for each feature, and show
  the requests and tokens each one used by day or month, with no prices. The engine keeps the key
  in the login keychain and never returns it to a client. Adding a key gives every feature it
  serves that has no model yet the provider's default (OpenAI: gpt-5 and whisper-1; Anthropic:
  claude-sonnet-5-5 for the assistant); `ley ai use` changes one. Settings says, for each
  feature, what it sends to which host.
- **Speech.** The speech decoder sends the audio of each over, and none of the silence between,
  to OpenAI's transcription API or the server a key's endpoint names, and keeps the words tied to
  the over: `ley transcribe` over a gated recording, after stating the minutes and the host;
  `ley decode speech --freq` on a live channel, with each over kept as a clip; and
  `ley watch speech --freq 146.52 --where 'text~net control'`. The Library transcribes a gated
  recording, shows each over's words and the callsigns a pattern found in them, searches them,
  plays one over and exports them as text or SRT. `ley play --over`, `--from` and `--to` play
  part of a recording. There is no on-device speech engine yet.
- **The window follows the radio.** When another client (the assistant, a terminal's `ley tune`,
  an agent on `ley mcp`) makes a channel on the window's radio, the readout, the inspector, the
  transmissions log and the audio move to it, and the inspector says who tuned. While the
  window's old channel is still recording, the inspector shows Still recording with a Stop.
- **`ley mcp`.** Eleven more tools: `set`, `stop`, `list_bookmarks`, `add_bookmark`,
  `remove_bookmark`, `list_bands`, `list_presets`, `watch`, `attach_device`, `import_chirp` and
  `help`. `set` refuses to change another client's channel until `take_over`, as `tune` does, and
  each tool's text starts with what it did.
- **The sidebar.** An open band's Scan band and Channels are rows under its header, and the
  words are shorter (`17 bands out of range ›`, `sq auto`). A band the radio cannot tune reads
  disabled. A bookmark near a plan channel reads `≈` and the channel. A scan hit tunes and
  bookmarks the channel it names, or its measured frequency to 100 Hz.
- **Tuning.** The tuning field shows four decimals of MHz, cut and never rounded. A typed
  frequency tunes to the hertz, and Return with nothing typed keeps the exact frequency.
- **Squelch.** A measured squelch reads `auto` in the sidebar and `(auto)` after its level in
  `ley state`, `ley set` and the event lines.
- **Bookmarks.** Leaving a Tone or Note field saves it, as Return does; Escape throws the edit
  away. Bookmarks on one frequency (a repeater and its net from a CHIRP export) are one sidebar
  row named after the file's first, `Club repeater +1`; the inspector lists each with its own
  tone and note, marks the one whose tone is on the air, and the transmissions log names each
  over by it. The file keeps every entry. A control beside the sidebar's `+` sorts the bookmarks under every band by frequency
  or by name.
- **The band rail.** The rail's one thumb is the view the spectrum and waterfall show, over a
  faint underlay for what the radio captures, so a 20 MHz HackRF capture fits the rail. Dragging
  the thumb pans the view inside the capture with no retune, and only a drag past its edge moves
  the radio. Picking a band fits the view to it with half a channel past each edge, so the
  channels on its edges show whole. − and + halve and double the span (`4 MHz across`), a
  click on the track tunes the nearest tick, and a marker at the spectrum's edge (`146.520 ▸`)
  brings the view back to the tuned channel.
- **Recordings that fall behind.** When the engine cannot keep up with the radio, a recording
  lists each stretch it dropped and claims only the audio it wrote. `ley recordings` gains a
  DROPPED column, and the Library marks a part with gaps and ticks them on its level graph.
- **Keys.** A key the keychain will not give the engine is named with the keychain's own words
  (`cannot read the openai key from the keychain: …`) in Settings' Check and the assistant,
  rather than "no key is set", and the engine logs every failed read. Settings calls a key for
  OpenAI's own API `OpenAI`, and a key with an endpoint `OpenAI-compatible`. `text~` in a watch
  or a search ignores punctuation at a word's edges, so `text~net control` matches "net control.".
- **Fixes.** A window that opens before the radio, or across a restart of the engine, takes the
  channel once the radio comes. A wide file radio keeps its tuned band in the sidebar. After Stop
  Listening, a band moves the radio another client left rather than asking for a second one. The
  Width pop-up no longer wraps `11.25 kHz`, a tall inspector no longer pushes the transport bar
  out of the window, and the audio ladder shows a dash while the audio is silent. Go to… from the
  Library gives the filter its focus. The API key field no longer offers AutoFill.
- **For test and check runs**, `leylined` gains `--no-audio`, `--file-scan-dwell` and `--secrets
  file`, which keeps AI keys in a file under `--data`.

## 0.1.2 (2026-10-07)

- **Install.** Install CLI Tools… in the app menu puts `ley` on the Terminal path.

## 0.1.1 (2026-10-06)

- **Install.** A first launch from the DMG now registers and starts the bundled engine on a Mac
  that has never run Leyline before.

## 0.1.0 (2026-10-05)

The first release: a signed, notarized Mac app for a small group of testers.

- **Install.** Leyline is a Mac app (Apple silicon, macOS 26 or later) delivered as a DMG. It
  carries its own RTL-SDR and HackRF drivers, so nothing else needs installing. On first launch it
  registers its engine as a login item, listed in System Settings > General > Login Items &
  Extensions. Leyline > Check for Updates… installs newer releases.
- **Radios.** An RTL-SDR or HackRF on USB, an RTL-SDR another machine serves with `rtl_tcp`, or an
  IQ recording played back as a radio.
- **Listening.** NFM, WFM, AM, USB, LSB and CW, with squelch, CTCSS and DCS detection, and two
  channels from one radio.
- **The window.** Spectrum and waterfall, a sidebar of bands with their channel plans and your
  bookmarks, an inspector for the channel's signal, tuning error and recent transmissions, a band
  scan, and recording, with a Library of what was recorded.
- **Recording.** Audio or IQ, continuous or one file per transmission when squelch-gated, played
  back from the Library or with `ley play`.
- **Decoding.** APRS, SAME weather alerts and marine AIS.
- **`ley`.** The command-line client ships inside the app; `docs/guide/install.md` shows the one
  symlink that puts it on your `PATH`. Every verb takes `--json`, and `ley mcp` serves the same
  verbs to an AI agent as MCP tools.

Not in this release: the terminal dashboard, audio transcripts, channel occupancy, and builds for
Intel Macs. Leyline only receives; it never transmits.

Report problems with what you did, what you expected, and `ley daemon logs` (or
`~/Library/Logs/Leyline/leylined.log`) from around the time it happened.
