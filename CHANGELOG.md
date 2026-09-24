# Changelog

Nothing has been released yet. This file starts with everything that exists on `main`.

## Unreleased

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
