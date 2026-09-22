// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LEYLINE_CHACKRF_SHIM_H
#define LEYLINE_CHACKRF_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum hackrf_error {
    HACKRF_SUCCESS = 0,
    HACKRF_TRUE = 1,
    HACKRF_ERROR_INVALID_PARAM = -2,
    HACKRF_ERROR_NOT_FOUND = -5,
    HACKRF_ERROR_BUSY = -6,
    HACKRF_ERROR_NO_MEM = -11,
    HACKRF_ERROR_LIBUSB = -1000,
    HACKRF_ERROR_THREAD = -1001,
    HACKRF_ERROR_STREAMING_THREAD_ERR = -1002,
    HACKRF_ERROR_STREAMING_STOPPED = -1003,
    HACKRF_ERROR_STREAMING_EXIT_CALLED = -1004,
    HACKRF_ERROR_USB_API_VERSION = -1005,
    HACKRF_ERROR_NOT_LAST_DEVICE = -2000,
    HACKRF_ERROR_OTHER = -9999,
};

enum hackrf_usb_board_id {
    USB_BOARD_ID_JAWBREAKER = 0x604B,
    USB_BOARD_ID_HACKRF_ONE = 0x6089,
    USB_BOARD_ID_RAD1O = 0xCC15,
    USB_BOARD_ID_INVALID = 0xFFFF,
};

typedef struct hackrf_device hackrf_device;

typedef struct {
    hackrf_device *device;
    uint8_t *buffer;
    int buffer_length;
    int valid_length;
    void *rx_ctx;
    void *tx_ctx;
} hackrf_transfer;

typedef int (*hackrf_sample_block_cb_fn)(hackrf_transfer *transfer);

typedef struct hackrf_device_list {
    char **serial_numbers;
    enum hackrf_usb_board_id *usb_board_ids;
    int *usb_device_index;
    int devicecount;
    void **usb_devices;
    int usb_devicecount;
} hackrf_device_list_t;

/** Whether the runtime loader found libhackrf. Safe before any other call. */
int leyline_hackrf_available(void);
/** Loader diagnostic, or NULL when the library is available. */
const char *leyline_hackrf_load_error(void);

int hackrf_init(void);
hackrf_device_list_t *hackrf_device_list(void);
int hackrf_device_list_open(hackrf_device_list_t *list, int idx, hackrf_device **device);
void hackrf_device_list_free(hackrf_device_list_t *list);
int hackrf_open_by_serial(const char *desired_serial_number, hackrf_device **device);
int hackrf_close(hackrf_device *device);
int hackrf_board_id_read(hackrf_device *device, uint8_t *value);
int hackrf_set_freq(hackrf_device *device, uint64_t freq_hz);
int hackrf_set_sample_rate(hackrf_device *device, double freq_hz);
int hackrf_set_lna_gain(hackrf_device *device, uint32_t value);
int hackrf_set_vga_gain(hackrf_device *device, uint32_t value);
int hackrf_set_amp_enable(hackrf_device *device, uint8_t value);
int hackrf_start_rx(hackrf_device *device, hackrf_sample_block_cb_fn callback, void *rx_ctx);
int hackrf_stop_rx(hackrf_device *device);
const char *hackrf_error_name(enum hackrf_error errcode);

#ifdef __cplusplus
}
#endif

#endif
