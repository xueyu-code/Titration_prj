/* Calibration in NVS, see platform/cal_store.h. */
#include "platform/cal_store.h"

#include <stddef.h>

#include "core/ph.h"
#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"

#define NVS_NAMESPACE "titrator"
#define NVS_KEY "cal"
#define BLOB_VERSION 1

/* The stored form. The version lets a later layout be told from this one. */
typedef struct {
    uint8_t version;
    float slope;
    float offset;
} cal_blob_t;

static const char *TAG = "cal";

esp_err_t cal_store_init(void)
{
    esp_err_t err = nvs_flash_init();

    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        err = nvs_flash_erase();
        if (err != ESP_OK)
            return err;
        err = nvs_flash_init();
    }
    return err;
}

bool cal_store_load(cal_t *out)
{
    nvs_handle_t h;
    cal_blob_t blob = {0}; /* a shorter stored blob leaves the rest zero */
    size_t len = sizeof blob;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &h);

    if (err != ESP_OK) { /* the namespace does not exist before the first save */
        if (err != ESP_ERR_NVS_NOT_FOUND)
            ESP_LOGW(TAG, "nvs_open: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_get_blob(h, NVS_KEY, &blob, &len);
    nvs_close(h);
    if (err != ESP_OK) {
        if (err != ESP_ERR_NVS_NOT_FOUND)
            ESP_LOGW(TAG, "stored calibration unreadable: %s", esp_err_to_name(err));
        return false;
    }

    cal_t cal = {.slope = blob.slope, .offset = blob.offset};

    if (len != sizeof blob || blob.version != BLOB_VERSION || !ph_cal_valid(&cal)) {
        ESP_LOGW(TAG, "stored calibration rejected (size %u, version %u), using factory values",
                 (unsigned)len, (unsigned)blob.version);
        return false;
    }
    *out = cal;
    return true;
}

bool cal_store_save(const cal_t *cal)
{
    nvs_handle_t h;
    cal_blob_t blob = {.version = BLOB_VERSION, .slope = cal->slope, .offset = cal->offset};
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_set_blob(h, NVS_KEY, &blob, sizeof blob);
    if (err == ESP_OK)
        err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "saving calibration failed: %s", esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "saved slope %.2f offset %.2f", (double)cal->slope, (double)cal->offset);
    return true;
}
