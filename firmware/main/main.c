/*
 * Wiring: tasks, the control queue and the device ports (DESIGN.md
 * "任务与线程模型").
 *
 *   NimBLE host task --on_write/on_subscribe/on_disconnect--+
 *   sensor task ------MSG_SAMPLE (2 Hz)---------------------+--> s_ctl_queue
 *   MCPWM ISR --------MSG_MOTION_END (stepper_end_cb_t)-----+         |
 *                                                                     v
 *   control task (core 1): the only caller of device_*; also wakes every
 *   CTL_TICK_MS for device_tick(); its ports call stepper_*, cal_store_save
 *   and proto_encode_evt + ble_link_notify.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "core/config.h"
#include "core/device.h"
#include "core/ph.h"
#include "core/protocol.h"
#include "esp_app_desc.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "platform/ble_link.h"
#include "platform/cal_store.h"
#include "platform/ph_adc.h"
#include "platform/stepper.h"

#define CTL_TICK_MS 50u      /* jog watchdog resolution */
#define CTL_QUEUE_LEN 16u
#define CTL_QUEUE_RESERVE 4u /* slots kept free for messages that must not get lost */
#define CRITICAL_POST_MS 100u
#define CTL_TASK_PRIO 6u     /* above the sensor task, below NimBLE host */
#define SENSOR_TASK_PRIO 5u
#define CTL_TASK_STACK 6144u /* cJSON parse + snprintf with floats */
#define SENSOR_TASK_STACK 4096u
#define APP_CORE 1           /* the BLE controller runs on core 0 */

typedef enum {
    MSG_WRITE,
    MSG_SUBSCRIBE,
    MSG_DISCONNECT,
    MSG_SAMPLE,
    MSG_MOTION_END,
} ctl_msg_kind_t;

/* One item of the control queue. */
typedef struct {
    ctl_msg_kind_t kind;
    union {
        struct {
            uint16_t len; /* real length; > PROTO_MAX_MSG: too long */
            char data[PROTO_MAX_MSG + 1];
        } write;
        struct {
            bool ok;
            float v_adc_mv;
        } sample;
        struct {
            uint8_t ch;
            axis_status_t st;
            uint32_t tag;
        } motion;
    };
} ctl_msg_t;

static const char *TAG = "main";

static QueueHandle_t s_ctl_queue;
static device_t s_device;
static bool s_adc_ready;
static volatile uint32_t s_motion_ends_lost; /* counted by the ISR, reported by the control task */

