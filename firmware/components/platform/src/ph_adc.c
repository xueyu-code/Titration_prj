/*
 * pH front-end ADC on ESP32-S3 ADC1 continuous mode, see platform/ph_adc.h.
 * TODO(WP1): implement.
 */
#include "platform/ph_adc.h"

#include "core/config.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_continuous.h"
#include "esp_log.h"
#include "platform/board.h"

esp_err_t ph_adc_init(void)
{
    return ESP_ERR_NOT_SUPPORTED;
}

esp_err_t ph_adc_read(float *v_adc_mv)
{
    (void)v_adc_mv;
    return ESP_ERR_NOT_SUPPORTED;
}
