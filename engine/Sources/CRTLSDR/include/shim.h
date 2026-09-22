// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LEYLINE_CRTLSDR_SHIM_H
#define LEYLINE_CRTLSDR_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rtlsdr_dev rtlsdr_dev_t;

enum rtlsdr_tuner {
    RTLSDR_TUNER_UNKNOWN = 0,
    RTLSDR_TUNER_E4000,
    RTLSDR_TUNER_FC0012,
    RTLSDR_TUNER_FC0013,
    RTLSDR_TUNER_FC2580,
    RTLSDR_TUNER_R820T,
    RTLSDR_TUNER_R828D,
};

typedef void (*rtlsdr_read_async_cb_t)(unsigned char *buf, uint32_t len, void *ctx);

/** Whether the runtime loader found librtlsdr. Safe before any other call. */
int leyline_rtlsdr_available(void);
/** Loader diagnostic, or NULL when the library is available. */
const char *leyline_rtlsdr_load_error(void);

uint32_t rtlsdr_get_device_count(void);
const char *rtlsdr_get_device_name(uint32_t index);
int rtlsdr_get_device_usb_strings(uint32_t index, char *manufact, char *product, char *serial);
int rtlsdr_open(rtlsdr_dev_t **dev, uint32_t index);
int rtlsdr_close(rtlsdr_dev_t *dev);
int rtlsdr_set_center_freq(rtlsdr_dev_t *dev, uint32_t freq);
uint32_t rtlsdr_get_center_freq(rtlsdr_dev_t *dev);
int rtlsdr_set_freq_correction(rtlsdr_dev_t *dev, int ppm);
enum rtlsdr_tuner rtlsdr_get_tuner_type(rtlsdr_dev_t *dev);
int rtlsdr_get_tuner_gains(rtlsdr_dev_t *dev, int *gains);
int rtlsdr_get_tuner_gain(rtlsdr_dev_t *dev);
int rtlsdr_set_tuner_gain(rtlsdr_dev_t *dev, int gain);
int rtlsdr_set_tuner_gain_mode(rtlsdr_dev_t *dev, int manual);
int rtlsdr_set_sample_rate(rtlsdr_dev_t *dev, uint32_t rate);
int rtlsdr_set_agc_mode(rtlsdr_dev_t *dev, int on);
int rtlsdr_set_direct_sampling(rtlsdr_dev_t *dev, int on);
int rtlsdr_reset_buffer(rtlsdr_dev_t *dev);
int rtlsdr_read_async(rtlsdr_dev_t *dev, rtlsdr_read_async_cb_t cb, void *ctx,
                      uint32_t buf_num, uint32_t buf_len);
int rtlsdr_cancel_async(rtlsdr_dev_t *dev);
int rtlsdr_set_bias_tee(rtlsdr_dev_t *dev, int on);

#ifdef __cplusplus
}
#endif

#endif
