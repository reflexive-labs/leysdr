# Changelog

Nothing has been released yet. This file starts with everything that exists on `main`.

## Unreleased

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
- Not yet: recording to files, watch jobs and transcripts, the TUI dashboard, the Mac app, the MCP
  adapter (`docs/plans/build-order.md` has the order).
