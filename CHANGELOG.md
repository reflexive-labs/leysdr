# Changelog

Nothing has been released yet. This file starts with everything that exists on `main`.

## Unreleased

- `ley` knows the channel plans. Every band that has one carries it: NOAA WX1 to WX7, GMRS 1 to
  22, MURS 1 to 5 (two new bands and a `murs` group, like GMRS), the ITU marine plan with the US
  `A` channels, a ship and a coast entry per duplex channel and AIS 1 and 2, CB 1 to 40, 2 m
  calling and APRS, and airband guard; 6 m and 1.25 m are new bands with no plan. A preset is now
  a channel of one of these plans, named by one word that works anywhere (`wx3`, `marine16`,
  `cb19`, `murs1`, `ch5`), and every older name still resolves. `ley tune 16 --band marine` and
  `ley bookmarks add 5 --band gmrs` take a channel the way its radios number it, where a bare
  number stays a frequency. `ley bands` counts each plan, `ley bands noaa` lists one, `ley bands
  --json` and the app's seed carry `channels`, and `ley scan` and `ley monitor` name a carrier
  on any plan channel, marine and CB included.

- A bookmark can carry a repeater's tone, a note and tags. `ley bookmarks add --tone 100.0
  --note "600 kHz down" --tag home` keeps them beside the frequency; the tone is spelled the way
  CHIRP spells one (`100.0`, `D023N`) and anything else is refused. `ley bookmarks` shows TONE,
  NOTE and TAGS columns once a bookmark has them, `--tag home` lists only those filed under the
  word, and `--json` carries the fields. Nothing gates audio on the tone. This is `ley`'s half;
  the app's inspector, which edits the tone and note and shows the tone heard on the air beside
  them, follows.

- The bookmarks file keeps fields it does not know. Both `ley bookmarks` and the Mac app now
  write back, unchanged, every key of an entry they do not recognise, so a bookmark saved by a
  newer build of one client survives an edit by an older build of the other. Entries are written
  with their keys sorted.

- The Mac app has its mark, a splash and an icon. The toolbar starts with the mark and
  `Leyline` in place of the window's title. The first window of a launch opens on the mark,
  `leyline` and `SOFTWARE DEFINED RADIO`, holds until the daemon is live (1.2 s to 2 s), then
  clears in 0.7 s as a ring spreads from the mark, the mark moves to the toolbar and the window
  appears from the top down; with Reduce Motion on it cross-fades in 0.3 s. `bundle-app.sh` now
  draws the icon, the mark on the window's dark ground, with `scripts/render-icon.swift`.

- Switching a recording on or off in the Mac app cuts the transmissions log there, as a marker:
  the transmission on air ends at that moment and a new one begins, and the cut rows have a red
  bar at their left. A recording of a station that never stops transmitting now has a row that
  plays its part. A recording started or stopped with `ley record` cuts the log too.

- The Mac app's Library lists parts, not recordings. Each part is a row with its start, length,
  a small level graph read from its file, its peak and its size; a recording of several parts is
  bracketed at the left, and each day opens with a 24-hour strip marking when parts began and a
  `Play day` that plays the day in order. Days older than two fold to one line each. A part the
  radio clipped during reads `0.0 dBFS` in red, and the inspector says for how long and what to do
  about it. The player's button pauses and resumes now (space too), where it used to stop; Library
  ▸ Stop ends the part. Recordings on one frequency are one channel in the sidebar whatever their
  mode or width, and a recording with no parts is not listed. The notice line at the bottom of the
  Library is gone.

- A recording's parts say how long the radio clipped during them: `clipped_ms` in the manifest
  and each part's sidecar, from the capture's own clipping count, and a `CLIP` column in
  `ley recordings show` when any part clipped. A part's peak is measured on the audio, so a peak
  of 0.0 dBFS does not by itself mean the radio clipped.

- `ley play` pauses and resumes a recording on space while the daemon plays it, and the position
  line says `paused`. The contract gains `Control.SetPlaybackPaused` and `Playback.paused`, and
  the position holds while paused.

- A recording that heard nothing is no longer kept. A gated recording switched on and off while
  the squelch never opened used to leave an empty recording in every list; the daemon now removes
  it when the job ends, the job ends with `nothing was heard`, and `ley record` prints
  `Recorded nothing: the squelch never opened.`

- The Mac app's Record transmissions switches no longer go grey. Their red tint was switched off
  along with the switch, and on the owner's third run a switch went grey until it was clicked
  again. The tint now stays set; macOS paints it on the on track only, so an off switch still
  shows the system's dark track. A switch now matches a recording within 1 Hz of its frequency,
  and after a click it shows that click for 3 s at most before it shows the recording again. Each
  change to what the switch shows is written to the app's log.

- The play buttons' tooltips are one word: Play or Stop on a kept row of the log, on a part in the
  Library and on the player, and Previous part, Next part and Play all beside them.

- The Mac app's Record transmissions switch now makes one part per transmission. The window left
  the daemon's 5 s hang in place, so a quick back-and-forth on a simplex channel became one long
  part: four 4 s transmissions were one 25 s part in the Library, and playing one row of the log
  lit three. The window's recordings now close a part half a second after the squelch does, and
  a gap shorter than that stays in one part. `ley record` keeps the 5 s hang.

- Rows of the log that a recording kept keep their ▶ after the switch is turned off and on again.
  The window matched the rows against the newest recording only, which starts empty, so the rows
  the earlier recording had kept looked heard and could not be played. Every recording on the
  tuned frequency and mode now counts, and the waterfall's kept bars show them all.

- Playing a kept row shows ■ and the progress line on that row only. Rows close together can lie
  in one part, and each of them used to show the part playing.

- Switching channel no longer empties the transmissions log. The window keeps a log for each
  frequency and mode tuned this session, up to 32, and coming back to a frequency shows what was
  heard there. The transmission on air when you tune away still ends in that frequency's log.

- The toolbar's Radio | Library switch shows the unselected place on the toolbar's dark ground,
  and the Record transmissions switch is red only while it is on.

- The Mac app has two places, Radio and Library, switched at the left of the toolbar or with ⌘1
  and ⌘2. Radio is the window as before, and its sidebar is back to bands and bookmarks only.
  Library replaces the whole window below the toolbar with what has been kept while the radio
  keeps running: a sidebar with a search field, the recorded channels and the store's footer,
  the channel's page of recordings in the centre, the selected part (or the channel's name,
  frequency, size and Show in Finder) in the inspector, and a player in place of the transport
  bar. The player plays and stops the selected part, or the first part of the newest recording,
  steps to the previous and next part of that recording, shows the part as `GMRS CH3 · Tuesday
  14:02 · part 5 of 11` and `16:11:04 · 10.0 s` with how far it has played, and keeps the
  volume, captioned `GMRS CH3 · live` between parts. Space plays and stops, ← and → step, from
  the new Library menu. The Recordings source in the sidebar is gone; its pages moved to the
  Library unchanged.

- A recording gated by squelch now keeps a signal that was already on the air when it started.
  A broadcast station or any carrier that never stops holds the squelch open from before the
  recording begins, so no opening ever came, and switching the recording off left a recording of
  0 s and 0 B. The daemon now reads the squelch's state from the channel's meter when the
  recording starts, and after the radio comes back from being moved away, and opens a part at
  once when it is open. `ley record --gate squelch` and the Mac app's switch both get this.

- Retuning a channel ends the transmission it was hearing. The window retunes by moving the same
  channel, and the daemon's squelch stayed open across the move, so the log kept the last
  frequency's transmission on air (`not audible`, 2:48 and counting). The daemon now closes an
  open squelch whenever a channel's frequency, width or mode changes or its radio moves off it,
  and opens a new transmission if the new frequency carries a signal; every client's log sees
  the close. The Mac app's log switches to the new frequency's own log (above), since a
  transmission on the last frequency was not one on this. `ley tune` makes a new channel for
  each tune and was not affected.

- The Record transmissions switch on a Recordings channel page records. When the radio is
  listening somewhere else the daemon declines the recording after accepting the request, and
  the window dropped the reason, so the switch went back off with nothing said; the reason is now
  a notice on the page, with what to do: `Could not record: the app is listening on 146.520 MHz.
  Tune to 462.6125 MHz first, and the recording shares the radio.` The page asks for the daemon's
  auto squelch, which the daemon read as "squelch off" and then measured from the channel's own
  level, above any carrier on it; a gated recording now takes NaN as auto, and the auto squelch
  sits 10 dB over the band's noise floor, as `ley tune`'s does.

- The Mac app's Recordings source has channel pages. Select a channel in the sidebar and the
  centre of the window lists what it has kept, grouped Today, Yesterday, the day before, and
  Earlier, where older recordings fold to one line until clicked. Each recording is a card with
  its time range, parts, length and size, and each part is a chip, `▶ 09:12:40 · 8 s`: click it
  to hear it (the live channel is held silent meanwhile), click it again to stop, or use Play all
  to hear the parts in order. The page's header has the same Record transmissions switch as the
  inspector, and Tune goes back to Radio tuned to the channel. While a part is selected the
  inspector shows it: its place in the recording, how far it has played, its peak and mean, the
  radio, gain and squelch it was recorded with, why it ended, and its files, with Show in Finder
  and Delete recording…, which deletes the whole recording after asking and is disabled while it
  is still recording.

- The Mac app's sidebar has two sources, Radio and Recordings, under a switch above the bands.
  Recordings lists one row per channel that has been recorded, titled by its bookmark or its
  frequency, with how many recordings it holds and when the latest was (`latest now` while one
  is running), and a search field that matches a name, a frequency or a weekday. Under
  both sources a footer shows how much of the recordings cap the store uses, `944 MB of 20 GB ·
  oldest go first`. The waterfall has a time gutter at its right, with `now` at the top and a mark
  every ten seconds, and the red bars for what a recording kept are drawn in it instead of over
  the waterfall's edge. The log's heading reads `TRANSMISSIONS` with the day beside it and drops
  its column heads and count. The line under the volume slider says what you hear: `playing GMRS
  CH3`, `muted · GMRS CH3`, or `playing a part · GMRS CH3 held` while a kept part plays; hover it
  for the output device. `ley state` ends its first line with the same store use,
  `recordings 944 MB of 20 GB`, and the contract's `DaemonInfo` gains `recordings_cap_bytes`, the
  daemon's `--recordings-cap`.

- The Mac app records from its log. "Recent on this channel" opens with a Record transmissions
  switch: on, the daemon records the tuned channel while its squelch is open, one part per
  transmission, and keeps going after a retune or a quit; the line under the switch reads
  `Since 09:12 · 3 parts · 1.1 MB`. The switch shows a recording `ley record` or an agent started
  on the same frequency and mode too, and File ▸ Record Transmissions (⌘R) is the same switch. A
  transmission the recording holds is white with ▶ to play it and Show in Finder in its menu; one
  that was only heard stays grey and has no ▶. A bookmark that is recording has a red dot, and the
  waterfall marks the rows that were kept with a red bar at its right edge. Moving the radio off a
  recording's frequency (a band switch, a drag of the band rail, a narrower sample rate) asks
  first. The sidebar's Recordings list, the Record button beside the Channel heading, the log's
  rows made from a recording, and Record Continuously are gone; use `ley recordings` to list and
  delete recordings, and `ley record` without `--gate` for an ungated one, until the app's
  Recordings view arrives (M3).

- The daemon publishes a playing recording four times a second with its position, so `ley play`
  and the Mac app follow it on the event stream and no longer poll `GetState`. Deleting a
  recording stops a playback of any of its parts first, and `ley play` holding it ends. A
  recording's listing carries `bandwidth_hz`, and a click on a recording in the app's sidebar
  tunes the width it was recorded at rather than the mode's default.

- `ley recordings delete <id>` removes a recording whole, every part and its manifest, and prints
  how much space that freed. On a terminal it names the recording and asks first; `--yes` skips
  the question and is required from a script. A recording whose job is still running is refused
  with `ley jobs cancel` named. The contract gains `Resources.DeleteResource`, which the Mac app's
  delete button will use, and the MCP adapter a `delete_recording` tool with the same refusals.

- Every gain takes one syntax and prints one way. `ley set gain` and `ley scan --gain` accept what
  `--gain` accepts on `tune` and `record`: `auto`, a level for the first stage, or stages by name
  (`ley set gain LNA=0,VGA=20`), so `ley set`'s `--element` flag is gone. `ScanConfig` gains
  `repeated GainWrite gains`, applied in order, and a stage the radio does not have fails the
  sweep with the ones it has. A capture's gain reads the same in the banners, `ley state`,
  `ley set`, the scan summary and `ley recordings show`: `gain 28 dB` on a one-stage radio,
  `gain LNA 0 dB, VGA 20 dB, AMP off` on a HackRF, a decimal only when the value has one.
  `ley devices` lists ranges the same way (`TUNER 0–49.6 dB auto`), and `ley help gain` is the
  one explanation of the syntax.
- `ley tune` says the radio is clipping once, after it has clipped for a second, with the count
  that raised it, and says nothing more until it has been clean for two seconds; the "Nothing is
  above the noise" line is said once, at tune. "At the lowest gain" now needs every gain stage you
  can set at its lowest, so a HackRF at LNA 8 and VGA 20 is told "Lower the LNA or VGA gain."
  rather than to move the antenna; the Mac app's clipping words follow the same rule.
- `ley record --gain` reaches the radio. The daemon had dropped it on every real radio and
  recorded at whatever gain the radio was on. A gain the radio refuses now fails the job with the
  reason, and the banner's `Radio` line lists the gain the take started at. `--gain` on `tune`,
  `record` and the other verbs that take it accepts stage=dB pairs, `--gain LNA=0,VGA=0`, for a
  radio with several stages (`RecordConfig.gains`), and a banner on such a radio lists every stage.

- `ley tune` prints a DCS code the daemon reports as `DCS  023`, once per change as it prints a
  PL tone, and `ley levels` and `ley scope` show it in their headers. The MCP `listen_summary`
  keeps a DCS report over a CTCSS one. A code sent inverted is named as the standard code the same
  bit stream reads as normal: 023 inverted shows as 047. `make fixtures` adds `nfm_dcs`,
  `nfm_dcs_754` and `nfm_dcs_inverted`.

- The RTL-SDR and HackRF native backends are now optional runtime-loaded components. The daemon
  builds and starts with neither library, logs a missing backend once, and continues with the other
  backend, `rtl_tcp`, and file playback. CI tests neither, either one alone, and both with mocks.
  The Mac app exposes every advertised gain stage separately and remembers it per device and stage,
  while a new multi-stage radio keeps the driver's safe defaults until a control is changed.
- The engine can now discover and receive from HackRF One and HackRF Pro through libhackrf. It
  identifies Pro by board id, carries native signed 8-bit IQ at 2–20 MSPS into the existing CS8
  path, exposes LNA/VGA/RF-amp gain stages, keeps stable ids across replug, and shares the physical
  device claim/backoff behavior used by RTL-SDR. TX and Pro-specific 16-/4-bit modes remain out of
  scope; the initial backend uses libhackrf's backwards-compatible receive mode.
- The Mac app opens a radio at 2.4 MSPS and a fixed 28 dB of gain, and remembers what the device
  menu sets for either; a band change moves the capture's centre and never its rate. The tuner's
  auto mode overloaded on a strong FM station, and the inspector now shows when the radio clips.
- A channel written to NFM now looks for a CTCSS tone. The detector was decided when a channel
  was created and never again, so the Mac app's one channel, which starts on whatever band was
  last used and follows the mode written to it, never reported a PL after a band change.
- Frequencies on an exact half-kilohertz print with four decimals: GMRS channel 3 is
  `462.6125 MHz`, and `462.613` is not a GMRS channel. A measured centre keeps three, the
  precision its FFT bin width supports. The app's tuning field takes a fourth digit after
  the kHz.
- The Mac app's inspector reads clipping from the daemon's count rather than the loudest bin, its
  Measurements group shows the radio's peak and clipped fraction, the "On air" row shows in words
  how many transmissions were heard and since when, and the app log lists each tone the daemon
  reports.
- The radio's clipping is measured, not inferred. The daemon counts the samples at the
  converter's rails as each block arrives and reports them four times a second as `CaptureLevel`
  telemetry (`clipped_samples`, `total_samples`, `peak_dbfs`), so `ley tune`'s line says "The
  radio is clipping: N of M samples (x.x %) hit the converter's rails" when it is and nothing
  about full scale when it is not; it read the loudest FFT bin, which sits near full scale on an
  FM broadcast carrier at auto gain with nothing wrong. `ley levels`' `OVER` reads the same
  count and its header carries the converter's peak.
- The Mac app has an inspector: a panel on the right that describes the tuned signal in words.
  Signal as one of five words with a matching bar, tuning as `Centred` or `Off tune · high`,
  deviation as `Quiet`, `Normal` or `Overdeviating`, time on air, and the last transmissions on the
  channel with the time each started, and a click on any word shows the number it came from. The
  channel's name leads, and a pencil renames it into `bookmarks.json`, so `ley bookmarks` lists the
  name too. Band warnings (the radio clipping, the channel outside the capture) now show here
  instead of over the waterfall, and the transport bar's signal readout moved here too. `View ▸ Show Inspector` (⌥⌘I)
  and the toolbar's right-hand button close and open it.
- The meter reports how far off frequency a transmitter is and how hard it is deviating.
  `Meter.freq_error_hz` is the FM discriminator's DC over the meter interval, positive when the
  transmitter sits above the channel, and `deviation_hz` its peak excursion, both read ahead of
  de-emphasis where a CTCSS tone still stands. NaN outside the FM modes and, for the error, while
  the squelch is closed. `ley scope --tap demod` shows the daemon's value in its header instead of
  measuring it from the trace's DC.
- Transmissions are timed and counted. `ley tune`'s meter line shows `on air 4 s` while the squelch
  is open, and the line for each transmission that ended begins with the time it started, taken from
  the capture's anchor rather than the terminal's clock, so a saved log keeps the correct time. The
  Mac app's façade keeps the same log of recent transmissions per channel, with the CTCSS tone each
  carried, for the inspector M2 adds.
- A channel's `snr_db` is its power over the band's noise floor at the channel's width, the
  number the Mac app's "over noise" and `ley tune`'s auto squelch already measured for themselves
  from a spectrum row. It was the channel's power over its own running minimum, which on a
  carrier that never stops is the carrier, so a -12 dBFS signal read 0 dB over noise in `ley`'s
  `snr` column. NaN until the capture has read a row.
- The window and `ley tune` report the failure states a newcomer hits instead of showing a dark
  waterfall: a signal within 3 dB of full scale ("lower the gain"), and nothing 15 dB above the
  noise floor, suggesting more gain when gain is set by hand to its lowest and the antenna
  otherwise. `ley tune` prints it beside the squelch it measured, on stderr; the MCP tune tool
  carries the same line, so an agent learns that the radio is receiving nothing instead of reading
  an empty decode as a quiet band.
- A gain write that names no element now lands on the first the device lists, as the contract
  specifies; the Mac app's gain slider was refused on every drag because of it.
- Changing the sample rate in the Mac app keeps the station inside the capture: the centre is
  re-placed for the tuned frequency at the new width, a width the channel cannot fit is refused
  with a message, and a channel another client leaves outside the capture is shown in the window.
- Bookmarks: `ley bookmarks add 146.94 --name "Local repeater"` keeps a frequency, `ley bookmarks`
  lists what you kept, `ley bookmarks move "Local repeater" 147.0` re-files one at another
  frequency with its name, mode and width intact, and `ley bookmarks remove` deletes one. They
  are stored in a JSON file beside the labels store (`$LEYLINE_BOOKMARKS` overrides its path),
  not daemon state, and the Mac app reads the same file, so a frequency kept from a terminal is in
  its sidebar. The band table gained a `step_hz` column -- the channel spacing, which is not the
  bandwidth: airband is 10 kHz wide and spaced 25 kHz -- and the app's seed copy of the table is
  `bands.json`, the checked-in output of `ley bands --json` that `make bands-json` regenerates and
  a test holds to the table.
- The Mac app, begun: an `app/` package with the Swift client façade (`LeylineClient`: one
  identity per process, the daemon's state as an observable mirror, coalesced writes, FFT and
  telemetry streams, the bands and bookmarks files, and the folds `ley` already applies: max
  hold, the peak rule, the auto squelch) and the M1 window from the design handoff: a sidebar of
  bands and bookmarks, a band rail (the band's edges as a track, the slice on screen, bookmarks
  and the tuned frequency as ticks, a drag that moves the region inside the band, and the
  neighbouring bands labelled at its ends), a spectrum, a Metal waterfall at 30 rows a second, a
  transport bar (play, the tuning field, mode, width, signal, the squelch track, volume), a device
  menu with the gain slider, and a Tune menu listing every gesture. `make app-run` opens it on a Mac
  (`docs/plans/app.md`, "The M1 cut").
- `leylined`: a launchd daemon that owns RTL-SDR hardware (USB via librtlsdr, or a remote dongle over
  `rtl_tcp`) and IQ files, runs every stage of the signal path (capture, channelize, NFM/WFM/AM/USB/
  LSB/CW demodulation, squelch, spectrum, sub-audible tone detection, energy detection) and speaks
  the `leyline.v1` gRPC contract over a Unix socket.
- `ley`: the command-line client. `devices`, `tune`, `set`, `stop`, `listen`, `spectrum`, `fft`,
  `waterfall`, `phosphor`, `scan`, `play`, `state`, `presets`, `bands`, `daemon`, `version`, `help`,
  with `--json` on every verb that prints a result.
- `leyfix`: the IQ fixture generator and analyser that lets the whole pipeline be tested without a
  radio.
- Licences: Apache-2.0 for the repository, GPL-3.0-or-later for the engine under `engine/`, which
  links librtlsdr (`docs/decisions/D2-licensing.md`). `NOTICE`, the vendored third-party texts under
  `third_party/licenses/`, an SPDX line on every source file, `TRADEMARK.md`, and
  `make license-check`, which refuses copyleft outside the engine.
- Decoders: the daemon runs decoder plugins as separate processes and turns what they decode into
  typed records. `ley decoders` lists what is installed, `ley decode aprs` decodes APRS packets from
  144.39 MHz, `ley records` queries what a kept job (`--job`) stored, and `ley track aprs` is the
  live station table. Three plugins ship, all written in Go: `leydec-aprs` (APRS over AFSK
  1200/AX.25), `leydec-same` (SAME/EAS weather alerts), and `leydec-ais` (marine AIS over 9600-baud
  GMSK). `ley watch <decoder>` filters a decoder's records with a daemon-side predicate and fires a
  notifier (a macOS notification, a webhook or a shell hook) on a match, so `ley watch same --county
  06009 --notify` raises a weather alert for your county with nothing connected. `ley devices-seen`
  lists the transmitters heard and, with `--quiet-since`, the ones that went quiet; `ley label`
  assigns a name to a discovered id. A decoder can read a channel's audio or, declaring so, the
  capture's raw IQ (for wideband modes). `make install-decoders` puts the plugins where the daemon
  finds them. `docs/design/decoders.md` and `docs/reference/writing-a-decoder.md` are the contract
  for another.
- Recording: `ley record 146.52 --for 5m` writes the received signal to files the daemon keeps --
  WAV audio, or the capture's raw samples with `--iq` -- as a job, so it outlives the terminal that
  started it and what it writes is a resource. `--gate squelch` records only while something is on
  the air and keeps one file per exchange, with the pauses between overs inside it and half a second
  of pre-roll before each key-up; silence is never edited out of a file, and the times nothing was
  recorded are listed in the manifest instead. `ley recordings` lists the store, `ley recordings
  show` prints one's manifest and `ley recordings path` prints its path, so `open -R "$(ley
  recordings path <id>)"` reveals it in Finder. `ley play <id>` plays one back whichever kind it is:
  an IQ recording is tuned as if it were a radio, and an audio recording is played by the daemon
  through the same audio device a channel's audio comes out of, so the sound comes out on the
  daemon's machine and Ctrl-C stops it. A `Playback` is daemon state, so `ley state` lists what is
  playing and the Mac app can render a position and a stop button; a daemon with no audio device
  falls back to this machine's player (`$LEYLINE_PLAYER`, else `open`). `ley record --listen` plays
  what is going into the file as it records. The `Resources` service serves recordings, kept records
  and scans; `Control.AttachSink(file)` stays refused, because a recording is a job's output rather
  than a sink somebody attached (`docs/design/recording.md`).
