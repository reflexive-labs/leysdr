# Plan: a signed alpha build

Status: draft, 2026-10-05. Implements E.7 of `build-order.md` (APP-7 in `app.md`). Companion to
`../decisions/S3-usb-posture.md`, whose driver posture this changes for distributed builds, and
`../decisions/D2-licensing.md`, whose per-release obligations it adds to. The release pass is
`../dev/release-checklist.md`. Legend: `[ ]` pending, `[x]` done, `[-]` dropped with the reason,
`[d]` waiting on an owner or external prerequisite.

## Context

Alpha testers need a build they can download, open and use with an RTL-SDR or a HackRF without
cloning the repository, installing Homebrew or running `ley daemon install`. Today
`scripts/bundle-app.sh --with-daemon` lays out `Leyline.app` with `leylined`, `ley`, the decoders
and the licence texts under `Contents/Helpers`, ad-hoc signed. Four things stand between that
bundle and a tester:

- **A Developer ID signature breaks the radios.** Notarization requires the hardened runtime,
  and the hardened runtime turns on library validation: a process may load only libraries signed
  by Apple or by its own team. Homebrew's `librtlsdr.0.dylib` and `libhackrf.0.dylib` are ad-hoc
  signed, so the `dlopen` in `CRTLSDR/loader.c` and `CHackRF/loader.c` fails and the device list
  is empty. The ad-hoc build works only because it does not opt into the hardened runtime.
- **Nothing starts the bundled daemon.** The app tells the user to run `ley daemon start`.
- **Nothing updates the build.** An alpha ships often; a tester on a stale build files stale bugs.
- **The repository is private.** GitHub Releases on it are not downloadable by testers, and the
  GPL obligation to provide source travels with every binary handed out, alpha builds included.

## Decisions (2026-10-05)

