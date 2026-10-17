/*
 * Step pulses on MCPWM + PCNT, see platform/stepper.h. TODO(WP2): implement.
 *
 * Per channel: mcpwm timer (1 MHz, up, update_period_on_empty), operator,
 * comparator (update_cmp_on_tez, value = period / 2), generator on STEP with
 * io_loop_back (TEZ -> low, compare -> high), PCNT unit on the same pin
 * (rising edge +1, accum_count with the limits as watch points), DIR and
 * LIMIT GPIOs, one portMUX shared by the ISR and the task-side calls.
 * The TEZ after STOP_EMPTY still interrupts once: ignore it when the
 * channel is no longer running.
 */
#include "platform/stepper.h"

#include "driver/gpio.h"
#include "driver/mcpwm_prelude.h"
#include "driver/pulse_cnt.h"
#include "esp_attr.h"
#include "esp_log.h"
#include "platform/board.h"

esp_err_t stepper_init(const axis_cfg_t *cfg, stepper_end_cb_t on_end, void *arg)
{
    (void)cfg;
    (void)on_end;
    (void)arg;
    return ESP_ERR_NOT_SUPPORTED;
}

axis_status_t stepper_start(uint8_t ch, dir_t dir, int32_t steps, uint32_t tag)
{
    (void)ch;
    (void)dir;
    (void)steps;
    (void)tag;
    return AXIS_HALTED;
}

bool stepper_extend(uint8_t ch, dir_t dir, int32_t steps)
{
    (void)ch;
    (void)dir;
    (void)steps;
    return false;
}

void stepper_halt(uint8_t ch)
{
    (void)ch;
}

bool stepper_limit_active(uint8_t ch)
{
    (void)ch;
    return false;
}
