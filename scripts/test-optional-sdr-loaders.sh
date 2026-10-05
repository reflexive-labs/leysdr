#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Prove that each native SDR backend can be present or absent independently, and that a daemon
# finds the drivers a distributed build carries in Frameworks/ beside its Helpers/ directory before
# any system copy. The fake libraries expose only the discovery calls used by this probe, and name
# themselves through one call a real driver answers differently; no USB hardware or system package
# is needed.
#
# Linux exercises the candidate order through the loaders' $ORIGIN entry; the Mac run exercises the
# @executable_path entry a bundle uses. Neither run proves that a hardened-runtime daemon may load a
# signed copy: that is checked against a signed bundle on the Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cc="${CC:-cc}"

cat >"$work/rtl.c" <<'EOF'
#include <stdint.h>
uint32_t rtlsdr_get_device_count(void) { return 0; }
const char *rtlsdr_get_device_name(uint32_t index) { (void)index; return FAKE_NAME; }
EOF

cat >"$work/hackrf.c" <<'EOF'
#include "shim.h"
static hackrf_device_list_t empty_list = {0};
int hackrf_init(void) { return HACKRF_SUCCESS; }
hackrf_device_list_t *hackrf_device_list(void) { return &empty_list; }
void hackrf_device_list_free(hackrf_device_list_t *list) { (void)list; }
const char *hackrf_error_name(enum hackrf_error errcode) { (void)errcode; return FAKE_NAME; }
EOF

cat >"$work/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rtl.h"
#include "hackrf.h"

int main(int argc, char **argv) {
    /* argv[3], when given, is the name the loaded fakes must report: which copy was found. */
    if (argc != 3 && argc != 4) return 64;
    int want_rtl = atoi(argv[1]);
    int want_hackrf = atoi(argv[2]);
    const char *want_name = argc == 4 ? argv[3] : NULL;
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
    if (want_name) {
        const char *rtl_name = have_rtl ? rtlsdr_get_device_name(0) : want_name;
        const char *hackrf_name = have_hackrf ? hackrf_error_name(HACKRF_SUCCESS) : want_name;
        if (!rtl_name || strcmp(rtl_name, want_name) != 0 ||
            !hackrf_name || strcmp(hackrf_name, want_name) != 0) {
            fprintf(stderr, "wanted the copies named %s, got rtl=%s hackrf=%s\n", want_name,
                    rtl_name ? rtl_name : "(null)", hackrf_name ? hackrf_name : "(null)");
            return 5;
        }
    }
    return 0;
}
EOF

ln -s "$PWD/engine/Sources/CRTLSDR/include/shim.h" "$work/rtl.h"
ln -s "$PWD/engine/Sources/CHackRF/include/shim.h" "$work/hackrf.h"

# fake <name> <rtl output> <hackrf output>: both fake drivers, each reporting <name>.
if [[ "$(uname -s)" == Darwin ]]; then
    lib_flags=(-dynamiclib)
    rtl_lib="$work/librtlsdr-test.dylib"
    hackrf_lib="$work/libhackrf-test.dylib"
    rtl_name=librtlsdr.0.dylib
    hackrf_name=libhackrf.0.dylib
    dl_flags=()
else
    lib_flags=(-shared -fPIC)
    rtl_lib="$work/librtlsdr-test.so"
    hackrf_lib="$work/libhackrf-test.so"
    rtl_name=librtlsdr.so.0
    hackrf_name=libhackrf.so.0
    dl_flags=(-ldl)
fi
fake() {
    "$cc" "${lib_flags[@]}" -DFAKE_NAME="\"$1\"" "$work/rtl.c" -o "$2"
    "$cc" "${lib_flags[@]}" -DFAKE_NAME="\"$1\"" -I engine/Sources/CHackRF/include \
        "$work/hackrf.c" -o "$3"
}
fake loose "$rtl_lib" "$hackrf_lib"

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
    "$work/probe" 1 1 loose

# The bundle layout: the daemon in Helpers/, the drivers in Frameworks/ beside it, no override.
bundle="$work/Leyline.app/Contents"
mkdir -p "$bundle/Helpers" "$bundle/Frameworks"
cp "$work/probe" "$bundle/Helpers/probe"
fake bundled "$bundle/Frameworks/$rtl_name" "$bundle/Frameworks/$hackrf_name"
if [[ "$(uname -s)" == Darwin ]]; then
    # A Homebrew copy, if this Mac has one, answers with its own name, so a pass here means the
    # bundled copy came first. DYLD_LIBRARY_PATH is not used for a stand-in system copy because
    # dyld consults it before every candidate, the bundled one included.
    env -u LEYLINE_RTLSDR_LIBRARY -u LEYLINE_HACKRF_LIBRARY "$bundle/Helpers/probe" 1 1 bundled
else
    # A system copy found by its bare name, standing in for one a package manager installed.
    mkdir -p "$work/system"
    fake system "$work/system/$rtl_name" "$work/system/$hackrf_name"
    env -u LEYLINE_RTLSDR_LIBRARY -u LEYLINE_HACKRF_LIBRARY LD_LIBRARY_PATH="$work/system" \
        "$bundle/Helpers/probe" 1 1 bundled
    # Outside the bundle the same probe falls through to the system copy.
    env -u LEYLINE_RTLSDR_LIBRARY -u LEYLINE_HACKRF_LIBRARY LD_LIBRARY_PATH="$work/system" \
        "$work/probe" 1 1 system
fi
# The environment override still wins over the bundled copies.
LEYLINE_RTLSDR_LIBRARY="$missing-rtl" LEYLINE_HACKRF_LIBRARY="$hackrf_lib" \
    "$bundle/Helpers/probe" 0 1 loose

echo "optional SDR loader matrix passed (neither, RTL-only, HackRF-only, both, bundled first)"
