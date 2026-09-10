# Release checklist

What a tag means: the automated gate is green on both hosts *and* one person has done the pass below
on a Mac with an RTL-SDR plugged in. The gate cannot hear audio or see USB, so the manual pass is not
optional.

## Mechanical

- [ ] `VERSION` bumped, `make version`, committed; the tag will be `v<VERSION>`.
- [ ] `make check` green on the Mac (Accelerate kernels, parity tests, audio sink compile, e2e).
- [ ] `make check` green on Linux (the Go half, the portable engine core, e2e).
- [ ] `CHANGELOG.md` has a dated section for this version.
- [ ] README's status section agrees with `docs/build-order.md`.
- [ ] `docs/decisions/` has a note for any spike or measurement this release relied on.

## Acceptance, on a Mac with a dongle

Run each with the release binaries (`make go swift-release`, `export PATH=$PWD/go/bin:$PATH`).

- [ ] `ley daemon install --bin $PWD/engine/.build/release/leylined`; `ley daemon status` reports the
      version being released; `ley daemon logs` shows a clean start.
- [ ] `ley devices` lists the dongle with its tuner gain table; unplug it, `ley devices` shows it gone;
      replug, it is back under the same id.
- [ ] `ley play fixtures/nfm_tone.cf32` — a 1 kHz tone is audible from the Mac's output device.
- [ ] `ley tune <a local broadcaster> --mode wfm` — audible, stereo pilot does not buzz.
- [ ] `ley tune <a local NFM repeater or NOAA>` — audible, squelch closes on silence; from a second
      terminal `ley set squelch -45`, `ley set gain 30`, `ley set bw 25`, each confirmed in the first
      terminal's session line.
- [ ] `ley spectrum` and `ley waterfall` on the same capture draw the station where `tune` says it is.
- [ ] `ley scan 144M..148M` (or a band you know) finds the carriers you expect; a second run at
      `--dwell 500` reports them at the same frequencies (the settle-constant check in
      `docs/design-scan.md`).
- [ ] Two channels on one capture: `ley tune A --persistent`, `ley tune B` in another terminal, both
      audible, `ley stop all` frees the radio.
- [ ] Ctrl-C in a `tune` session hands the radio back (`ley state` shows no channel); a hard kill of
      the terminal does the same within about five seconds.
- [ ] `ley daemon uninstall` stops the daemon and removes the LaunchAgent.

Record the machine, macOS version, dongle and date at the bottom of the release notes.
