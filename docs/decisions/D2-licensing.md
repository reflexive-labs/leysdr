# D2: Licensing and monetization

Status: decided 2026-09-12. Resolves D2 in `docs/plans/v1-release.md`. `LICENSE`, `engine/LICENSE`,
`NOTICE`, `TRADEMARK.md`, `third_party/licenses/` and `scripts/check-licenses.sh` implement it;
`CONTRIBUTING.md` carries the inbound-licence clause.

Not legal advice. The trademark filing and the contributor terms should be reviewed by counsel
before the repository goes public.

## Decision

**Everything ships open source.** There is no closed component. Revenue comes from the notarized
build and a curated content layer, not from withheld source.

Rationale: the only legally forced constraint is that the daemon links librtlsdr and must therefore
be GPL. Nothing else is forced. Closing the app or the MCP adapter would cost a private repo, a
split build and release pipeline, licence-key infrastructure, and a public/private boundary to
police in every refactor: recurring work on the scarcest resource, for a paywall that
self-compiling already defeats. The MCP adapter is additionally a weak paywall on its own terms:
six of nine planned tools are plumbing over public RPCs, so a third-party equivalent is a weekend's
work.

## Licence assignment

| Path | Licence | Why |
|---|---|---|
| `engine/` (leylined) | GPL-3.0-or-later | Forced: links librtlsdr (GPL-2.0-or-later). Must be v3, not v2-only, because the daemon also links Apache-2.0 Swift packages, which are incompatible with GPLv2-only. librtlsdr's "or later" permits this. |
| `proto/`, generated code (`go/gen`, `swift/LeylineProto`), `go/pkg/leyline` and the other `go/pkg` packages | Apache-2.0 | The contract and client library. Must stay permissive so any consumer, including a future commercial one, can link them. |
| `go/cmd/ley`, `go/internal/*` | Apache-2.0 | No copyleft dependencies. Permissive keeps R-13 (moving CLI behaviour into the client library) a file move rather than a relicensing exercise, and makes `ley` forkable as a starting point for third-party tools. |
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
auto-updates, plus access to the curated content layer. Source remains fully available; anyone can
compile their own. Compiling a Swift daemon with a launchd agent and USB entitlements is enough
friction that most buyers will pay, and the ones who don't are contributors rather than lost
revenue. Precedent: Sublime Merge, Dash, and most Mac indie software; hams routinely spend far more
on hardware than on software.

Not doing: licence keys, feature gating, telemetry-based enforcement, or any DRM. Payment works on
the honour system.

Explicitly out of scope: paid support tiers.

## What must be preserved regardless

These two keep every future option open (commercial licence, OEM deal, appliance partnership)
without deciding anything today.

1. **Copyright stays with the project owner.** Contributions are inbound Apache-2.0, outbound
   GPL-3.0 for the engine. A DCO alone would lock the licence in permanently; an assignment CLA
   deters contributors. Inbound-permissive/outbound-copyleft is the middle path and is in
   `CONTRIBUTING.md` before the first outside PR, not after.
2. **Trademark.** File "Leyline" (intent-to-use, software class) before the repo goes public, after
   a clearance search; there are existing users in other classes. The code licence does not grant
   use of the name. The licence cannot stop someone shipping "Leyline Pro"; the trademark can.
   `TRADEMARK.md` is the policy.

Also keep maintained: the `RTLTCPDevice` path, CI-tested as a first-class device backend rather
than a contingency. It costs a loopback copy (about 4.8 MB/s per radio, a millisecond or two
against the 50 ms S1 budget) and is the standing escape hatch if a proprietary daemon is ever
required for a partnership. Do not let it bit-rot. Its coverage today: `RTLTCPTests` and
`RemoteDeviceTests` in the engine suite, `TestRemoteRadioAgainstRealDaemon` in the e2e, all run
by `make check` on both CI hosts.

## Repository layout

Single public monorepo. The earlier plan to split public/private is dropped along with the closed
components. The client library must remain independently consumable as a Go module, so that a
commercial consumer (ours or someone else's) never needs to vendor GPL code.

## Distribution obligations

On every binary release (`docs/dev/release-checklist.md` carries these as checklist items):

- GPL source offer for the daemon (a link to the tagged source suffices).
- `NOTICE` file covering the Apache-2.0 dependencies.
- librtlsdr's licence text alongside (`third_party/licenses/librtlsdr.txt`).
- Direct + notarized distribution. Not the App Store: the GPL conflicts with its terms, and the
  daemon needs USB entitlements a sandboxed app cannot hold.

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

Blocking on public release: trademark clearance search and filing (D3 in the release plan).

## Follow-on

The content layer is now load-bearing for revenue and has no specification. It needs one before
v1 pricing is announced: R-22 in `docs/plans/v1-release.md` is the requirements document. Sketch of
what it covers: band plans, decoder recipe bundles, listening presets, CHIRP mappings, regional
frequency databases. Open questions include update cadence, distribution mechanism (in-app fetch
vs. git), which packs are free versus paid, community submission and curation, and the licence per
pack.