- `ley mcp`: a Model Context Protocol server an agent's client starts on stdin and stdout, serving the
  daemon's verbs as tools -- `list_devices`, `get_state`, `daemon_logs`, `tune`, `scan`,
  `listen_summary`, `snapshot` (a spectrum PNG and the row), `list_decoders`, `query_records`,
  `list_entities`, `start_decode_job`, `record`, `find_recordings`, `get_recording`, `list_jobs`,
  `get_job`, `cancel_job` -- with a recording's manifest and a kept job's records as the resources
  `ley://recordings/<job_id>` and `ley://records/<job_id>`. Every tool returns the proto3 JSON its
  `ley` mirror prints and a short summary; what an agent starts ends with its conversation unless
  it asks to keep it, and a recording, being a file, always outlives the call
  (`docs/reference/mcp.md`).
- Sweeps take a gain (`ley scan --gain 30|auto`, the MCP tool's `gain`) and report the gain they ran
  at; a running decode job's detail shows how many records it has heard and how long ago; a decode
  job started with `--job` comes back after a daemon restart as the same job; the tone detector
  waits one second before reporting a PL, so synthesised voice is no longer reported as a tone.
- Not yet: durable watch jobs and transcripts (D.15), the terminal dashboard (D.14), and in the
  Mac app, CHIRP import (E.4) and a signed bundle (E.7)
  (`docs/plans/build-order.md` has the order).
