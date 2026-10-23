# Changelog

What changed for someone using Leyline, newest first. Each released version has a dated section;
`## Unreleased` collects what the next one will carry.

## Unreleased

- **AI on your own key.** Settings > AI and `ley ai` add, check and remove a key for Anthropic,
  OpenAI or an OpenAI-compatible endpoint, choose the provider and model for each feature, and
  show what each one used by day and month. The engine keeps the key in the login keychain and
  sends it only to its provider. Adding a key sets every feature it can serve that has no choice
  yet; `ley ai use` changes one.
- **The assistant.** A column beside the inspector (the toolbar's Assistant button, or View >
  Show Assistant) takes plain requests and runs the radio with `ley mcp`'s tools: it tunes, sets
  the squelch, scans, keeps bookmarks, and shows a band, a place or a recording in the window.
  Each step opens to its arguments and result. A call that changes something asks first, in
  words, with Decline, Allow in this chat and Allow, and says when it would take the radio from
  another listener. Stop ends a turn. Conversations are kept across a restart of the engine. The
  assistant never hears the audio.
- **The window follows the radio.** When the assistant or a terminal's `ley tune` makes a
  channel on the window's radio, the readout, the inspector, the transmissions log and the audio
  move to it, and the inspector says who tuned. While the window's old channel is still
  recording, the inspector shows Still recording with a Stop.
- **Speech.** The speech decoder transcribes each over through OpenAI's speech API: `ley
  transcribe` over a recording, `ley decode speech` on a live channel with each over kept as a
  clip, and `ley watch speech --where 'text~net control'`. The Library shows each over's words,
  searches them, plays one over and exports them as text or SRT. `ley play --over`, `--from` and
  `--to` play part of a recording.
- **`ley mcp`.** Eleven more tools: `set`, `stop`, `list_bookmarks`, `add_bookmark`,
  `remove_bookmark`, `list_bands`, `list_presets`, `watch`, `attach_device`, `import_chirp` and
  `help`. `set` asks before it changes another client's channel, and each tool's text starts with
  what it did.
- **The sidebar.** An open band's Scan band and Channels are rows under its header, and the
  words are shorter (`17 bands out of range ›`, `sq auto`). A band the radio cannot tune reads
  disabled. A bookmark near a plan channel reads `≈` and the channel. A scan hit tunes and
  bookmarks the channel it names, or its measured frequency to 100 Hz.
- **Tuning.** The tuning field shows four decimals of MHz, cut and never rounded. A typed
  frequency tunes to the hertz, and Return with nothing typed keeps the exact frequency.
- **Squelch.** A measured squelch reads `auto` in the sidebar and `(auto)` after its level in
  `ley state`, `ley set` and the event lines.
- **Bookmarks.** Leaving a Tone or Note field saves it, as Return does; Escape throws the edit
  away.
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
