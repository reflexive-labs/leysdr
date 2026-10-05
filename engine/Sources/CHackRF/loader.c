// SPDX-License-Identifier: GPL-3.0-or-later

#include "shim.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static pthread_once_t loader_once = PTHREAD_ONCE_INIT;
static void *library_handle;
static char loader_error[512];

static void initialize_loader(void) {
    const char *override = getenv("LEYLINE_HACKRF_LIBRARY");
    if (override && *override) {
        library_handle = dlopen(override, RTLD_LAZY | RTLD_LOCAL);
        if (!library_handle) {
            snprintf(loader_error, sizeof(loader_error), "%s", dlerror());
        }
        return;
    }
    // A distributed build carries the driver in Leyline.app/Contents/Frameworks, one directory
    // over from the daemon in Contents/Helpers, signed by the same team so a hardened-runtime
    // daemon may load it. A build from source has no such directory and falls through to the
    // system's copy (docs/decisions/S3-usb-posture.md, "Decision"). glibc expands $ORIGIN in a
    // dlopen path against the calling object, the daemon executable this file is linked into.
#if defined(__APPLE__)
    static const char *candidates[] = {
        "@executable_path/../Frameworks/libhackrf.0.dylib",
        "/opt/homebrew/opt/hackrf/lib/libhackrf.0.dylib",
        "/usr/local/opt/hackrf/lib/libhackrf.0.dylib",
        "libhackrf.0.dylib",
        "libhackrf.dylib",
    };
#else
    static const char *candidates[] = {
        "$ORIGIN/../Frameworks/libhackrf.so.0",
        "libhackrf.so.0",
        "libhackrf.so",
    };
#endif
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        library_handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (library_handle) return;
    }
    const char *error = dlerror();
    snprintf(loader_error, sizeof(loader_error), "%s", error ? error : "libhackrf was not found");
}

static void *load_symbol(const char *name) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle ? dlsym(library_handle, name) : NULL;
}

int leyline_hackrf_available(void) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle != NULL;
}

const char *leyline_hackrf_load_error(void) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle ? NULL : loader_error;
}

#define LOAD_OR_RETURN(symbol, declaration, fallback)               \
    __typeof__(&declaration) function =                             \
        (__typeof__(&declaration))load_symbol(symbol);              \
    if (!function) return fallback

int hackrf_init(void) {
    LOAD_OR_RETURN("hackrf_init", hackrf_init, HACKRF_ERROR_NOT_FOUND);
    return function();
}

hackrf_device_list_t *hackrf_device_list(void) {
    LOAD_OR_RETURN("hackrf_device_list", hackrf_device_list, NULL);
    return function();
}

int hackrf_device_list_open(hackrf_device_list_t *list, int idx, hackrf_device **device) {
    if (device) *device = NULL;
    LOAD_OR_RETURN("hackrf_device_list_open", hackrf_device_list_open, HACKRF_ERROR_NOT_FOUND);
    return function(list, idx, device);
}

void hackrf_device_list_free(hackrf_device_list_t *list) {
    void (*function)(hackrf_device_list_t *) =
        (void (*)(hackrf_device_list_t *))load_symbol("hackrf_device_list_free");
    if (function) function(list);
}

int hackrf_open_by_serial(const char *serial, hackrf_device **device) {
    if (device) *device = NULL;
    LOAD_OR_RETURN("hackrf_open_by_serial", hackrf_open_by_serial, HACKRF_ERROR_NOT_FOUND);
    return function(serial, device);
}

int hackrf_close(hackrf_device *device) {
    LOAD_OR_RETURN("hackrf_close", hackrf_close, HACKRF_ERROR_NOT_FOUND);
    return function(device);
}

int hackrf_board_id_read(hackrf_device *device, uint8_t *value) {
    LOAD_OR_RETURN("hackrf_board_id_read", hackrf_board_id_read, HACKRF_ERROR_NOT_FOUND);
    return function(device, value);
}

int hackrf_set_freq(hackrf_device *device, uint64_t hz) {
    LOAD_OR_RETURN("hackrf_set_freq", hackrf_set_freq, HACKRF_ERROR_NOT_FOUND);
    return function(device, hz);
}

int hackrf_set_sample_rate(hackrf_device *device, double hz) {
    LOAD_OR_RETURN("hackrf_set_sample_rate", hackrf_set_sample_rate, HACKRF_ERROR_NOT_FOUND);
    return function(device, hz);
}

int hackrf_set_lna_gain(hackrf_device *device, uint32_t db) {
    LOAD_OR_RETURN("hackrf_set_lna_gain", hackrf_set_lna_gain, HACKRF_ERROR_NOT_FOUND);
    return function(device, db);
}

int hackrf_set_vga_gain(hackrf_device *device, uint32_t db) {
    LOAD_OR_RETURN("hackrf_set_vga_gain", hackrf_set_vga_gain, HACKRF_ERROR_NOT_FOUND);
    return function(device, db);
}

int hackrf_set_amp_enable(hackrf_device *device, uint8_t enabled) {
    LOAD_OR_RETURN("hackrf_set_amp_enable", hackrf_set_amp_enable, HACKRF_ERROR_NOT_FOUND);
    return function(device, enabled);
}

int hackrf_start_rx(hackrf_device *device, hackrf_sample_block_cb_fn callback, void *context) {
    LOAD_OR_RETURN("hackrf_start_rx", hackrf_start_rx, HACKRF_ERROR_NOT_FOUND);
    return function(device, callback, context);
}

int hackrf_stop_rx(hackrf_device *device) {
    LOAD_OR_RETURN("hackrf_stop_rx", hackrf_stop_rx, HACKRF_ERROR_NOT_FOUND);
    return function(device);
}

const char *hackrf_error_name(enum hackrf_error code) {
    const char *(*function)(enum hackrf_error) =
        (const char *(*)(enum hackrf_error))load_symbol("hackrf_error_name");
    return function ? function(code) : "libhackrf is not installed";
}
