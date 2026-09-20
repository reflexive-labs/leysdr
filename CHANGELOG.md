# Changelog

Nothing has been released yet. This file starts with everything that exists on `main`.

## Unreleased

- The radio's clipping is measured, not inferred. The daemon counts the samples at the
  converter's rails as each block arrives and reports them four times a second as `CaptureLevel`
  telemetry (`clipped_samples`, `total_samples`, `peak_dbfs`), so `ley tune`'s line says "The
  radio is clipping: N of M samples (x.x %) hit the converter's rails" when it is and nothing
  about full scale when it is not; it read the loudest FFT bin, which sits near full scale on an
  FM broadcast carrier at auto gain with nothing wrong. `ley levels`' `OVER` reads the same
  count and its header carries the converter's peak.
- The Mac app has an inspector: a panel on the right that says what you are hearing in words.
  Signal as one of five words with a bar that agrees with it, tuning as `Centred` or `Off tune ·
  high`, deviation as `Quiet`, `Normal` or `Overdeviating`, time on air, and the last
  transmissions on the channel with the time each started, and a click on any word shows the
  number it came from. The channel's name leads, and a pencil renames it into `bookmarks.json`,
  so `ley bookmarks` lists the name too. What the band's numbers say is wrong reads here now
  rather than over the waterfall, and the transport bar's signal readout left with it. `View ▸
  Show Inspector` (⌥⌘I) and the toolbar's right-hand button close and open it.
- The meter says how far off frequency a transmitter is and how hard it is deviating.
  `Meter.freq_error_hz` is the FM discriminator's DC over the meter interval, positive when the
  transmitter sits above the channel, and `deviation_hz` its peak excursion, both read ahead of
  de-emphasis where a CTCSS tone still stands. NaN outside the FM modes and, for the error, while
  the squelch is closed. `ley scope --tap demod` names the daemon's number in its header where it
  measured one from the trace's DC before.
- Transmissions have a clock and a count. `ley tune`'s meter line says `on air 4 s` while the
  squelch is open, and the line for each transmission that ended begins with the time it started,
  taken from the capture's anchor rather than the terminal's clock, so a log read later still says
  when. The Mac app's façade keeps the same log of recent transmissions per channel, with the
  CTCSS tone each carried, for the inspector M2 adds.
- A channel's `snr_db` is its power over the band's noise floor at the channel's width, the
  number the Mac app's "over noise" and `ley tune`'s auto squelch already measured for themselves
  from a spectrum row. It was the channel's power over its own running minimum, which on a
  carrier that never stops is the carrier, so a -12 dBFS signal read 0 dB over noise in `ley`'s
  `snr` column. NaN until the capture has read a row.
- The window and `ley tune` name the failure states a newcomer hits instead of showing a dark
  waterfall: a signal within 3 dB of full scale ("lower the gain"), and nothing 15 dB above the
  noise floor, with the gain named as the thing to try when it is set by hand to its lowest and
  the antenna otherwise. `ley tune` says it beside the squelch it measured, on stderr; the MCP
  tune tool carries the same line, so an agent is told a band is deaf rather than left to read an
  empty decode as quiet.
- A gain write that names no element now lands on the first the device lists, as the contract
  always said; the Mac app's gain slider was refused on every drag because of it.
- Changing the sample rate in the Mac app keeps the station inside the capture: the centre is
  re-placed for the tuned frequency at the new width, a width the channel cannot fit is refused
  in words, and a channel another client leaves outside the capture is named in the window.
- Bookmarks: `ley bookmarks add 146.94 --name "Local repeater"` keeps a frequency, `ley bookmarks`
  lists what you kept and `ley bookmarks remove` forgets one. They are your data in a JSON file
  beside the labels store (`$LEYLINE_BOOKMARKS` overrides its path), not daemon state, and the Mac
  app reads the same file, so a frequency kept from a terminal is in its sidebar. The band table
  gained a `step_hz` column -- the channel spacing, which is not the bandwidth: airband is 10 kHz
  wide and spaced 25 kHz -- and the app's seed copy of the table is `bands.json`, the checked-in
  output of `ley bands --json` that `make bands-json` regenerates and a test holds to the table.
- The Mac app, begun: an `app/` package with the Swift client façade (`LeylineClient`: one
  identity per process, the daemon's state as an observable mirror, coalesced writes, FFT and
  telemetry streams, the bands and bookmarks files, and the folds `ley` already applies: max
  hold, the peak rule, the auto squelch) and the M1 window from the design handoff: a sidebar of
  bands and bookmarks, a band rail (the band's edges as a track, the slice on screen, bookmarks
  and the tuned frequency as ticks, a drag that moves the region inside the band, and the
  neighbouring bands named at its ends), a spectrum, a Metal waterfall at 30 rows a second, a transport bar
  (play, the tuning field, mode, width, signal, the squelch track, volume), a device menu with
  the gain slider, and a Tune menu naming every gesture. `make app-run` opens it on a Mac
  (`docs/plans/app.md`, "The M1 cut").
- `leylined`: a launchd daemon that owns RTL-SDR hardware (USB via librtlsdr, or a remote dongle over
  `rtl_tcp`) and IQ files, runs every stage of the signal path (capture, channelize, NFM/WFM/AM/USB/
  LSB/CW demodulation, squelch, spectrum, sub-audible tone detection, energy detection) and speaks
  the `leyline.v1` gRPC contract over a Unix socket.
- `ley`: the command-line client. `devices`, `tune`, `set`, `stop`, `listen`, `spectrum`, `fft`,
  `waterfall`, `phosphor`, `scan`, `play`, `state`, `presets`, `bands`, `daemon`, `version`, `help`,
  with `--json` on every verb that has an answer to give.
- `leyfix`: the IQ fixture generator and analyser that lets the whole pipeline be tested without a
  radio.
- Licences: Apache-2.0 for the repository, GPL-3.0-or-later for the engine under `engine/`, which
  links librtlsdr (`docs/decisions/D2-licensing.md`). `NOTICE`, the vendored third-party texts under
  `third_party/licenses/`, an SPDX line on every source file, `TRADEMARK.md`, and
  `make license-check`, which refuses copyleft outside the engine.
- Decoders: the daemon runs decoder plugins as separate processes and turns what they decode into
  typed records. `ley decoders` lists what is installed, `ley decode aprs` decodes APRS packets
  from 144.39 MHz, `ley records` queries what a kept job (`--job`) stored, and `ley track aprs` is
  the live station table. Three plugins ship, all written in Go: `leydec-aprs` (APRS over AFSK
  1200/AX.25), `leydec-same` (SAME/EAS weather alerts), and `leydec-ais` (marine AIS over 9600-baud
  GMSK). `ley watch <decoder>` filters a decoder's records with a daemon-side predicate and fires a
  notifier (a macOS notification, a webhook or a shell hook) on a match, so `ley watch same --county
  06009 --notify` raises a weather alert for your county with nothing connected. `ley devices-seen`
  lists the transmitters heard and, with `--quiet-since`, the ones that went quiet; `ley label`
  names a discovered id. A decoder can read a channel's audio or, declaring so, the capture's raw
  IQ (for wideband modes). `make install-decoders` puts the plugins where the daemon finds them.
  `docs/design/decoders.md` and `docs/reference/writing-a-decoder.md` are the contract for another.
- Recording: `ley record 146.52 --for 5m` writes what the radio hears to files the daemon keeps --
  WAV audio, or the capture's raw samples with `--iq` -- as a job, so it outlives the terminal that
  started it and what it writes is a resource. `--gate squelch` records only while something is on
  the air and keeps one file per exchange, with the pauses between overs inside it and half a
  second of pre-roll before each key-up; silence is never edited out of a file, and the times
  nothing was recorded are stated in the manifest instead. `ley recordings` lists the store,
  `ley recordings show` prints one's manifest and `ley recordings path` says where it is, so
  `open -R "$(ley recordings path <id>)"` reveals it in Finder. `ley play <id>` hears one back
  whichever kind it is: an IQ recording is tuned as if it were a radio, and an audio recording is
  played by the daemon through the same audio device a channel's audio comes out of, so the sound
  is where the radio is and Ctrl-C stops it. A `Playback` is daemon state, so `ley state` lists
  what is playing and the Mac app can render a position and a stop button; a daemon with no audio
  device falls back to this machine's player (`$LEYLINE_PLAYER`, else `open`). `ley record --listen`
  plays what is going into the file as it records. The `Resources`
  service answers recordings, kept records and scans; `Control.AttachSink(file)` stays refused,
  because a recording is a job's output rather than a sink somebody attached
  (`docs/design/recording.md`).
- `ley mcp`: a Model Context Protocol server an agent's client starts on stdin and stdout, serving the
  daemon's verbs as tools -- `list_devices`, `get_state`, `daemon_logs`, `tune`, `scan`,
  `listen_summary`, `snapshot` (a spectrum PNG and the row), `list_decoders`, `query_records`,
  `list_entities`, `start_decode_job`, `record`, `find_recordings`, `get_recording`, `list_jobs`,
  `get_job`, `cancel_job` -- with a recording's manifest and a kept job's records as the resources
  `ley://recordings/<job_id>` and `ley://records/<job_id>`. Every tool returns the proto3 JSON its
  `ley` mirror prints and a short summary; what an agent starts ends with its conversation unless
  it asks to keep it, and a recording, being a file, always outlives the call
  (`docs/reference/mcp.md`).
- Sweeps take a gain (`ley scan --gain 30|auto`, the MCP tool's `gain`) and say which they ran at; a
  running decode job's detail says how many records it has heard and how long ago; a decode job
  started with `--job` comes back after a daemon restart as the same job; the tone detector holds
  out for a second before naming a PL, so a synthesised voice is no longer one.
- Not yet: watch jobs and transcripts, the TUI dashboard, the Mac app
  (`docs/plans/build-order.md` has the order).
