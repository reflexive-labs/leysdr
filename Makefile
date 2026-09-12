# SPDX-License-Identifier: Apache-2.0

# Leyline — top-level developer entry points. See docs/dev/setup.md.
#
#   make proto      regenerate leyline.v1 code (Go + Swift) from proto/
#   make version    regenerate the engine's version constant from the root VERSION file
#   make go         build the Go clients (ley, leyfix) into go/bin
#   make go-test    Go unit + contract tests
#   make race       Go tests that exercise goroutines, under the race detector
#   make swift      build the engine (leylined) — macOS for the real thing, Linux compiles the non-DSP core
#   make swift-test engine tests; depends on fixtures so the fixture round-trips actually run (set
#                   LEYLINE_FIXTURES to point the tests elsewhere)
#   make fixtures   generate IQ fixtures into fixtures/ with leyfix (FIXTURE_DURATION=0.5 for a quick set)
#   make e2e        cross-language contract test: `ley` driving a locally built leylined over UDS
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
GO_LDFLAGS := -X github.com/dpup/leysdr/go/internal/cli.Version=$(BUILD_VERSION)
# Repo-pinned developer tools, per host (a checkout shared between a Mac and a Linux container must
# not hand one host the other's binaries). scripts/gen-proto.sh keeps the protoc plugins here too.
HOST := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
TOOLS := $(CURDIR)/.tools/$(HOST)/bin
GOLANGCI_LINT_VERSION := v2.8.0
GOFUMPT_VERSION := v0.9.2

.PHONY: reload all proto proto-check version version-check go go-test race swift swift-release swift-test fixtures e2e lint check clean install-decoders

all: go swift

proto:
	./scripts/gen-proto.sh

# Fails if generated code is stale relative to proto/.
proto-check:
	./scripts/gen-proto.sh
	git diff --exit-code -- go/gen engine/Sources/LeylineProto

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

# The verbs stream events on a background goroutine while the foreground reads the session mirror,
# which only the race detector can police; it is a separate target because -race is slow enough that
# nobody would run the whole suite that way.
race:
	cd go && go test -race ./internal/cli/...

swift:
	cd engine && swift build -c $(SWIFT_CONFIG)

swift-release:
	cd engine && swift build -c release

swift-test: fixtures
	cd engine && swift test

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

lint: $(TOOLS)/golangci-lint $(TOOLS)/gofumpt
	cd go && $(TOOLS)/golangci-lint run ./... && test -z "$$($(TOOLS)/gofumpt -l .)"

check: proto-check version-check license-check go-test race lint swift swift-test e2e

clean:
	rm -rf go/bin engine/.build
