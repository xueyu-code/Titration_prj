/*
 * Voltage and pH conversion (protocol 2.4):
 *   mv = (V_adc - FE_BIAS_MV) / FE_GAIN
 *   pH = 7 + (mv - offset) / slope
 */
#pragma once

#include <stdbool.h>

#include "core/types.h"

/* Electrode voltage in mV for the voltage at the ADC pin in mV. */
float ph_electrode_mv(float v_adc_mv);

/* pH for electrode voltage mv under calibration cal (cal must be valid). */
float ph_from_mv(const cal_t *cal, float mv);

/* Whether slope and offset are inside the ranges `cal_set` accepts. */
bool ph_cal_valid(const cal_t *cal);

/* Factory calibration: CAL_DEFAULT_SLOPE, CAL_DEFAULT_OFFSET. */
cal_t ph_cal_default(void);
