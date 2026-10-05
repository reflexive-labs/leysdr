# S3 — USB posture: librtlsdr + libhackrf over libusb now, IOUSBHost later

Status: decided for v0 (2026-09-05) and current; where the libraries come from was decided
2026-10-05 ("Where the libraries come from"). The sandbox measurement below remains open.

## Decision

The USB driver bindings are **librtlsdr** (Homebrew `librtlsdr`) and **libhackrf** (Homebrew
`hackrf`), both libusb-backed and wrapped behind `RadioDevice`, running **unsandboxed** in a user
launchd agent. IOUSBHost is not used in v0.

**A distributed build carries the libraries; a build from source loads Homebrew's.** The app's
disk image ships `librtlsdr.0.dylib`, `libhackrf.0.dylib` and the `libusb-1.0.0.dylib` both link
in `Leyline.app/Contents/Frameworks`, signed with the same Developer ID team as `leylined`.

## Why

- `AGENTS.md` prefers first-party driver bindings; librtlsdr is the reference driver and supplies
  tuner tables, gain lists, bias-tee, direct sampling and asynchronous streaming. Reimplementing
  RTL2832U/R820T register programming over
  IOUSBHost is weeks of work with no user-visible benefit at v0.
- The daemon is distributed direct + notarized, not through the App Store, so the App Sandbox is
  optional. libusb needs no kernel extension on macOS and no entitlements when unsandboxed; the
  only permission that matters is that no other process has the interface claimed.
- HackRF has the same shape (`libhackrf`, libusb) — one posture covers both devices on the roadmap.

## Where the libraries come from

Decided 2026-10-05, for the signed build.

- **Why bundled.** Notarization requires the hardened runtime, and the hardened runtime turns on
  library validation: a process may load only libraries signed by Apple or by its own team.
  Homebrew's driver libraries are ad-hoc signed, so a notarized `leylined` could not load them and
  would list no radios. Copies signed with the team's identity pass, library validation stays on,
  and `leylined` carries no entitlements. A tester installs nothing, and the release pins the
  driver versions it was tested with.
- **How.** `scripts/bundle-app.sh --with-daemon` copies the three libraries from Homebrew on the
  build Mac, rewrites each id to `@rpath/<name>` and each reference to another of the three to
  `@loader_path/<name>`, signs them, and fails naming the library if a copy still links into
  `/opt/homebrew` or `/usr/local`. It records each library's formula, version, source URL and
  SHA-256 in `Contents/Resources/drivers.json`, the source a release owes
  (`docs/decisions/D2-licensing.md`, "Distribution obligations").
- **Load order.** The loaders in `engine/Sources/CRTLSDR/loader.c` and
  `engine/Sources/CHackRF/loader.c` try, in order: `LEYLINE_RTLSDR_LIBRARY` or
  `LEYLINE_HACKRF_LIBRARY` when set; the bundled copy at
  `@executable_path/../Frameworks/<name>` (`leylined` is in `Contents/Helpers`); then the Homebrew
  paths. A build from source has no `Frameworks` directory beside the daemon, so it falls through
  to Homebrew.
- **Costs.** The distributed build is arm64 only, because the copies come from Homebrew's arm64
  bottles; a universal build needs universal driver libraries, which Homebrew does not provide.
  Every release owes the source of librtlsdr (GPL-2.0-or-later) and libusb (LGPL-2.1-or-later).
- **Rejected.** The `com.apple.security.cs.disable-library-validation` entitlement with Homebrew
  as a prerequisite, which costs every tester a `brew install` and weakens the hardening; and
  bundled-then-Homebrew, which needs that same entitlement.

## What this costs

- A build from source needs a Homebrew dependency for each local radio (`brew install librtlsdr`
  and/or `brew install hackrf`). The daemon loads them at runtime and independently, so a missing
  library does not stop the daemon. `scripts/bootstrap-mac.sh` supports either alone. The app
  carries both ("Where the libraries come from").
- No hot-plug callbacks from librtlsdr: the registry polls enumeration once a second (cheap:
  descriptor reads only). IOKit `IOServiceAddMatchingNotification` on the RTL vendor/product IDs is
  a possible refinement and does not change the decision.
- A sandboxed future (App Store, or a hardened daemon) would need the `com.apple.security.device.usb`
  entitlement and, for a sandboxed *daemon*, an XPC-free way to reach USB — which is exactly what
  IOUSBHost provides. That is the later switch: `RTLSDRDevice` keeps its interface; only the
  transport underneath changes.

## Provisional item

Sandboxed-versus-unsandboxed behaviour of libusb on the current macOS release has **not** been
recorded. The remaining check is to run `leylined` in the foreground with a Nooelec plugged in, confirm
`ley devices` lists it, then confirm that a second process (`rtl_test`) reports the device busy —
proving the daemon owns the interface exclusively. The check is also run against the app's
bundled daemon on a Mac without Homebrew. Record the macOS version and librtlsdr version here when
done.

## Consequence for `AGENTS.md`

No change to the licensing/driver line: "prefer first-party driver bindings (librtlsdr, libhackrf,
vendor SDKs) wrapped behind `RadioDevice`" already describes this decision.
