# Release checklist

What a tag means: the automated gate is green on both hosts *and* one person has done the pass below
on a Mac with an RTL-SDR plugged in. The gate cannot hear audio or see USB, so the manual pass is not
optional.

## Mechanical

- [ ] `VERSION` bumped, `make version`, committed; the tag will be `v<VERSION>`.
- [ ] `make check` green on the Mac (Accelerate kernels, parity tests, audio sink compile, e2e).
- [ ] `make check` green on Linux (the Go half, the portable engine core, e2e).
- [ ] `CHANGELOG.md` has a dated section for this version.
- [ ] README's status section agrees with `docs/plans/build-order.md`.
- [ ] `docs/decisions/` has a note for any spike or measurement this release relied on.

## Licence obligations, on every binary release

`docs/decisions/D2-licensing.md` is the decision; these are what it costs per release.

- [ ] `make license-check` is green (it is part of `make check`), so every source file names its
      licence and `NOTICE` names every dependency the binaries carry.
- [ ] The release archive contains `LICENSE`, `engine/LICENSE`, `NOTICE` and `third_party/licenses/`
      (librtlsdr's GPL-2.0 text is among them, beside the daemon that links it).
- [ ] The release notes carry the daemon's source offer: a link to this tag's source tree
      (`https://github.com/dpup/leysdr/tree/v<VERSION>`). GPLv3 lets a network-distributed binary
      point at the source served the same way, so the tag must stay for as long as the binary is
      offered.
- [ ] Distribution is direct and notarized, never the App Store.

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
      `docs/design/scan.md`).
- [ ] Two channels on one capture: `ley tune A --persistent`, `ley tune B` in another terminal, both
      audible, `ley stop all` frees the radio.
- [ ] Record-then-play: `ley record <the same repeater> --iq --for 20s`, then
      `ley play "$(ley recordings path <id> --part 1)"` — the station is audible again from the
      file. `ley recordings show <id>` names the radio and the gain it was made at.
- [ ] Gated recording on a live repeater: `ley record <repeater> --gate squelch --for 5m`, key up
      twice with a pause between. One part per exchange, the pauses inside it, and
      `ley recordings show` says how many times the squelch opened. Note the pre-roll and hang that
      felt right against `docs/design/recording.md`'s open question, which is where the numbers get
      measured.
- [ ] `open -R "$(ley recordings path <id>)"` reveals the recording in Finder, and QuickTime plays
      the WAV.
- [ ] Ctrl-C in a `tune` session hands the radio back (`ley state` shows no channel); a hard kill of
      the terminal does the same within about five seconds. Ctrl-C in a `ley record` session leaves
      the recording complete: `ley recordings show` says `cancelled` and the last part plays.
- [ ] `ley daemon uninstall` stops the daemon and removes the LaunchAgent.

Record the machine, macOS version, dongle and date at the bottom of the release notes.
