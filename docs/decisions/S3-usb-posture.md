# S3 — USB posture: librtlsdr + libhackrf over libusb now, IOUSBHost later

Status: decided for v0 (2026-09-05). Provisional on one point, flagged below.

## Decision

The USB driver bindings are **librtlsdr** (Homebrew `librtlsdr`) and **libhackrf** (Homebrew
`hackrf`), both libusb-backed and wrapped behind `RadioDevice`, running **unsandboxed** in a user
launchd agent. IOUSBHost is not used in v0.

## Why

- CLAUDE.md prefers first-party driver bindings; librtlsdr *is* the reference driver, GPL is fine
  for the open-source engine, and it gives us the tuner tables, gain lists, bias-tee, direct
  sampling and async streaming for free. Reimplementing RTL2832U/R820T register programming over
  IOUSBHost is weeks of work with no user-visible benefit at v0.
- The daemon is distributed direct + notarized, not through the App Store, so the App Sandbox is
  optional. libusb needs no kernel extension on macOS and no entitlements when unsandboxed; the
  only permission that matters is that no other process has the interface claimed.
- HackRF has the same shape (`libhackrf`, libusb) — one posture covers both devices on the roadmap.

## What this costs

- Homebrew dependencies for each local radio (`brew install librtlsdr` and/or `brew install
  hackrf`). The daemon runtime-loads them independently, so users install only what their hardware
  needs and a missing library does not stop the daemon. `scripts/bootstrap-mac.sh` supports either
  alone; bundling driver dylibs + `libusb` inside the app/daemon remains a later option.
- No hot-plug callbacks from librtlsdr: the registry polls enumeration once a second (cheap:
  descriptor reads only). IOKit `IOServiceAddMatchingNotification` on the RTL vendor/product IDs is
  the obvious refinement and does not change the posture.
- A sandboxed future (App Store, or a hardened daemon) would need the `com.apple.security.device.usb`
  entitlement and, for a sandboxed *daemon*, an XPC-free way to reach USB — which is exactly what
  IOUSBHost provides. That is the later switch: `RTLSDRDevice` keeps its interface; only the
  transport underneath changes.

## Provisional item

Sandboxed-vs-unsandboxed behaviour of libusb on the current macOS release has **not** been measured
in this environment (no Mac hardware in the container). The spike's remaining artifact is a
five-minute check on the host: run `leylined` in the foreground with a Nooelec plugged in, confirm
`ley devices` lists it, then confirm that a second process (`rtl_test`) reports the device busy —
proving the daemon owns the interface exclusively. Record the macOS version and librtlsdr version
here when done.

## Consequence for CLAUDE.md

No change to the licensing/driver line: "prefer first-party driver bindings (librtlsdr, libhackrf,
vendor SDKs) wrapped behind `RadioDevice`" already describes this decision.
