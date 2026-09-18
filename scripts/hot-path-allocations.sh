#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Invariant 4 ("Hot path is allocation-free") as a number, without Instruments.
#
# The S2 spike's third criterion is "zero allocations in the sample path"
# (docs/plans/build-order.md), and the throughput run cannot see it: at 20 MSPS a block has
# 819 us of budget and the DSP thread uses about 160 us of it, so a thousand mallocs per block
# would cost under 10% of the budget and produce no overrun at all. Instruments' Allocations
# track is the specified tool and remains the authority; this is the check that runs in a
# terminal, in seconds, on every change.
#
# How it works, and why it does not simply count allocations: a process allocates plenty at
# startup and in its control plane, and none of that is what the invariant is about. What the
# invariant forbids is allocation that happens *per block*. So the harness is run twice, at two
# durations, and the counts are differenced: whatever is one-off cancels, and what is left is
# the allocation that scales with the number of blocks processed. That is the number reported.
#
# macOS only: it works by dyld interposition (__DATA,__interpose), which has no Linux equivalent.
#
#   scripts/hot-path-allocations.sh [path-to-binary] [short-seconds] [long-seconds]
#
# Default binary is the S2 harness. Any program that prints a "blocks processed : N" line and
# takes `--seconds N` works, which is the contract this depends on.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "hot-path-allocations: macOS only (dyld interposition); the Linux container cannot run it" >&2
  exit 2
fi

BIN="${1:-}"
SHORT="${2:-5}"
LONG="${3:-25}"
if [[ -z "$BIN" ]]; then
  BIN="$(cd "$(dirname "$0")/../engine" && swift build -c release --show-bin-path)/s2-throughput"
fi
if [[ ! -x "$BIN" ]]; then
  echo "hot-path-allocations: no executable at $BIN (build it with: cd engine && swift build -c release)" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/counter.c" <<'EOF'
// Counts every allocation the process makes, by dyld interposition. The replacement calls the
// real allocator: dyld rewrites the bindings of every image except the one declaring the
// interposition, so this is not recursive.
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_ullong allocations;

typedef struct interpose_s {
    const void *replacement;
    const void *replacee;
} interpose_t;

static void *counted_malloc(size_t size);
static void *counted_calloc(size_t count, size_t size);
static void *counted_realloc(void *ptr, size_t size);
static void *counted_valloc(size_t size);
static char *counted_strdup(const char *s);

__attribute__((used)) static const interpose_t interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
        {(const void *)counted_malloc, (const void *)malloc},
        {(const void *)counted_calloc, (const void *)calloc},
        {(const void *)counted_realloc, (const void *)realloc},
        {(const void *)counted_valloc, (const void *)valloc},
        {(const void *)counted_strdup, (const void *)strdup},
};

static void *counted_malloc(size_t size) {
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    return malloc(size);
}
static void *counted_calloc(size_t count, size_t size) {
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    return calloc(count, size);
}
static void *counted_realloc(void *ptr, size_t size) {
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    return realloc(ptr, size);
}
static void *counted_valloc(size_t size) {
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    return valloc(size);
}
static char *counted_strdup(const char *s) {
    atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
    return strdup(s);
}

// Read the count before printing: fprintf allocates, and a number that included its own
// reporting would be wrong in a way nobody could see.
__attribute__((destructor)) static void report(void) {
    unsigned long long n = atomic_load_explicit(&allocations, memory_order_relaxed);
    fprintf(stderr, "leyline-alloc-count %llu\n", n);
}
EOF

clang -dynamiclib -O2 -o "$WORK/libcount.dylib" "$WORK/counter.c"