- **The driver libraries ship inside the app.** `librtlsdr`, `libhackrf` and the `libusb` both
  link go in `Contents/Frameworks`, their load commands rewritten to `@loader_path`, signed with
  the team's Developer ID. Library validation stays on and `leylined` carries no entitlements.
  Testers install nothing; the release pins the driver versions. The cost is arm64 only (the
  copies come from Homebrew's bottles on the build Mac) and a source obligation for librtlsdr
  (GPL-2.0-or-later) and libusb (LGPL-2.1-or-later) on every release. libhackrf is BSD-3-Clause.
  Rejected: the `com.apple.security.cs.disable-library-validation` entitlement with Homebrew
  kept as a prerequisite, which costs every tester a `brew install` and weakens the hardening;
  and bundled-then-Homebrew, which needs that same entitlement.
- **The app owns the daemon's launch agent through `SMAppService`.** The plist lives in
  `Contents/Library/LaunchAgents/com.leysdr.daemon.plist` with `BundleProgram` pointing at
  `Contents/Helpers/leylined`; the app registers it on first launch. It shows in System Settings,
  Login Items, under the team name, survives the app being moved and goes with the app when it is
  deleted. `ley daemon install` keeps working for source builds and refuses when the app has
  registered the job, because both use the label `com.leysdr.daemon`. Rejected: the app running
  `ley daemon install --bin <bundle>/…`, which writes an absolute path that breaks when the app
  moves and shows in Login Items with weaker attribution.
- **Sparkle 2 from the first build.** The app checks an appcast, downloads, verifies the EdDSA
  signature and replaces itself; then it restarts the daemon onto the new binary.
- **Apple silicon only** for the alpha. A universal build needs universal driver libraries, which
  Homebrew does not provide.
- **`ley` is reached through a symlink** to `Contents/Helpers/ley`, documented in the install
  guide. A menu item or a Homebrew cask can do it later.
- **Every release changes `VERSION`** (`0.1.0-alpha.1`, `0.1.0-alpha.2`, …; the release
  checklist already bumps it). The DMG is `Leyline-<VERSION>.dmg`, its notes are that version's
  `CHANGELOG.md` section, and the app restarts a daemon whose version differs from its own
  `CFBundleShortVersionString`. `CFBundleVersion` is `git rev-list --count HEAD`, which Sparkle
  compares.
- **Not TestFlight.** TestFlight for the Mac takes App Store builds only, and an App Store build
  must be sandboxed (`../decisions/D2-licensing.md`, "Distribution obligations").

## Owner prerequisites

- `[x]` **OWN-1** A Developer ID Application certificate in the build Mac's login keychain.
  `security find-identity -v -p codesigning` lists it; `CODESIGN_IDENTITY` takes its full name.
  Done 2026-10-05: team Reflexive Labs LLC, team ID `P2KZW25PL8`, enrolled as the organization;
  the `.p12` is backed up off the machine.
- `[x]` **OWN-2** Notarization credentials stored as a keychain profile:
  `xcrun notarytool store-credentials leysdr-notary --apple-id … --team-id …` with an
  app-specific password, or `--key`/`--key-id`/`--issuer` with an App Store Connect API key.
  Nothing of it enters the repository. Done 2026-10-05 as the profile `leysdr-notary` with an
  app-specific password; CI's API key is not set up.
- `[x]` **OWN-3** A Sparkle EdDSA key pair: Sparkle's `generate_keys` stores the private key in
  the keychain and prints the public key, which goes into `Info.plist` as `SUPublicEDKey`.
  Losing the private key means no existing install can update again, so export a backup
  (`generate_keys -x`) somewhere off the machine. Done 2026-10-05; the public key is
  `Ct1EXtjnkBDyBIT/onW9Yq4oohjUvDYzIhzwt9TCgOw=` and the private key is backed up.
- `[x]` **OWN-4** Where the appcast is served: `https://leysdr.com/updates/appcast.xml`
  (decided 2026-10-05), published by the site repository's build. The URL is compiled into
  `SUFeedURL`, and installed copies only move to a new one through an update, so it names no
  release track; a second track later is a Sparkle channel (`<sparkle:channel>`) in the same
  feed. The DMGs and source tarballs are served beside it, from `https://leysdr.com/updates/`;
  "Publishing" below is how they get there.
- `[d]` **OWN-5** Whether D3 (the trademark check) gates a closed alpha or only the first public
  build.

## Items

### DIST-1 `[ ]` Driver libraries in the bundle

- `bundle-app.sh --with-daemon` copies `librtlsdr.0.dylib`, `libhackrf.0.dylib` and
  `libusb-1.0.0.dylib` from `$(brew --prefix <formula>)/lib` into `Contents/Frameworks`. It
  rewrites each library's id to `@rpath/<name>` and each reference to another of the three to
  `@loader_path/<name>` with `install_name_tool`, then signs each one. It fails, naming the
  library, when `otool -L` still shows a path under `/opt/homebrew` or `/usr/local`, and when a
  formula is missing (the build Mac needs all three; the alpha carries both drivers).
- It writes `Contents/Resources/drivers.json`: each library's formula, version and source URL from
  `brew info --json=v2`, so a release knows what source it owes.
- Both loaders try `@executable_path/../Frameworks/<name>` before the Homebrew paths.
  `leylined` sits at `Contents/Helpers/leylined`, so that is `Contents/Frameworks`. A build from
  source has no such directory and falls through to Homebrew as today. `LEYLINE_*_LIBRARY` still
  wins.
- The licence texts for libusb go beside librtlsdr's and libhackrf's under `Contents/Helpers`.

Verification: `scripts/test-optional-sdr-loaders.sh` gains a case that places the fake libraries
in a `Frameworks` directory beside a fake `Helpers/` and loads them with no environment override
(Linux resolves `$ORIGIN` instead; the test covers the candidate order, the Mac run covers the
path). On the Mac: `otool -L` on each bundled library, and `ley devices` against the bundled
daemon with Homebrew's copies moved aside.

### DIST-2 `[ ]` The daemon runs from the bundle

- **The agent plist** (`app/Sources/LeylineApp/com.leysdr.daemon.plist`, excluded from the
  target and copied by `bundle-app.sh`): `Label`, `BundleProgram`, `RunAtLoad`,
  `KeepAlive.SuccessfulExit = false` (as `ley daemon install`'s plist: a clean stop stays
  stopped), `AssociatedBundleIdentifiers = [com.leysdr.app]`. `ProgramArguments` cannot expand
  `~`, so the daemon must find its paths without the plist's help:
  - `leylined` searches `<its own directory>/decoders` after the configured and default decoder
    directories, so the bundled decoders work without being copied out;
  - `leylined --log-file <path>` appends stdout and stderr to the file, expanding a leading `~/`.
    The plist passes `--log-file ~/Library/Logs/Leyline/leylined.log`, where `ley daemon logs`
    already looks. The socket already defaults to the right path.
- **Registration from the app.** On launch, unless the app was started with `LEYLINE_SOCKET` set
  (the shots and e2e runs), the app reads `SMAppService.agent(plistName:).status`:
  - `.notRegistered`: if `~/Library/LaunchAgents/com.leysdr.daemon.plist` exists, a source
    build's daemon owns the label, so the app registers nothing and connects as today. Otherwise
    it calls `register()`.
  - `.requiresApproval`: the connection failure state says that Login Items has the daemon
    switched off and offers a button that calls `SMAppService.openSystemSettingsLoginItems()`.
  - `.enabled`: connect as today.
  - `.notFound`: a bundle built without `--with-daemon` has no agent plist; register nothing.
  The failure state's `ley daemon start` instruction remains for a source build.
- **`ley daemon install` and `uninstall` refuse an app-registered job.** `launchctl print
  gui/<uid>/com.leysdr.daemon` shows the program path; one inside `*.app/Contents/Helpers/`
  means the app registered it, and the error says so and names Login Items. `start` and
  `stop` use launchctl when the plist exists or `launchctl print` finds the label loaded
  (`kickstart -k` to start, `kill SIGTERM` to stop), so they drive the app's job too; `status`
  and `logs` needed no change.
- **After an update the daemon is restarted.** When the app connects and the daemon's version
  (`State.daemon.version`) differs from the bundle's `CFBundleShortVersionString` + build, and
  the agent is the app's (`.enabled`), the app runs `launchctl kickstart -k
  gui/<uid>/com.leysdr.daemon` if no job is running. With a recording or decode job running it
  shows "Leyline was updated; restart the engine to finish" with a Restart button instead,
  because a restart ends the job.
- **Uninstall:** quitting the app leaves the daemon running, and a deleted app's registration
  lingers in Login Items, so `install.md` switches it off there first, then trashes the app and
  removes the data directories.

Verification: the decoder search path and `--log-file` in the engine suite; the install refusal in
`go/internal/cli` against a stubbed `launchctl`; the version comparison in `LeylineClientTests`.
On the Mac (DIST-5): first launch registers, Login Items shows it, a reboot starts it, toggling it
off shows the approval state.

### DIST-3 `[ ]` Sparkle

- `app/Package.swift` depends on `sparkle-project/Sparkle` 2.x inside the `#if os(macOS)` block,
  so Linux never resolves the binary target. `LeylineApp` gains "Check for Updates…" in the app
  menu through `SPUStandardUpdaterController`.
- `Info.plist`: `SUFeedURL` (OWN-4), `SUPublicEDKey` (OWN-3), `SUEnableAutomaticChecks = true`.
  `CFBundleVersion` becomes a number that only grows, `git rev-list --count HEAD`, because
  Sparkle compares it; the `git describe` string moves to a `LeylineBuild` key for the about
  panel and bug reports.
- `bundle-app.sh` copies `Sparkle.framework` into `Contents/Frameworks` and adds the rpath
  `@executable_path/../Frameworks` to `LeylineApp` with `install_name_tool -add_rpath` if the
  build does not.
- `scripts/release-appcast.sh` runs Sparkle's `generate_appcast` over the directory of
  notarized DMGs, signing with the keychain key, and writes `appcast.xml` with release notes
  from the version's `CHANGELOG.md` section.
- `NOTICE`, `third_party/licenses/` and the licence manifest gain Sparkle (MIT), and
  `make license-check` reads `app/Package.resolved` if it does not already.

Verification: on the Mac, version N installed from its DMG updates to N+1 from a local appcast
(`SUFeedURL` overridden with `defaults write com.leysdr.app SUFeedURL file://…`), the daemon is
restarted onto N+1, and `ley daemon status` shows N+1's version.

### DIST-4 `[ ]` Sign, notarize, package

`make release` on the Mac, with `CODESIGN_IDENTITY` and `NOTARY_PROFILE` set:

1. `bundle-app.sh --with-daemon` with `ley` and the decoders built for darwin/arm64.
2. Signing from the inside out, never `codesign --deep`, each with `--options runtime
   --timestamp`: the three driver libraries; Sparkle's `Installer.xpc` and `Downloader.xpc`
   (the latter with `--preserve-metadata=entitlements`), `Autoupdate`, `Updater.app`, then
   `Sparkle.framework`; every executable under `Contents/Helpers`; then the app.
   No Leyline component carries entitlements; Sparkle's `Downloader.xpc` keeps its own, as
   Sparkle's signing instructions require.
3. `codesign --verify --strict --deep` on the app, then a DMG (`hdiutil create -format UDZO`)
   holding the app and an `/Applications` link, signed.
4. `xcrun notarytool submit Leyline-<version>.dmg --keychain-profile "$NOTARY_PROFILE" --wait`;
   on rejection, `notarytool log` prints the reasons and the target fails.
5. `xcrun stapler staple` on the DMG; `spctl -a -t open --context context:primary-signature -v`
   on the DMG and `spctl -a -vvv` on the app inside it.
6. The source the release owes: `git archive` of the tag as `leysdr-<version>-source.tar.gz`,
   and the driver tarballs `drivers.json` names, downloaded and checked against their SHA-256.

`release-appcast.sh` passes `--maximum-deltas 0`: Sparkle's delta updates would be extra files to
serve, and a full DMG is tens of megabytes. `[ ]` The tag is created on GitHub after the build,
so a release's `LeylineBuild` (the about panel) shows the previous tag's describe; tagging
locally before `bundle-app.sh` would fix it.

Everything goes to `dist/<version>/`, with `appcast.xml` from `scripts/release-appcast.sh`
(`--download-url-prefix https://leysdr.com/updates/`, the previous releases' DMGs kept in
`dist/` so the feed lists them).

`make release-publish` creates the GitHub release `v<VERSION>` on this repository as a
prerelease with the DMG, both source tarballs, `drivers.json` and `appcast.xml` as assets, the
same way `make shots-publish` creates a `shots-*` release: refused until HEAD is pushed.

Verification: a Linux test of the pure parts (the version string, the `drivers.json` reader);
the rest only on the Mac, where step 5 is the gate.

### DIST-7 `[ ]` Publishing through leysdr.com

leysdr.com is an Astro build deployed to S3 behind CloudFront (`reflexive-labs/leysdr.com`,
`deploy.yml`) and already pulls `shots-*` releases from this private repository with
`LEYSDR_READ_TOKEN` (`update-shots.yml`, daily, as a pull request). Releases take the same route,
so merging the site's pull request is the step that ships an update to testers:

- A daily (and manually dispatchable) workflow in the site repository finds the newest `v*`
  release, and when it differs from the pinned tag opens a pull request that pins it.
- The site build downloads that release's `appcast.xml`, its DMG and source tarballs, and the
  DMGs of the releases the appcast still lists, into `public/updates/`. The deploy's existing
  cache rules fit: `appcast.xml` revalidates on every request, and the versioned DMG and tarball
  names are cached as immutable.
- A download page links the newest DMG and its source tarballs; it is unlisted while the alpha is
  closed.

This is work in the site repository, which its own agent maintains; this item is the handoff.
Verification: after a merge, `curl -I https://leysdr.com/updates/appcast.xml` shows
`max-age=0`, and the enclosure URL in it downloads a DMG whose `spctl` check passes.

### DIST-5 `[ ]` A second Mac

The checks no build machine can make, done with a DMG downloaded through a browser (so it is
quarantined) onto a Mac that has never built Leyline, or a fresh user account with `app/.build`
renamed:

- `[ ]` Gatekeeper opens the app without a warning beyond "downloaded from the Internet".
- `[ ]` The band table loads. `Bands.builtIn` reads `Bundle.module`, whose generated accessor
  falls back to an absolute path inside the build machine's `app/.build`; if the bundle copied to
  `Contents/Resources` is not found there, the app crashes at launch on any other Mac. The fix,
  if needed, is an accessor that looks in `Bundle.main.resourceURL` first.
- `[ ]` First launch registers the daemon; Login Items lists it under the team name.
- `[ ]` `ley devices` (through the symlink) lists an RTL-SDR and a HackRF with Homebrew absent.
- `[ ]` A second process (`rtl_test`) reports the RTL-SDR busy while the daemon holds it, which
  closes the provisional item in `../decisions/S3-usb-posture.md`.
- `[ ]` `ley devices attach rtltcp <host>:1234` reaches a LAN host. macOS's Local Network privacy
  may block a launch agent's connection to a private address without a prompt; if it does, the
  app's `Info.plist` needs `NSLocalNetworkUsageDescription` and the daemon's connection attributed
  to the app.
- `[ ]` Audio plays from the daemon running as the app's agent.
- `[ ]` The N to N+1 update of DIST-3.

### DIST-6 `[ ]` Documents

- `../guide/install.md` opens with installing the app from the DMG and the `ley` symlink; the
  build from source follows.
- `../decisions/S3-usb-posture.md`: distributed builds carry the libraries; source builds use
  Homebrew.
- `../decisions/D2-licensing.md`, "Distribution obligations", and the release checklist: the
  driver source tarballs and libusb's licence on every release; the checklist gains `make
  release` and DIST-5's checks.
- `app.md` APP-7 points here; `../README.md` lists this page.

## Order

DIST-1 and the engine half of DIST-2 (decoder path, `--log-file`) need no certificate and can
start now. The app half of DIST-2 and DIST-3 touch `LeylineApp` and are written blind on Linux,
so they go to one agent in sequence. DIST-4 needs OWN-1 to OWN-3 to run end to end, but the
script can be written first and run ad-hoc. DIST-5 is the owner's pass on a second Mac and gates
sending the first DMG.
