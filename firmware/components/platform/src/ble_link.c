/*
 * NimBLE GATT server, see platform/ble_link.h. TODO(WP4): implement.
 * Starting point: $IDF_PATH/examples/bluetooth/nimble/bleprph.
 */
#include "platform/ble_link.h"

#include "core/protocol.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

esp_err_t ble_link_start(const ble_link_cbs_t *cbs)
{
    (void)cbs;
    return ESP_ERR_NOT_SUPPORTED;
}

bool ble_link_notify(const char *msg, size_t len)
{
    (void)msg;
    (void)len;
    return false;
}
