/*
 * Calibration in NVS (namespace "titrator", key "cal": a versioned blob of
 * slope and offset). Nothing else is persisted: syringe positions live in RAM
 * only (protocol 3).
 */
#pragma once

#include <stdbool.h>

#include "core/types.h"
#include "esp_err.h"

/* nvs_flash_init(), erasing and retrying on NO_FREE_PAGES / NEW_VERSION.
 * Also needed by the BT controller (PHY data), so call it first in app_main. */
esp_err_t cal_store_init(void);

/* The stored calibration if there is a valid one (ph_cal_valid); false: none
 * or invalid, the caller uses ph_cal_default(). */
bool cal_store_load(cal_t *out);

/* Writes and commits. False on any NVS error. */
bool cal_store_save(const cal_t *cal);
