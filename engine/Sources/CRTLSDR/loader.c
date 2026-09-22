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
    const char *override = getenv("LEYLINE_RTLSDR_LIBRARY");
    if (override && *override) {
        library_handle = dlopen(override, RTLD_LAZY | RTLD_LOCAL);
        if (!library_handle) {
            snprintf(loader_error, sizeof(loader_error), "%s", dlerror());
        }
        return;
    }
#if defined(__APPLE__)
    static const char *candidates[] = {
        "/opt/homebrew/opt/librtlsdr/lib/librtlsdr.0.dylib",
        "/usr/local/opt/librtlsdr/lib/librtlsdr.0.dylib",
        "librtlsdr.0.dylib",
        "librtlsdr.dylib",
    };
#else
    static const char *candidates[] = {"librtlsdr.so.0", "librtlsdr.so"};
#endif
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        library_handle = dlopen(candidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (library_handle) return;
    }
    const char *error = dlerror();
    snprintf(loader_error, sizeof(loader_error), "%s", error ? error : "librtlsdr was not found");
}

static void *load_symbol(const char *name) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle ? dlsym(library_handle, name) : NULL;
}

int leyline_rtlsdr_available(void) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle != NULL;
}

const char *leyline_rtlsdr_load_error(void) {
    pthread_once(&loader_once, initialize_loader);
    return library_handle ? NULL : loader_error;
}

#define LOAD_OR_RETURN(symbol, declaration, fallback)               \
    __typeof__(&declaration) function =                             \
        (__typeof__(&declaration))load_symbol(symbol);              \
    if (!function) return fallback

uint32_t rtlsdr_get_device_count(void) {
    LOAD_OR_RETURN("rtlsdr_get_device_count", rtlsdr_get_device_count, 0);
    return function();
}

const char *rtlsdr_get_device_name(uint32_t index) {
    LOAD_OR_RETURN("rtlsdr_get_device_name", rtlsdr_get_device_name, NULL);
    return function(index);
}

int rtlsdr_get_device_usb_strings(uint32_t index, char *manufact, char *product, char *serial) {
    LOAD_OR_RETURN("rtlsdr_get_device_usb_strings", rtlsdr_get_device_usb_strings, -1);
    return function(index, manufact, product, serial);
}

int rtlsdr_open(rtlsdr_dev_t **dev, uint32_t index) {
    if (dev) *dev = NULL;
    LOAD_OR_RETURN("rtlsdr_open", rtlsdr_open, -1);
    return function(dev, index);
}

int rtlsdr_close(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_close", rtlsdr_close, -1);
    return function(dev);
}

int rtlsdr_set_center_freq(rtlsdr_dev_t *dev, uint32_t freq) {
    LOAD_OR_RETURN("rtlsdr_set_center_freq", rtlsdr_set_center_freq, -1);
    return function(dev, freq);
}

uint32_t rtlsdr_get_center_freq(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_get_center_freq", rtlsdr_get_center_freq, 0);
    return function(dev);
}

int rtlsdr_set_freq_correction(rtlsdr_dev_t *dev, int ppm) {
    LOAD_OR_RETURN("rtlsdr_set_freq_correction", rtlsdr_set_freq_correction, -1);
    return function(dev, ppm);
}

enum rtlsdr_tuner rtlsdr_get_tuner_type(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_get_tuner_type", rtlsdr_get_tuner_type, RTLSDR_TUNER_UNKNOWN);
    return function(dev);
}

int rtlsdr_get_tuner_gains(rtlsdr_dev_t *dev, int *gains) {
    LOAD_OR_RETURN("rtlsdr_get_tuner_gains", rtlsdr_get_tuner_gains, -1);
    return function(dev, gains);
}

int rtlsdr_get_tuner_gain(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_get_tuner_gain", rtlsdr_get_tuner_gain, 0);
    return function(dev);
}

int rtlsdr_set_tuner_gain(rtlsdr_dev_t *dev, int gain) {
    LOAD_OR_RETURN("rtlsdr_set_tuner_gain", rtlsdr_set_tuner_gain, -1);
    return function(dev, gain);
}

int rtlsdr_set_tuner_gain_mode(rtlsdr_dev_t *dev, int manual) {
    LOAD_OR_RETURN("rtlsdr_set_tuner_gain_mode", rtlsdr_set_tuner_gain_mode, -1);
    return function(dev, manual);
}

int rtlsdr_set_sample_rate(rtlsdr_dev_t *dev, uint32_t rate) {
    LOAD_OR_RETURN("rtlsdr_set_sample_rate", rtlsdr_set_sample_rate, -1);
    return function(dev, rate);
}

int rtlsdr_set_agc_mode(rtlsdr_dev_t *dev, int on) {
    LOAD_OR_RETURN("rtlsdr_set_agc_mode", rtlsdr_set_agc_mode, -1);
    return function(dev, on);
}

int rtlsdr_set_direct_sampling(rtlsdr_dev_t *dev, int on) {
    LOAD_OR_RETURN("rtlsdr_set_direct_sampling", rtlsdr_set_direct_sampling, -1);
    return function(dev, on);
}

int rtlsdr_reset_buffer(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_reset_buffer", rtlsdr_reset_buffer, -1);
    return function(dev);
}

int rtlsdr_read_async(rtlsdr_dev_t *dev, rtlsdr_read_async_cb_t cb, void *ctx,
                      uint32_t buf_num, uint32_t buf_len) {
    LOAD_OR_RETURN("rtlsdr_read_async", rtlsdr_read_async, -1);
    return function(dev, cb, ctx, buf_num, buf_len);
}

int rtlsdr_cancel_async(rtlsdr_dev_t *dev) {
    LOAD_OR_RETURN("rtlsdr_cancel_async", rtlsdr_cancel_async, -1);
    return function(dev);
}

int rtlsdr_set_bias_tee(rtlsdr_dev_t *dev, int on) {
    LOAD_OR_RETURN("rtlsdr_set_bias_tee", rtlsdr_set_bias_tee, -1);
    return function(dev, on);
}