static uint32_t now_ms(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

/* --------------------------------------------------------- device ports */

static void port_emit(void *ctx, const evt_t *evt)
{
    (void)ctx;
    char buf[PROTO_MAX_MSG + 1];
    size_t len = proto_encode_evt(evt, buf, sizeof buf);
    if (len == 0) {
        ESP_LOGE(TAG, "event kind %d does not encode", (int)evt->kind);
        return;
    }
    ble_link_notify(buf, len);
}

static axis_status_t port_motor_start(void *ctx, uint8_t ch, dir_t dir, int32_t steps, uint32_t tag)
{
    (void)ctx;
    return stepper_start(ch, dir, steps, tag);
}

static bool port_motor_extend(void *ctx, uint8_t ch, dir_t dir, int32_t steps)
{
    (void)ctx;
    return stepper_extend(ch, dir, steps);
}

static void port_motor_halt(void *ctx, uint8_t ch)
{
    (void)ctx;
    stepper_halt(ch);
}

static bool port_cal_save(void *ctx, const cal_t *cal)
{
    (void)ctx;
    return cal_store_save(cal);
}

/* ------------------------------------------------ producers of messages */

static bool IRAM_ATTR on_motion_end_isr(uint8_t ch, axis_status_t st, uint32_t tag, void *arg)
{
    (void)arg;
    ctl_msg_t msg;
    msg.kind = MSG_MOTION_END;
    msg.motion.ch = ch;
    msg.motion.st = st;
    msg.motion.tag = tag;
    BaseType_t woken = pdFALSE;
    /* May use every free slot; no logging in an ISR. */
    if (xQueueSendFromISR(s_ctl_queue, &msg, &woken) != pdTRUE)
        s_motion_ends_lost++;
    return woken == pdTRUE;
}

/* Writes and samples may be dropped (the app resends, the next window comes
 * in 500 ms), but never into the reserve. */
static void post_droppable(const ctl_msg_t *msg, const char *what)
{
    if (uxQueueSpacesAvailable(s_ctl_queue) <= CTL_QUEUE_RESERVE ||
        xQueueSend(s_ctl_queue, msg, 0) != pdTRUE)
        ESP_LOGW(TAG, "control queue full, %s dropped", what);
}

/* Losing a subscribe or a disconnect would leave the app without its first
 * events or the motors running with nobody connected: wait for a slot. */
static void post_critical(const ctl_msg_t *msg, const char *what)
{
    if (xQueueSend(s_ctl_queue, msg, pdMS_TO_TICKS(CRITICAL_POST_MS)) != pdTRUE)
        ESP_LOGE(TAG, "control queue full, %s lost", what);
}

static void on_ble_write(const uint8_t *data, size_t len)
{
    ctl_msg_t msg;
    msg.kind = MSG_WRITE;
    msg.write.len = (uint16_t)len;
    memcpy(msg.write.data, data, len < sizeof msg.write.data ? len : sizeof msg.write.data);
    post_droppable(&msg, "write");
}

static void on_ble_subscribe(void)
{
    ctl_msg_t msg = {.kind = MSG_SUBSCRIBE};
    post_critical(&msg, "subscribe");
}

static void on_ble_disconnect(void)
{
    ctl_msg_t msg = {.kind = MSG_DISCONNECT};
    post_critical(&msg, "disconnect");
}

/* ---------------------------------------------------------------- tasks */

static void sensor_task(void *arg)
{
    (void)arg;
    for (;;) {
        ctl_msg_t msg = {.kind = MSG_SAMPLE};
        msg.sample.ok = s_adc_ready && ph_adc_read(&msg.sample.v_adc_mv) == ESP_OK;
        post_droppable(&msg, "sample");
        if (!msg.sample.ok)
            vTaskDelay(pdMS_TO_TICKS(SAMPLE_PERIOD_MS)); /* failed reads keep the 2 Hz pace, even when they fail at once */
    }
}

static void dispatch(const ctl_msg_t *msg)
{
    switch (msg->kind) {
    case MSG_WRITE:
        device_on_write(&s_device, msg->write.data, msg->write.len, now_ms());
        break;
    case MSG_SUBSCRIBE:
        device_on_subscribe(&s_device);
        break;
    case MSG_DISCONNECT:
        device_on_disconnect(&s_device);
        break;
    case MSG_SAMPLE:
        device_on_sample(&s_device, msg->sample.ok, msg->sample.v_adc_mv, now_ms());
        break;
    case MSG_MOTION_END:
        device_on_motion_end(&s_device, msg->motion.ch, msg->motion.st, msg->motion.tag, now_ms());
        break;
    }
}

static void ctl_task(void *arg)
{
    (void)arg;
    /* Here, so the MCPWM interrupts are allocated on this core. */
    const axis_cfg_t axis_cfg = {
        .v_start = V_START_SPS,
        .v_max = V_MAX_SPS,
        .accel = ACCEL_SPS2,
        .stroke = STROKE_STEPS,
        .backlash = BACKLASH_STEPS,
        .limit_debounce = LIMIT_DEBOUNCE,
    };
    ESP_ERROR_CHECK(stepper_init(&axis_cfg, on_motion_end_isr, NULL));

    uint32_t lost_reported = 0;
    for (;;) {
        ctl_msg_t msg;
        if (xQueueReceive(s_ctl_queue, &msg, pdMS_TO_TICKS(CTL_TICK_MS)) == pdTRUE)
            dispatch(&msg);
        device_tick(&s_device, now_ms());

        uint32_t lost = s_motion_ends_lost;
        if (lost != lost_reported) {
            ESP_LOGE(TAG, "control queue full: %u motion end(s) lost", (unsigned)(lost - lost_reported));
            lost_reported = lost;
        }
    }
}

static void start_task(TaskFunction_t fn, const char *name, uint32_t stack, UBaseType_t prio)
{
    BaseType_t ok = xTaskCreatePinnedToCore(fn, name, stack, NULL, prio, NULL, APP_CORE);
    ESP_ERROR_CHECK(ok == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();
    ESP_LOGI(TAG, "titrator firmware %s, protocol v4, ESP-IDF %s", app->version, app->idf_ver);

    ESP_ERROR_CHECK(cal_store_init()); /* first: NVS is needed by the BT controller too */
    cal_t cal;
    if (!cal_store_load(&cal))
        cal = ph_cal_default();

    s_ctl_queue = xQueueCreate(CTL_QUEUE_LEN, sizeof(ctl_msg_t));
    ESP_ERROR_CHECK(s_ctl_queue ? ESP_OK : ESP_ERR_NO_MEM);

    const device_ports_t ports = {
        .emit = port_emit,
        .motor_start = port_motor_start,
        .motor_extend = port_motor_extend,
        .motor_halt = port_motor_halt,
        .cal_save = port_cal_save,
    };
    device_init(&s_device, &ports, &cal);

    /* Without the ADC the device still works: every window then counts as a
     * failed read, so `sensor` is reported after 2 s and BLE and the syringes
     * stay usable. */
    esp_err_t adc_err = ph_adc_init();
    s_adc_ready = adc_err == ESP_OK;
    if (!s_adc_ready)
        ESP_LOGE(TAG, "pH ADC init failed (%s), reporting read errors", esp_err_to_name(adc_err));
    start_task(ctl_task, "ctl", CTL_TASK_STACK, CTL_TASK_PRIO);
    start_task(sensor_task, "sensor", SENSOR_TASK_STACK, SENSOR_TASK_PRIO);

    /* Last: from here on the callbacks enqueue messages for the tasks above. */
    const ble_link_cbs_t cbs = {
        .on_write = on_ble_write,
        .on_subscribe = on_ble_subscribe,
        .on_disconnect = on_ble_disconnect,
    };
    ESP_ERROR_CHECK(ble_link_start(&cbs));
}
