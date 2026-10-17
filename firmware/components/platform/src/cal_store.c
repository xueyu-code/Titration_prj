/* Calibration in NVS, see platform/cal_store.h. TODO(WP1): implement. */
#include "platform/cal_store.h"

#include "core/ph.h"
#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"

esp_err_t cal_store_init(void)
{
    return ESP_ERR_NOT_SUPPORTED;
}

bool cal_store_load(cal_t *out)
{
    (void)out;
    return false;
}

bool cal_store_save(const cal_t *cal)
{
    (void)cal;
    return false;
}
