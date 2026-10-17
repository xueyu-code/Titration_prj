/*
 * Electrode / front-end fault detection (protocol 3, "电极异常"): the reading
 * sits near either end of the measurable range for SENSOR_FAULT_MS. A failed
 * ADC read counts as being at the rail. The fault is reported once on entry;
 * it clears on the first good sample, silently.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    bool active;       /* in the fault */
    bool at_rail;      /* the last sample was at a rail */
    uint32_t since_ms; /* first sample of the current run at the rail */
} sensor_fault_t;

void sensor_fault_init(sensor_fault_t *sf);

/* Whether one sample is at a rail: !read_ok, or v_adc_mv outside
 * (SENSOR_RAIL_LO_MV, SENSOR_RAIL_HI_MV). */
bool sensor_fault_at_rail(bool read_ok, float v_adc_mv);

/* Feeds one sample. Returns true exactly when the fault is entered. */
bool sensor_fault_update(sensor_fault_t *sf, bool at_rail, uint32_t now_ms);

static inline bool sensor_fault_active(const sensor_fault_t *sf) { return sf->active; }
