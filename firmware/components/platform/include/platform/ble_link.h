/*
 * BLE GATT server of docs/protocol.md section 1, on NimBLE.
 *
 * Service f65c0001-..., CMD f65c0002-... (write with response), EVT
 * f65c0003-... (notify). Advertising: flags + 128-bit service UUID; the name
 * "Titrator-XXXX" (last two bytes of the BT MAC) goes into the scan response.
 * One connection; advertising restarts right after a disconnect. Preferred
 * MTU 247 (sdkconfig). No pairing.
 *
 * A CMD write is always acknowledged (no ATT error): the bytes go to
 * on_write and the outcome is reported through events.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    /* One CMD write. Runs in the NimBLE host task: copy and return. len is
     * the real length; data holds min(len, PROTO_MAX_MSG + 1) bytes, so
     * len > PROTO_MAX_MSG means "too long". */
    void (*on_write)(const uint8_t *data, size_t len);
    /* Notifications on EVT were enabled. */
    void (*on_subscribe)(void);
    /* The connection is gone (also when it never subscribed). */
    void (*on_disconnect)(void);
} ble_link_cbs_t;

/* Initialises NimBLE, registers the service and starts advertising. */
esp_err_t ble_link_start(const ble_link_cbs_t *cbs);

/* Notifies one event on EVT. False when nobody is subscribed or the stack
 * has no buffer; the event is dropped. Callable from any task. */
bool ble_link_notify(const char *msg, size_t len);