run() { # seconds [rate] -> "<allocations> <blocks>"
  local secs="$1" rate="${2:-}" tag="$1${2:+-$2}"
  local -a args=(--seconds "$secs")
  [[ -n "$rate" ]] && args+=(--rate "$rate")
  DYLD_INSERT_LIBRARIES="$WORK/libcount.dylib" "$BIN" "${args[@]}" \
    > "$WORK/out.$tag" 2> "$WORK/err.$tag" || true
  local allocs blocks
  allocs="$(awk '/^leyline-alloc-count/ {print $2}' "$WORK/err.$tag" | tail -1)"
  blocks="$(awk -F: '/blocks processed/ {gsub(/ /, "", $2); print $2}' "$WORK/out.$tag" | tail -1)"
  if [[ -z "$allocs" ]]; then
    echo "hot-path-allocations: the counter did not report; DYLD_INSERT_LIBRARIES may be blocked" >&2
    sed -n '1,5p' "$WORK/err.$tag" >&2
    exit 1
  fi
  if [[ -z "$blocks" ]]; then
    echo "hot-path-allocations: $BIN printed no 'blocks processed' line" >&2
    sed -n '1,5p' "$WORK/out.$tag" >&2
    exit 1
  fi
  echo "$allocs $blocks"
}

echo "counting allocations in $(basename "$BIN") over ${SHORT}s and ${LONG}s runs..."
read -r A_SHORT B_SHORT <<<"$(run "$SHORT")"
read -r A_LONG B_LONG <<<"$(run "$LONG")"

awk -v as="$A_SHORT" -v bs="$B_SHORT" -v al="$A_LONG" -v bl="$B_LONG" -v s="$SHORT" -v l="$LONG" '
BEGIN {
  db = bl - bs; da = al - as;
  printf "  %4ss run : %12d allocations, %10d blocks\n", s, as, bs;
  printf "  %4ss run : %12d allocations, %10d blocks\n", l, al, bl;
  if (db <= 0) { print "  the two runs processed the same number of blocks; nothing to difference"; exit 2 }
  per = da / db;
  printf "  scaling  : %12d allocations over %d more blocks = %.4f per block\n", da, db, per;
  # One allocation every other block is already far more than a sample path should do, and well
  # clear of the noise from background threads that also run for longer in the longer run.
  if (per > 0.5) {
    printf "  VERDICT  : FAIL -- something in the per-block path allocates. Instruments\n";
    printf "             (Allocations > Call Trees, Separate by Thread) says what.\n";
    exit 1
  }
  printf "  VERDICT  : PASS -- allocation does not scale with blocks processed\n";
}'

# Whatever is left after the difference is either a small per-block cost or the clock ticking:
# timers, housekeeping, the runtime's own threads, all of which run for longer in the longer run
# and have nothing to do with blocks. One run separates them. Same duration, a tenth of the rate,
# so a tenth of the blocks and identical wall time: if the counts match, the residual belongs to
# the clock and the per-block path allocates nothing at all.
SLOW_RATE=2000000
echo
echo "separating clock-driven allocation from block-driven, at ${LONG}s and ${SLOW_RATE} sps..."
read -r A_SLOW B_SLOW <<<"$(run "$LONG" "$SLOW_RATE")"

awk -v af="$A_LONG" -v bf="$B_LONG" -v as="$A_SLOW" -v bs="$B_SLOW" -v l="$LONG" '
BEGIN {
  printf "  %4ss at full rate : %12d allocations, %10d blocks\n", l, af, bf;
  printf "  %4ss at a tenth   : %12d allocations, %10d blocks\n", l, as, bs;
  db = bf - bs; da = af - as;
  if (db <= 0) { print "  the two rates processed the same number of blocks; nothing to compare"; exit 0 }
  per = da / db;
  printf "  same wall clock, %d more blocks, %+d allocations = %.4f per block\n", db, da, per;
  if (per > 0.05 || per < -0.05) {
    printf "  READING  : the residual tracks blocks, so some of it is the sample path\n";
  } else {
    printf "  READING  : the residual tracks the clock, not blocks -- the per-block path\n";
    printf "             allocates nothing measurable\n";
  }
}'
