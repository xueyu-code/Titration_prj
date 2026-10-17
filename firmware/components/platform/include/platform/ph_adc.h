/*
 * The pH front end's ADC (DESIGN.md "pH 测量链").
 *
 * Implementation: ESP32-S3 ADC1 in continuous (DMA) mode, 6 dB attenuation
 * (0..1600 mV effective range), BOARD_PH_ADC_SAMPLE_HZ. The raw codes of one
 * SAMPLE_PERIOD_MS window are averaged, and the average is converted with the
 * curve-fitting calibration through a piecewise-linear table built at init
 * (knots every 64 codes), which keeps sub-LSB resolution instead of the 1 mV
 * steps of adc_cali_raw_to_voltage().
 *
 * Another ADC (e.g. an external ADS1115) replaces ph_adc.c behind this same
 * interface; nothing else changes.
 */
#pragma once

#include "esp_err.h"

esp_err_t ph_adc_init(void);

/*
 * Blocks until the next SAMPLE_PERIOD_MS window is complete and returns the
 * mean voltage at the ADC pin in mV. An error means this window is lost
 * (the caller reports it as a failed read).
 */
esp_err_t ph_adc_read(float *v_adc_mv);
