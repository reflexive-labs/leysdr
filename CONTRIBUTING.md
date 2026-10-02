# Contributing to Leyline SDR

Leyline SDR is a receive-only SDR for macOS: a Swift daemon (`leylined`) that owns the radio and
does the signal processing, and clients (`ley`, the Mac app, scripts, agents) that drive it over
one gRPC contract.

## Build and test

[`docs/dev/setup.md`](docs/dev/setup.md) has the full setup. In short, on a Mac:

```sh
make go swift-release fixtures   # ley, leylined, the IQ fixtures
make check                       # what CI runs: generated code, Go tests, lint, engine, e2e, app
```

No radio is needed. The tests play generated IQ fixtures through the whole pipeline, and the `ley`
tests run against an in-memory fake of the daemon (`go/internal/fakedaemon`).

Linux can build and test the Go half and most of the engine, including the end-to-end tests. The
Mac app's views, the Accelerate DSP kernels and audio output need a Mac.

## Where things live

| path | what |
|---|---|
| `proto/leyline/v1` | the contract |
| `engine/` | the daemon and its DSP (Swift) |
| `app/` | the Mac app (SwiftUI) |
| `go/` | `ley`, the Go client library, the decoders, test tools |
| `decoders/` | decoder manifests |
| `docs/` | the [docs map](docs/README.md): guides, reference, design, contributor contracts, plans |

## Proposing a change

- **Open an issue first for anything large** (a new feature, a contract change, a new
  dependency), so the approach is agreed before the code is written. Small fixes can go straight
  to a pull request.
- **Keep pull requests small, and one concern per commit.** A commit carries its tests and its
  documentation. The subject is `area: what changed`, under 72 characters (`engine:`, `ley:`,
  `app:`, `proto:`, `docs:`); the body says why.
- **`make check` is green** before you ask for review (it includes both lints and the docs check).
- **Proto changes are additive.** New fields get new numbers; nothing is renamed, retyped or
  renumbered. Never hand-edit generated code (`go/gen`, `swift/LeylineProto`); run `make proto`.
- **Signal processing stays in the daemon.** Clients only render, so a feature works the same
  from `ley`, the app and an agent.

## Sign-off

Every commit carries a `Signed-off-by:` line (`git commit -s`). It certifies the
[Developer Certificate of Origin](https://developercertificate.org): you wrote the change or have
the right to submit it under the terms below. `git config core.hooksPath scripts/git-hooks` adds
the line automatically in this clone. CI checks every commit in a pull request, and
`git rebase --signoff origin/main` adds a missing line to each.

## Licensing

You keep the copyright in your contribution and license it to the project under Apache-2.0,
whichever directory it lands in. The project distributes it under the licence of that directory:

- **The engine (`engine/`, `leylined`) ships as GPL-3.0-or-later**, because it links librtlsdr,
  which is GPL.
- **Everything else is Apache-2.0**: the contract, the generated code, the client library, `ley`,
  the decoders and the app.

Because contributions come in under Apache-2.0, Reflexive Labs, LLC, the copyright holder, may also
offer the engine under other licences. [`docs/decisions/D2-licensing.md`](docs/decisions/D2-licensing.md)
records the decision.

New source files carry an `SPDX-License-Identifier` line (`scripts/check-licenses.sh --fix` adds
it). A new dependency needs a row in `third_party/licenses/MANIFEST.txt`, its licence text, and an
entry in `NOTICE`; `make license-check` tells you what is missing.

## Style

- [Writing guide](docs/writing-guide.md): documentation, help texts, error messages, comments and
  commit messages.
- [Swift style](docs/dev/swift-style.md): Swift in the engine and the app.
- [CLI style](docs/dev/cli-style.md): anything a `ley` user sees.

## AI-assisted contributions

They are welcome. The person who submits the change is responsible for it, as for any other.
[`AGENTS.md`](AGENTS.md) is the condensed rule list for coding agents working on this repository.

## Questions and security

Open an issue for questions. For a security problem, read [`SECURITY.md`](SECURITY.md) and report
it privately.
