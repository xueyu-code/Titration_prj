/*
 * Two step/dir channels on hardware pulse generation (DESIGN.md "步进脉冲").
 *
 * Per channel: one MCPWM timer + operator + comparator + generator drive the
 * STEP pin (rising edge in the middle of each period: TEZ -> low, compare at
 * period/2 -> high), one PCNT unit counts the pulses on the same pin, and the
 * timer's "empty" interrupt calls axis_next() once per period to set the next
 * period or to stop. Stopping forces the generator low at once (hold) and
 * stops the timer, so a pulse is either fully out and counted or not out.
 * The limit switch is sampled in that interrupt, i.e. before every pulse.
 * The two channels share no hardware and no lock.
 *
 * Shared ENN: drivers are enabled once by stepper_init() and stay enabled;
 * the TMC2209 lowers the current itself at standstill (PDN tied to GND).
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "core/axis.h"
#include "esp_err.h"

/*
 * Called from the MCPWM ISR when a motion ends by itself (AXIS_DONE,
 * AXIS_LIMIT_OUT, AXIS_LIMIT_IN), after the axis has been finished with the
 * final count. Not called for stepper_halt(). Must be IRAM-safe and fast;
 * returns true when it woke a higher-priority task (portYIELD_FROM_ISR).
 */
typedef bool (*stepper_end_cb_t)(uint8_t ch, axis_status_t st, uint32_t tag, void *arg);

/*
 * Configures GPIOs, MCPWM, PCNT for both channels with the same axis config
 * and enables the drivers. The interrupts land on the calling core: call it
 * from the control task (pinned to core 1, away from the BLE controller).
 */
esp_err_t stepper_init(const axis_cfg_t *cfg, stepper_end_cb_t on_end, void *arg);

/* Halts ch if it moves, then starts a new motion (see axis_start for steps
 * and refusals). Returns AXIS_RUNNING or the refusal; nothing moves then. */
axis_status_t stepper_start(uint8_t ch, dir_t dir, int32_t steps, uint32_t tag);

/* axis_extend() on the running motion of ch. False if it is not running in
 * dir any more. */
bool stepper_extend(uint8_t ch, dir_t dir, int32_t steps);

/* Stops ch at once and finalises its position. No end callback. */
void stepper_halt(uint8_t ch);

/* Switch level now (debug and logs). */
bool stepper_limit_active(uint8_t ch);
