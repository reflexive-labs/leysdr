# Release checklist

What a tag means: the automated gate is green on both hosts *and* one person has done the pass below
on a Mac with an RTL-SDR plugged in. The gate does not test audio output or real USB hardware, so
the manual pass is not optional. A release is a signed, notarized disk image of the app; the
signed build's steps follow the mechanical ones, and the second-Mac checks gate sending a build
to anyone.

## Mechanical

- [ ] Apple Developer Program access is active, a Developer ID Application certificate is installed,
      and notarization credentials are configured without storing them in the repository. Their absence
      blocks the signed release, not the install plumbing.
- [ ] `VERSION` bumped to this release, `make version`, committed; the tag will be `v<VERSION>`.
      Every release changes it: an alpha is `0.1.0-alpha.N`, one more than the last. The disk
      image is named after it, the app restarts a daemon whose version differs from it, and the
      update feed's notes come from its `CHANGELOG.md` section.
- [ ] `make check` green on the Mac (Accelerate kernels, parity tests, audio sink compile, e2e).
- [ ] `make check` green on Linux (the Go half, the portable engine core, e2e).
- [ ] `CHANGELOG.md` has a dated section for this version.
- [ ] README's status section agrees with `docs/plans/build-order.md`.
- [ ] `docs/decisions/` has a note for any spike or measurement this release relied on.

## The signed build

On the build Mac, an Apple silicon Mac with Homebrew's `librtlsdr`, `hackrf` and `libusb`
installed, because the app carries copies of all three (`docs/decisions/S3-usb-posture.md`).

- [ ] `CODESIGN_IDENTITY` is the full name `security find-identity -v -p codesigning` lists
      ("Developer ID Application: …"), and `NOTARY_PROFILE` the `xcrun notarytool
      store-credentials` profile. The Sparkle signing key is in the login keychain.
- [ ] `make release` succeeds. It lays out the app with the daemon, `ley`, the decoders and the
      driver libraries; signs each component from the inside out with the hardened runtime;
      builds and signs `Leyline-<VERSION>.dmg`; submits it for notarization and waits, printing
      the notary log and failing on a rejection; staples the ticket and checks the disk image and
      the app inside it with `spctl`. It writes the source tarballs (the tag's
      `leysdr-<VERSION>-source.tar.gz` and the driver tarballs `drivers.json` lists, each checked
      against its SHA-256) and `appcast.xml` into `dist/<VERSION>/`. Keep the previous releases'
      disk images in `dist/`, because the update feed lists them.
- [ ] `make release-publish` creates the GitHub release `v<VERSION>` on this repository as a
      prerelease, with the disk image, the source tarballs, `drivers.json` and `appcast.xml` as
      assets. It refuses until HEAD is pushed.
- [ ] Merge the leysdr.com pull request that pins the new release. The site's daily workflow
      opens it (or dispatch the workflow to open it now); merging it deploys the disk image, the
      tarballs and `appcast.xml` under `https://leysdr.com/updates/`, which is what installed
      copies check. Then `curl -I https://leysdr.com/updates/appcast.xml` shows `max-age=0`, and
      the newest enclosure URL in it downloads a disk image whose `spctl` check passes.

## Licence obligations, on every binary release

`docs/decisions/D2-licensing.md` is the decision; these are what it costs per release.

- [ ] `make license-check` is green (it is part of `make check`), so every source file names its
      licence and `NOTICE` names every dependency the binaries carry.
- [ ] The app carries `LICENSE`, `engine/LICENSE`, `NOTICE` and the licence texts of librtlsdr,
      libhackrf and libusb beside the daemon in `Contents/Helpers`.
- [ ] The release offers the daemon's source as `leysdr-<VERSION>-source.tar.gz`, served beside
      the disk image. GPLv3 lets a network-distributed binary point at source served the same way,
      so the tarball stays for as long as the disk image is offered. A link to the tag replaces it
      only once the repository is public.
- [ ] The source tarballs of librtlsdr (GPL-2.0-or-later) and libusb (LGPL-2.1-or-later) that
      `Contents/Resources/drivers.json` names are served beside the disk image, for the same
      period.
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
      file. `ley recordings show <id>` shows the radio and the gain it was made at.
- [ ] Gated recording on a live repeater: `ley record <repeater> --gate squelch --for 5m`, key up
      twice with a pause between. One part per exchange, the pauses inside it, and
      `ley recordings show` reports how many times the squelch opened. Note the pre-roll and hang that
      felt right against `docs/design/recording.md`'s open question, which is where the numbers get
      measured.
- [ ] `open -R "$(ley recordings path <id>)"` reveals the recording in Finder, and QuickTime plays
      the WAV.
- [ ] Ctrl-C in a `tune` session hands the radio back (`ley state` shows no channel); a hard kill of
      the terminal does the same within about five seconds. Ctrl-C in a `ley record` session leaves
      the recording complete: `ley recordings show` shows `cancelled` and the last part plays.
- [ ] `ley daemon uninstall` stops the daemon and removes the LaunchAgent.

## Acceptance, on a second Mac

The checks no build machine can make. Download the disk image through a browser, so it is
quarantined, onto a Mac that has never built Leyline, or into a fresh user account with
`app/.build` renamed, and with Homebrew's driver libraries absent.

- [ ] Gatekeeper opens the app with no warning beyond "downloaded from the Internet".
- [ ] The window opens and the bands sidebar lists the built-in bands. The band table is a
      resource bundle inside the app; if the app looks for it in the build Mac's `app/.build`
      instead, it crashes at launch here.
- [ ] First launch registers the daemon: macOS notifies that a background item was added, and
      System Settings > General > Login Items lists it. Switching it off shows "Login Items has
      the engine switched off" in the window; switching it on again connects.
- [ ] After a restart of the Mac, the daemon is running before the app is opened
      (`ley daemon status`).
- [ ] With `ley` linked as `docs/guide/install.md` describes, `ley devices` lists an RTL-SDR and a
      HackRF.
- [ ] While the daemon holds the RTL-SDR, `rtl_test` in a second process reports it busy; record
      the result in `docs/decisions/S3-usb-posture.md`, "Provisional item".
- [ ] `ley devices attach rtltcp <host>:1234` reaches a host on the LAN. If macOS's Local Network
      privacy blocks the daemon without a prompt, the release is not sent until the app declares
      `NSLocalNetworkUsageDescription`.
- [ ] Audio plays from the daemon running as the app's login item.
- [ ] The update: with the previous release installed from its disk image, Leyline > Check for
      Updates… installs this one, the app restarts the daemon, and `ley daemon status` reports this
      release's version. Before the site is updated, point the app at a local feed with
      `defaults write com.leysdr.app SUFeedURL file://<dist>/appcast.xml`, and delete the key
      afterwards.

Record the machine, macOS version, dongle and date at the bottom of the release notes.
