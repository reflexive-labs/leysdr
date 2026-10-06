# D2: Licensing and monetization

Status: decided 2026-09-12 and current. `LICENSE`, `engine/LICENSE`,
`NOTICE`, `TRADEMARK.md`, `third_party/licenses/` and `scripts/check-licenses.sh` implement it;
`CONTRIBUTING.md` contains the inbound-licence clause.

Not legal advice.

## Decision

**Everything ships open source.** There is no closed component. The commercial plan is a paid,
notarized build and curated content rather than withheld source.

Rationale: the only legally forced constraint is that the daemon links librtlsdr and must therefore
be GPL. Nothing else is forced. Closing the app or MCP adapter would require a private repository,
a split build and release pipeline, licence-key infrastructure and a maintained public/private
boundary. The public contract also permits a third party to implement an equivalent client.

## Licence assignment

| Path | Licence | Why |
|---|---|---|
| `engine/` (leylined) | GPL-3.0-or-later | Forced: links librtlsdr (GPL-2.0-or-later). Must be v3, not v2-only, because the daemon also links Apache-2.0 Swift packages, which are incompatible with GPLv2-only. librtlsdr's "or later" permits this. |
| `proto/`, generated code (`go/gen`, `swift/LeylineProto`), `go/pkg/leyline` and the other `go/pkg` packages | Apache-2.0 | The contract and client library. Must stay permissive so any consumer, including a future commercial one, can link them. |
| `go/cmd/ley`, `go/internal/*` | Apache-2.0 | No copyleft dependencies. The permissive licence allows CLI behaviour to move into the client library and makes `ley` a starting point for third-party tools. |
| MCP adapter | Apache-2.0 | Same repo, same terms. |
| Mac app | Apache-2.0 | SwiftUI over the client library; zero GPL contact. |
| Content packs (see below) | CC-BY-SA or similar, per pack | Data, not code. Decide per source; community contributions likely require share-alike. |

The GPL reaches only what links librtlsdr. Every client is a separate process communicating over
a documented socket protocol, which on the FSF's reading makes them separate works. The process
boundary exists for crash isolation and to let clients use any language. It also serves as the
licence boundary.

Every source file carries an `SPDX-License-Identifier` line matching the table; generated files
inherit theirs from the `.proto` they came from, so the Apache-2.0 line survives `make proto`.

## Monetization

**Sell the build; the source stays free.** Paid tier is a signed, notarized installer with Sparkle
auto-updates, plus access to the curated content layer. Source remains fully available and can be
compiled independently. The paid product provides signed distribution and update maintenance.

Not doing: licence keys, feature gating, telemetry-based enforcement, or any DRM. Payment works on
the honour system.

Explicitly out of scope: paid support tiers.

## What must be preserved regardless

These two preserve the option of a commercial licence, OEM deal or appliance partnership.

1. **Copyright stays with the project owner.** Contributions are inbound Apache-2.0, outbound
   GPL-3.0 for the engine. A DCO alone would lock the licence in permanently; an assignment CLA
   deters contributors. Inbound-permissive/outbound-copyleft is the middle path and is in
   `CONTRIBUTING.md` before the first outside PR, not after.
2. **The name.** The code licence does not grant use of the name, so a fork that ships under it
   is answered by the trademark policy, `TRADEMARK.md`, not by the licence.

Also keep maintained: the `RTLTCPDevice` path, CI-tested as a first-class device backend rather
than a contingency. It costs a loopback copy (about 4.8 MB/s per radio, a millisecond or two
against the 50 ms S1 budget) and is the standing escape hatch if a proprietary daemon is ever
required for a partnership. Do not let it bit-rot. Its current coverage: `RTLTCPTests` and
`RemoteDeviceTests` in the engine suite, `TestRemoteRadioAgainstRealDaemon` in the e2e, all run
by `make check` on both CI hosts.

## Repository layout

Single public monorepo. The earlier plan to split public/private is dropped along with the closed
components. The client library must remain independently consumable as a Go module, so that a
commercial consumer (ours or someone else's) never needs to vendor GPL code.

## Distribution obligations

On every binary release (`docs/dev/release-checklist.md` carries these as checklist items):

- GPL source offer for the daemon: the release's source, `leysdr-<version>-source.tar.gz` (a
  `git archive` of the tag), published beside the disk image. While the repository is private a
  link to the tag reaches no one, so the tarball is the offer.
- The source of the driver libraries the app carries in `Contents/Frameworks`
  (`docs/decisions/S3-usb-posture.md`, "Where the libraries come from"): librtlsdr is
  GPL-2.0-or-later and libusb LGPL-2.1-or-later, so their source tarballs are published beside
  every disk image. `Contents/Resources/drivers.json` records each library's formula, version,
  source URL and SHA-256, and the release downloads and checks the tarballs from it. libhackrf is
  BSD-3-Clause and needs only its licence text.
- `NOTICE` file covering the Apache-2.0 dependencies and the app's Sparkle (MIT, with
  BSD-2-Clause, MIT and Zlib parts).
- The licence texts of librtlsdr, libhackrf and libusb alongside the daemon
  (`third_party/licenses/librtlsdr.txt`, `libhackrf.txt`, `libusb.txt`, copied to
  `Leyline.app/Contents/Resources/licenses`).
- Direct + notarized distribution. Not the App Store: the GPL conflicts with its terms, and the
  daemon needs USB entitlements a sandboxed app cannot hold. Not TestFlight either, which takes
  App Store builds only.

## Implementation

- [x] `LICENSE` (Apache-2.0) at repo root; `engine/LICENSE` (GPL-3.0); per-file SPDX headers
      matching the table above, checked by `scripts/check-licenses.sh`.
- [x] `NOTICE` file; vendored third-party licence texts under `third_party/licenses/`, with a
      manifest the check keeps equal to `go.mod`'s graph and `engine/Package.resolved`.
- [x] `CONTRIBUTING.md`: inbound Apache-2.0 clause, DCO sign-off for provenance.
- [x] `README.md` and `SECURITY.md` placeholders replaced.
- [x] `TRADEMARK.md` policy.
- [x] CI check: no GPL-licensed code imported by anything outside `engine/` (`make license-check`,
      in `make check` and the Go CI job).
- [x] `RTLTCPDevice` named as a supported backend in the README and the engine internals, with its
      CI coverage.

## Follow-on

The curated content layer needs a specification before pricing is announced. Its scope includes
band plans, decoder recipes, listening presets, CHIRP mappings and regional frequency databases.
The release plan tracks update cadence, distribution, free and paid packs, community submission,
curation and licences.
