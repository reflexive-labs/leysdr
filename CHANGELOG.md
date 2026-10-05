# Changelog

What changed for someone using Leyline, newest first. Each released version has a dated section;
`## Unreleased` collects what the next one will carry.

## Unreleased

The first alpha: a signed, notarized Mac app for a small group of testers.

- **Install.** Leyline is a Mac app (Apple silicon, macOS 26 or later) delivered as a DMG. It
  carries its own RTL-SDR and HackRF drivers, so nothing else needs installing. On first launch it
  registers its engine as a login item, listed in System Settings > General > Login Items &
  Extensions. Leyline > Check for Updates… installs newer alphas.
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

Not in this alpha: the terminal dashboard, audio transcripts, channel occupancy, and builds for
Intel Macs. Leyline only receives; it never transmits.

Report problems with what you did, what you expected, and `ley daemon logs` (or
`~/Library/Logs/Leyline/leylined.log`) from around the time it happened.
