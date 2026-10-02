# SPDX-License-Identifier: Apache-2.0

# Leyline — top-level developer entry points. See docs/dev/setup.md.
#
#   make proto      regenerate leyline.v1 code (Go + Swift) from proto/
#   make version    regenerate the engine's version constant from the root VERSION file
#   make go         build the Go clients (ley, leyfix) into go/bin
#   make bands-json regenerate the app's seed copy of the band table from `ley bands --json`
#   make go-test    Go unit + contract tests
#   make race       Go tests that exercise goroutines, under the race detector
#   make swift      build the engine (leylined) — macOS for the real thing, Linux compiles the non-DSP core
#   make swift-test engine tests and the optional SDR-library matrix; depends on fixtures so the fixture round-trips actually run (set
#                   LEYLINE_FIXTURES to point the tests elsewhere)
#   make fixtures   generate IQ fixtures into fixtures/ with leyfix (FIXTURE_DURATION=0.5 for a quick set)
#   make e2e        cross-language contract test: `ley` driving a locally built leylined over UDS
#   make eval       the agent evals: an agent on `ley mcp` against fixtures, graded (costs tokens)
#   make app        build the Mac app package (app/): the app and the client façade on macOS, the
#                   façade alone on Linux, where the SwiftUI target is not declared
#   make app-test   the façade's unit tests (no daemon)
#   make app-e2e    the façade against a locally built leylined --no-hardware playing a fixture
#   make app-run    macOS: run the app straight from the package (no bundle, no signature)
#   make app-bundle macOS: assemble and sign app/dist/Leyline.app (scripts/bundle-app.sh)
#   make reload     macOS: rebuild ley and leylined (release), stop the running daemon, reinstall the
#                   LaunchAgent on the new binary and start it — the edit-build-try loop in one step
#   make lint       golangci-lint + gofumpt (pinned versions, installed into .tools/<host>/bin)
#   make check      everything CI runs on this platform (includes the fixture and e2e suites)
SHELL := /bin/bash
GOBIN := $(CURDIR)/go/bin
SWIFT_CONFIG ?= debug
FIXTURE_DURATION ?= 1
# The root VERSION file is the single source of truth. Swift reads a generated constant (make
# version); the Go binaries are stamped at link time. A checkout sitting on the tag v$(VERSION)
# prints the bare number; anything else carries what it actually is — `0.1.0+3-gd34db33-dirty`, or
# `0.1.0-dev+d34db33` before the first tag — so a bug report names one tree.
VERSION := $(shell tr -d '[:space:]' < $(CURDIR)/VERSION)
GIT_DESCRIBE := $(shell git -C $(CURDIR) describe --tags --always --dirty --match 'v*' --abbrev=7 2>/dev/null | sed 's/^v$(VERSION)-//')
BUILD_VERSION := $(if $(filter v$(VERSION),$(shell git -C $(CURDIR) describe --tags --exact-match --match 'v*' 2>/dev/null)),$(VERSION),$(VERSION)$(if $(GIT_DESCRIBE),+$(GIT_DESCRIBE)))
GO_LDFLAGS := -X github.com/reflexive-labs/leysdr/go/internal/cli.Version=$(BUILD_VERSION)
# Repo-pinned developer tools, per host (a checkout shared between a Mac and a Linux container must
# not hand one host the other's binaries). scripts/gen-proto.sh keeps the protoc plugins here too.
HOST := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
TOOLS := $(CURDIR)/.tools/$(HOST)/bin
GOLANGCI_LINT_VERSION := v2.8.0
GOFUMPT_VERSION := v0.9.2

.PHONY: reload all proto proto-check version version-check go go-test bands-json race swift swift-release swift-test sdr-loader-test fixtures e2e eval app app-test app-e2e app-run app-bundle lint check clean install-decoders

all: go swift app

proto:
	./scripts/gen-proto.sh

# Fails if generated code is stale relative to proto/.
proto-check:
	./scripts/gen-proto.sh
	git diff --exit-code -- go/gen swift/LeylineProto/Sources

version:
	./scripts/gen-version.sh

# Fails if the engine's version constant or the Go fallback literal has drifted from VERSION.
version-check:
	./scripts/gen-version.sh
	git diff --exit-code -- engine/Sources/LeylineDaemon/Version.swift
	cd go && go test -count=1 -run TestVersionMatchesTheSourceOfTruth ./internal/cli/

go:
	cd go && GOBIN=$(GOBIN) go install -ldflags '$(GO_LDFLAGS)' ./cmd/...

go-test:
	cd go && go test ./...

# bands.json is the app's seed layer: the band table lives in Go (go/pkg/bandplan/bands.go), the
# app has no Go library, so the sidebar's bands come from the exact bytes `ley bands --json`
# prints, checked in as a resource of the LeylineClient target. TestBandsJSONResource fails when
# the two drift and names this target; the app never edits the file.
bands-json: go
	mkdir -p app/Sources/LeylineClient/Resources
	$(GOBIN)/ley bands --json > app/Sources/LeylineClient/Resources/bands.json

# The verbs stream events on a background goroutine while the foreground reads the session mirror,
# which only the race detector can police; it is a separate target because -race is slow enough that
# nobody would run the whole suite that way.
race:
	cd go && go test -race ./internal/cli/...

swift:
	cd engine && swift build -c $(SWIFT_CONFIG)

swift-release:
	cd engine && swift build -c release

swift-test: fixtures sdr-loader-test
	cd engine && swift test

sdr-loader-test:
	./scripts/test-optional-sdr-loaders.sh

