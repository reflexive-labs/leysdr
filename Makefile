# Leyline — top-level developer entry points. See docs/dev-setup.md.
#
#   make proto      regenerate leyline.v1 code (Go + Swift) from proto/
#   make go         build the Go clients (ley, leyfix) into go/bin
#   make go-test    Go unit + contract tests
#   make swift      build the engine (leylined) — macOS for the real thing, Linux compiles the non-DSP core
#   make swift-test engine tests; depends on fixtures so the fixture round-trips actually run (set
#                   LEYLINE_FIXTURES to point the tests elsewhere)
#   make fixtures   generate IQ fixtures into fixtures/ with leyfix (FIXTURE_DURATION=0.5 for a quick set)
#   make e2e        cross-language contract test: `ley` driving a locally built leylined over UDS
#   make lint       golangci-lint + gofumpt (pinned versions, installed into .tools/<host>/bin)
#   make check      everything CI runs on this platform (includes the fixture and e2e suites)
SHELL := /bin/bash
GOBIN := $(CURDIR)/go/bin
SWIFT_CONFIG ?= debug
FIXTURE_DURATION ?= 1
# Repo-pinned developer tools, per host (a checkout shared between a Mac and a Linux container must
# not hand one host the other's binaries). scripts/gen-proto.sh keeps the protoc plugins here too.
HOST := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
TOOLS := $(CURDIR)/.tools/$(HOST)/bin
GOLANGCI_LINT_VERSION := v2.8.0
GOFUMPT_VERSION := v0.9.2

.PHONY: all proto proto-check go go-test swift swift-release swift-test fixtures e2e lint check clean

all: go swift

proto:
	./scripts/gen-proto.sh

# Fails if generated code is stale relative to proto/.
proto-check:
	./scripts/gen-proto.sh
	git diff --exit-code -- go/gen engine/Sources/LeylineProto

go:
	cd go && GOBIN=$(GOBIN) go install ./cmd/...

go-test:
	cd go && go test ./...

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
e2e: go swift fixtures
	cd go && LEYLINED_BIN="$$(cd ../engine && swift build -c $(SWIFT_CONFIG) --show-bin-path)/leylined" LEY_BIN=$(GOBIN)/ley \
		go test -count=1 -v ./internal/e2e/...

$(TOOLS)/golangci-lint:
	cd go && GOBIN=$(TOOLS) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)

$(TOOLS)/gofumpt:
	cd go && GOBIN=$(TOOLS) go install mvdan.cc/gofumpt@$(GOFUMPT_VERSION)

lint: $(TOOLS)/golangci-lint $(TOOLS)/gofumpt
	cd go && $(TOOLS)/golangci-lint run ./... && test -z "$$($(TOOLS)/gofumpt -l .)"

check: proto-check go-test lint swift swift-test e2e

clean:
	rm -rf go/bin engine/.build
