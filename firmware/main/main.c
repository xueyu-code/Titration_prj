/*
 * Wiring: tasks, the control queue and the device ports (DESIGN.md
 * "任务与线程模型"). TODO(WP4): implement the bodies.
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
#define CTL_TASK_PRIO 6u     /* above the sensor task, below NimBLE host */
#define SENSOR_TASK_PRIO 5u
#define CTL_TASK_STACK 6144u /* cJSON parse + snprintf with floats */
#define SENSOR_TASK_STACK 4096u

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

static uint32_t now_ms(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

/* --------------------------------------------------------- device ports */

static void port_emit(void *ctx, const evt_t *evt)
{
    (void)ctx;
    (void)evt; /* TODO: proto_encode_evt -> ble_link_notify */
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
    (void)ch;
    (void)st;
    (void)tag;
    (void)arg;
    return false; /* TODO: xQueueSendFromISR(MSG_MOTION_END) */
}

static void on_ble_write(const uint8_t *data, size_t len)
{
    (void)data;
    (void)len; /* TODO: copy into MSG_WRITE, xQueueSend(..., 0); log when full */
}

static void on_ble_subscribe(void)
{
    /* TODO: MSG_SUBSCRIBE */
}

static void on_ble_disconnect(void)
{
    /* TODO: MSG_DISCONNECT */
}

/* ---------------------------------------------------------------- tasks */

static void sensor_task(void *arg)
{
    (void)arg;
    /* TODO: loop { ok = ph_adc_read(&v) == ESP_OK; post MSG_SAMPLE } */
    vTaskDelete(NULL);
}

static void ctl_task(void *arg)
{
    (void)arg;
    /* TODO: stepper_init (here, so the MCPWM interrupts run on this core),
     * then loop: xQueueReceive(CTL_TICK_MS) -> dispatch to device_on_*,
     * device_tick(now) on every wake-up. */
    vTaskDelete(NULL);
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();
    ESP_LOGI(TAG, "titrator firmware %s, protocol v3, ESP-IDF %s", app->version, app->idf_ver);

    /* TODO(WP4), in this order:
     *  cal_store_init(); cal = cal_store_load() or ph_cal_default();
     *  s_ctl_queue = xQueueCreate(CTL_QUEUE_LEN, sizeof(ctl_msg_t));
     *  device_init(&s_device, &ports, &cal);
     *  ph_adc_init();
     *  xTaskCreatePinnedToCore(ctl_task, ..., 1); xTaskCreatePinnedToCore(sensor_task, ..., 1);
     *  ble_link_start(&cbs);  (last: callbacks only enqueue) */
    (void)s_ctl_queue;
    (void)s_device;
    (void)now_ms;
    (void)port_emit;
    (void)port_motor_start;
    (void)port_motor_extend;
    (void)port_motor_halt;
    (void)port_cal_save;
    (void)on_motion_end_isr;
    (void)on_ble_write;
    (void)on_ble_subscribe;
    (void)on_ble_disconnect;
    (void)sensor_task;
    (void)ctl_task;
}
