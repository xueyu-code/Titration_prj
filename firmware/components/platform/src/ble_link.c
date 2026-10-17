/*
 * NimBLE GATT server, see platform/ble_link.h and DESIGN.md "BLE (NimBLE)".
 * Modelled on $IDF_PATH/examples/bluetooth/nimble/bleprph.
 *
 * Context: the callbacks below run in the NimBLE host task and only hand the
 * bytes on; ble_link_notify() runs in the control task. The connection handle
 * and the subscription flag are written by the host task and read by the
 * control task. A stale read at a disconnect makes the notify fail, which
 * drops one event and is harmless.
 */
#include "platform/ble_link.h"

#include <stdio.h>
#include <string.h>

#include "core/protocol.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#define NAME_PREFIX "Titrator-"

static const char *TAG = "ble";

/* f65c000N-8221-4068-aa47-28e41eec47fd, least significant byte first. */
#define TITRATOR_UUID128(n) \
    BLE_UUID128_INIT(0xfd, 0x47, 0xec, 0x1e, 0xe4, 0x28, 0x47, 0xaa, \
                     0x68, 0x40, 0x21, 0x82, (n), 0x00, 0x5c, 0xf6)

static const ble_uuid128_t s_svc_uuid = TITRATOR_UUID128(0x01);
static const ble_uuid128_t s_cmd_uuid = TITRATOR_UUID128(0x02);
static const ble_uuid128_t s_evt_uuid = TITRATOR_UUID128(0x03);

static ble_link_cbs_t s_cbs;
static uint8_t s_own_addr_type;
static uint16_t s_evt_handle;
static volatile uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool s_subscribed;

/* ----------------------------------------------------------------- GATT */

/* A write to CMD: hand the bytes on and always report success (protocol 1);
 * the outcome of the command comes back as an event. */
static int cmd_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn;
    (void)attr;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR)
        return BLE_ATT_ERR_UNLIKELY;

    uint8_t buf[PROTO_MAX_MSG + 1];
    size_t len = OS_MBUF_PKTLEN(ctxt->om);
    uint16_t copied = 0;
    /* BLE_HS_EMSGSIZE: longer than buf, which keeps the first bytes. */
    int rc = ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof buf, &copied);
    if (rc != 0 && rc != BLE_HS_EMSGSIZE) {
        ESP_LOGW(TAG, "cannot read the write, rc=%d", rc);
        return 0;
    }
    s_cbs.on_write(buf, len);
    return 0;
}

/* EVT only notifies; it has no readable value. */
static int evt_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn;
    (void)attr;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_READ_NOT_PERMITTED;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics =
            (struct ble_gatt_chr_def[]){
                {
                    .uuid = &s_cmd_uuid.u,
                    .access_cb = cmd_access,
                    .flags = BLE_GATT_CHR_F_WRITE,
                },
                {
                    .uuid = &s_evt_uuid.u,
                    .access_cb = evt_access,
                    .val_handle = &s_evt_handle,
                    .flags = BLE_GATT_CHR_F_NOTIFY,
                },
                {0},
            },
    },
    {0},
};

/* ------------------------------------------------------------ advertising */

static int gap_event(struct ble_gap_event *event, void *arg);

/* Flags + service UUID (3 + 18 = 21 B) in the advertisement, the name in the
 * scan response. Connectable, undirected, default interval. */
static void advertise(void)
{
    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };
    int rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY)
        ESP_LOGE(TAG, "advertising failed, rc=%d", rc);
}

static int set_adv_data(void)
{
    struct ble_hs_adv_fields adv = {0};
    adv.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    adv.uuids128 = &s_svc_uuid;
    adv.num_uuids128 = 1;
    adv.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&adv);
    if (rc != 0)
        return rc;

    const char *name = ble_svc_gap_device_name();
    struct ble_hs_adv_fields rsp = {0};
    rsp.name = (const uint8_t *)name;
    rsp.name_len = strlen(name);
    rsp.name_is_complete = 1;
    return ble_gap_adv_rsp_set_fields(&rsp);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn = event->connect.conn_handle;
            ESP_LOGI(TAG, "connected, handle %u", (unsigned)s_conn);
        } else {
            ESP_LOGW(TAG, "connect failed, status %d", event->connect.status);
            advertise();
        }
        break;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "disconnected, reason %d", event->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed = false;
        s_cbs.on_disconnect();
        advertise();
        break;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;

    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_evt_handle) {
            s_subscribed = event->subscribe.cur_notify;
            ESP_LOGI(TAG, "notifications %s", s_subscribed ? "on" : "off");
            if (s_subscribed)
                s_cbs.on_subscribe();
        }
        break;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU %u", (unsigned)event->mtu.value);
        break;

    default:
        break;
    }
    return 0;
}

/* ------------------------------------------------------------ host stack */

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset, reason %d", reason);
}

/* The stack has an address now: name the device after it and advertise. */
static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0)
        rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    uint8_t addr[6];
    if (rc == 0)
        rc = ble_hs_id_copy_addr(s_own_addr_type, addr, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "no device address, rc=%d", rc);
        return;
    }

    /* addr[] is least significant first: the last two bytes of the MAC. */
    char name[sizeof NAME_PREFIX + 4];
    snprintf(name, sizeof name, NAME_PREFIX "%02X%02X", addr[1], addr[0]);
    rc = ble_svc_gap_device_name_set(name);
    if (rc == 0)
        rc = set_adv_data();
    if (rc != 0) {
        ESP_LOGE(TAG, "advertising data failed, rc=%d", rc);
        return;
    }
    ESP_LOGI(TAG, "advertising as %s", name);
    advertise();
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run(); /* returns only after nimble_port_stop() */
    nimble_port_freertos_deinit();
}

esp_err_t ble_link_start(const ble_link_cbs_t *cbs)
{
    if (!cbs || !cbs->on_write || !cbs->on_subscribe || !cbs->on_disconnect)
        return ESP_ERR_INVALID_ARG;
    s_cbs = *cbs;

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK)
        return err;

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_gatts_count_cfg(s_gatt_svcs) != 0 || ble_gatts_add_svcs(s_gatt_svcs) != 0)
        return ESP_FAIL;

    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

bool ble_link_notify(const char *msg, size_t len)
{
    uint16_t conn = s_conn;
    if (conn == BLE_HS_CONN_HANDLE_NONE || !s_subscribed)
        return false;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(msg, (uint16_t)len);
    if (!om) {
        ESP_LOGW(TAG, "no buffer, event dropped");
        return false;
    }
    int rc = ble_gatts_notify_custom(conn, s_evt_handle, om); /* consumes om */
    if (rc != 0) {
        ESP_LOGW(TAG, "notify failed, rc=%d", rc);
        return false;
    }
    return true;
}
