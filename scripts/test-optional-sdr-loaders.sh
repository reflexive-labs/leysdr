#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prove that each native SDR backend can be present or absent independently. The fake libraries
# expose only the discovery calls used by this probe; no USB hardware or system package is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cc="${CC:-cc}"

cat >"$work/rtl.c" <<'EOF'
#include <stdint.h>
uint32_t rtlsdr_get_device_count(void) { return 0; }
EOF

cat >"$work/hackrf.c" <<'EOF'
#include "shim.h"
static hackrf_device_list_t empty_list = {0};
int hackrf_init(void) { return HACKRF_SUCCESS; }
hackrf_device_list_t *hackrf_device_list(void) { return &empty_list; }
void hackrf_device_list_free(hackrf_device_list_t *list) { (void)list; }
EOF

cat >"$work/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include "rtl.h"
#include "hackrf.h"

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    int want_rtl = atoi(argv[1]);
    int want_hackrf = atoi(argv[2]);
    int have_rtl = leyline_rtlsdr_available();
    int have_hackrf = leyline_hackrf_available();
    if (have_rtl != want_rtl || have_hackrf != want_hackrf) {
        fprintf(stderr, "wanted rtl=%d hackrf=%d, got rtl=%d (%s) hackrf=%d (%s)\n",
                want_rtl, want_hackrf, have_rtl,
                leyline_rtlsdr_load_error() ? leyline_rtlsdr_load_error() : "loaded",
                have_hackrf,
                leyline_hackrf_load_error() ? leyline_hackrf_load_error() : "loaded");
        return 1;
    }
    if (have_rtl && rtlsdr_get_device_count() != 0) return 2;
    if (have_hackrf) {
        if (hackrf_init() != HACKRF_SUCCESS) return 3;
        hackrf_device_list_t *list = hackrf_device_list();
        if (!list || list->devicecount != 0) return 4;
        hackrf_device_list_free(list);
    }
    return 0;
}
EOF

ln -s "$PWD/engine/Sources/CRTLSDR/include/shim.h" "$work/rtl.h"
ln -s "$PWD/engine/Sources/CHackRF/include/shim.h" "$work/hackrf.h"

if [[ "$(uname -s)" == Darwin ]]; then
    rtl_lib="$work/librtlsdr-test.dylib"
    hackrf_lib="$work/libhackrf-test.dylib"
    "$cc" -dynamiclib "$work/rtl.c" -o "$rtl_lib"
    "$cc" -dynamiclib -I engine/Sources/CHackRF/include "$work/hackrf.c" -o "$hackrf_lib"
    dl_flags=()
else
    rtl_lib="$work/librtlsdr-test.so"
    hackrf_lib="$work/libhackrf-test.so"
    "$cc" -shared -fPIC "$work/rtl.c" -o "$rtl_lib"
    "$cc" -shared -fPIC -I engine/Sources/CHackRF/include "$work/hackrf.c" -o "$hackrf_lib"
    dl_flags=(-ldl)
fi

"$cc" -pthread -I engine/Sources/CRTLSDR/include \
    -c engine/Sources/CRTLSDR/loader.c -o "$work/rtl-loader.o"
"$cc" -pthread -I engine/Sources/CHackRF/include \
    -c engine/Sources/CHackRF/loader.c -o "$work/hackrf-loader.o"
"$cc" -pthread -I "$work" "$work/probe.c" "$work/rtl-loader.o" "$work/hackrf-loader.o" \
    "${dl_flags[@]}" -o "$work/probe"

missing="$work/not-installed"
LEYLINE_RTLSDR_LIBRARY="$missing-rtl" LEYLINE_HACKRF_LIBRARY="$missing-hackrf" \
    "$work/probe" 0 0
LEYLINE_RTLSDR_LIBRARY="$rtl_lib" LEYLINE_HACKRF_LIBRARY="$missing-hackrf" \
    "$work/probe" 1 0
LEYLINE_RTLSDR_LIBRARY="$missing-rtl" LEYLINE_HACKRF_LIBRARY="$hackrf_lib" \
    "$work/probe" 0 1
LEYLINE_RTLSDR_LIBRARY="$rtl_lib" LEYLINE_HACKRF_LIBRARY="$hackrf_lib" \
    "$work/probe" 1 1

echo "optional SDR loader matrix passed (neither, RTL-only, HackRF-only, both)"
