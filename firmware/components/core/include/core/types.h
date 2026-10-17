/*
 * Shared vocabulary of the firmware core.
 *
 * Everything under components/core is plain C17 without ESP-IDF headers, so
 * it builds both for the ESP32-S3 and for the host tests (test/host).
 *
 * Time is a monotonic millisecond counter (uint32_t, wraps after ~49 days).
 * Always compare times by difference: (uint32_t)(now_ms - since_ms) >= dur_ms.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Syringe channel index. The protocol's `ch` is index + 1. */
enum {
    CH_ACID = 0, /* ch 1: acid */
    CH_BASE = 1, /* ch 2: base */
    CH_COUNT = 2,
};

/* Plunger direction. DIR_IN: aspirate, protocol "in" (motor reverse).
 * DIR_OUT: dispense, protocol "out" (motor forward, towards the switch). */
typedef enum {
    DIR_IN = 0,
    DIR_OUT = 1,
} dir_t;

/* Device state reported by the `state` event (protocol 2.2). */
typedef enum {
    DEV_IDLE = 0,
    DEV_TITRATING,
    DEV_MOVING,
} dev_state_t;

/* Error codes of the `error` event (protocol 2.3). */
typedef enum {
    ERR_BUSY = 0,
    ERR_LIMIT,
    ERR_UNHOMED,
    ERR_NO_CONVERGE,
    ERR_SENSOR,
    ERR_BAD_CMD,
    ERR_COUNT,
} err_code_t;

/* Electrode calibration (protocol 2.4): slope in mV/pH (negative), offset in
 * mV at pH 7. Set by the app through `cal_set`. */
typedef struct {
    float slope;
    float offset;
} cal_t;