fixtures: go
	$(GOBIN)/leyfix generate --out fixtures --duration $(FIXTURE_DURATION)

# go/internal/e2e skips itself unless both binaries are named, so this is the only place it runs.
# -count=1: the test's inputs are the binaries, which the go test cache does not see.
# --show-bin-path resolves SwiftPM's per-platform directory; the .build/<config> symlink can point
# at another host's build on a shared checkout.
# The decode e2e needs the repository's plugin manifests and the plugin binaries `make go` put beside
# ley: LEYLINE_DECODERS names the manifests and PATH is where the daemon finds `leydec-aprs`.
e2e: go swift fixtures
	cd go && LEYLINED_BIN="$$(cd ../engine && swift build -c $(SWIFT_CONFIG) --show-bin-path)/leylined" LEY_BIN=$(GOBIN)/ley \
		LEYLINE_DECODERS=$(CURDIR)/decoders PATH="$(GOBIN):$$PATH" \
		go test -count=1 -v ./internal/e2e/...

# The daemon under test is the one launchd runs, so a rebuild is only half the loop: the old process
# keeps serving until it is replaced. `ley daemon stop` ends a launchd job or a bare spawn alike;
# `install` rewrites the plist, boots out what is loaded and bootstraps the new binary, so this is
# safe to run whether or not an agent was installed before.
# Copies the repo's decoder plugins (manifest + binary together) into the platform default decoder
# directory the daemon searches, so `ley decode`/`ley watch` find them. Depends on `go` for the
# leydec-* binaries.
install-decoders: go
	GOBIN=$(GOBIN) ./scripts/install-decoders.sh

reload: go swift-release install-decoders
	@[ "$$(uname -s)" = Darwin ] || { echo "make reload drives launchd; run it on the Mac" >&2; exit 2; }
	-$(GOBIN)/ley daemon stop
	$(GOBIN)/ley daemon install --bin $(CURDIR)/engine/.build/release/leylined
	@$(GOBIN)/ley daemon status || { echo "--- leylined log (last 20 lines)" >&2; $(GOBIN)/ley daemon logs | tail -20 >&2; exit 1; }

$(TOOLS)/golangci-lint:
	cd go && GOBIN=$(TOOLS) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

$(TOOLS)/gofumpt:
	cd go && GOBIN=$(TOOLS) go install mvdan.cc/gofumpt@$(GOFUMPT_VERSION)

# Every source file names its licence and every dependency is in third_party/licenses/MANIFEST.txt
# with terms the code that pulls it in may use (docs/decisions/D2-licensing.md). `--fix` adds headers.
license-check:
	./scripts/check-licenses.sh

# The agent evals (docs/dev/evals.md): a daemon per scenario playing fixtures, an agent on `ley
# mcp` against it, graded. Costs tokens, so it is not in `check`; EVAL_ARGS passes scenario names
# or flags through (`make eval EVAL_ARGS="survey-2m --mode shell"`).
eval: go swift fixtures
	cd go && LEYLINED_BIN="$$(cd ../engine && swift build -c $(SWIFT_CONFIG) --show-bin-path)/leylined" LEY_BIN=$(GOBIN)/ley \
		LEYLINE_FIXTURES=$(CURDIR)/fixtures LEYLINE_DECODERS=$(CURDIR)/decoders PATH="$(GOBIN):$$PATH" \
		go run ./cmd/leyeval run --scenarios $(CURDIR)/evals/scenarios --out $(CURDIR)/evals/runs $(EVAL_ARGS)

# The Mac app (docs/dev/app.md). One package at app/, depending on swift/LeylineProto for the
# generated contract and on the engine package not at all. `swift test` in app/ would run the
# daemon-backed suite too and silently skip it without LEYLINED_BIN, so the two targets name their
# suites: app-test skips it, app-e2e is the only place it runs, with the daemon `make swift` built
# and the fixtures the file device plays.
app:
	cd app && swift build -c $(SWIFT_CONFIG)

app-test:
	cd app && swift test --skip LeylineClientDaemonTests

app-e2e: swift fixtures
	cd app && LEYLINED_BIN="$$(cd ../engine && swift build -c $(SWIFT_CONFIG) --show-bin-path)/leylined" \
		LEYLINE_FIXTURES=$(CURDIR)/fixtures swift test --filter LeylineClientDaemonTests

app-run:
	@[ "$$(uname -s)" = Darwin ] || { echo "the app runs on the Mac" >&2; exit 2; }
	@mkdir -p tmp
	cd app && LEYLINE_APP_LOG=$(CURDIR)/tmp/leyline-app.log swift run -c $(SWIFT_CONFIG) LeylineApp

app-bundle:
	./scripts/bundle-app.sh $(BUNDLE_ARGS)

# swift-format ships in the toolchain; app/.swift-format pins its defaults at four spaces and 100
# columns (docs/dev/swift-style.md, "Files"). app-format rewrites, app-lint only reports.
app-format:
	cd app && swift format --in-place --recursive Sources Tests Package.swift

app-lint:
	cd app && swift format lint --strict --recursive Sources Tests Package.swift

lint: $(TOOLS)/golangci-lint $(TOOLS)/gofumpt
	cd go && $(TOOLS)/golangci-lint run ./... && test -z "$$($(TOOLS)/gofumpt -l .)"

check: proto-check version-check license-check go-test race lint swift swift-test e2e app app-test app-e2e

clean:
	rm -rf go/bin engine/.build swift/LeylineProto/.build app/.build app/dist
