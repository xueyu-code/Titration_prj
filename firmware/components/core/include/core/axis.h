/*
 * One syringe axis: position bookkeeping, homing on the empty-end switch, the
 * soft limit of "in", backlash, and a trapezoidal speed profile.
 *
 * The STEP pulses come from hardware (MCPWM, see platform/stepper.h). The
 * hardware also counts them (PCNT), and that count is the truth: every call
 * below that needs to know how far the motion got takes `pulses`, the
 * hardware count of pulses emitted since axis_start().
 *
 * Contract with the platform, per motion:
 *
 *   task  axis_start()      -> AXIS_RUNNING, or a refusal (nothing moves)
 *   task  axis_next(a, 0)   -> length of the first pulse period; start the
 *                              generator with it
 *   ISR   axis_next(a, n)   -> at the start of every following period. Non-zero:
 *                              the length of this period, which will contain
 *                              one pulse. 0: suppress this period's pulse and
 *                              stop the generator; a->status says why.
 *   ISR/task axis_finish(a, n_final) once the generator has stopped, with the
 *                              final hardware count; finalises the position.
 *   task  axis_extend(), or axis_finish() on a running axis (= halt), under
 *         the same critical section as the ISR.
 *
 * Pure C with integer arithmetic only: axis_next() runs in an ISR, and on the
 * ESP32-S3 (Xtensa) the FPU must not be used in ISRs. No logging here either.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "core/types.h"

/* `steps` value for a motion without a step count (jog). It still stops at
 * the switch ("out") or the soft limit ("in"). */
#define AXIS_CONTINUOUS INT32_MAX

typedef enum {
    AXIS_RUNNING = 0,
    AXIS_DONE,      /* all requested steps emitted */
    AXIS_LIMIT_OUT, /* empty-end switch: position is now 0 and the axis homed;
                       also the refusal of "out" with the switch already active */
    AXIS_LIMIT_IN,  /* soft limit (cfg.stroke) reached, or refusal of "in" there */
    AXIS_UNHOMED,   /* refusal of "in" before the first homing */
    AXIS_HALTED,    /* stopped by axis_finish() while running */
} axis_status_t;

typedef struct {
    uint32_t v_start;       /* steps/s; start and stop speed */
    uint32_t v_max;         /* steps/s */
    uint32_t accel;         /* steps/s^2 */
    int32_t stroke;         /* soft limit of "in", steps from the empty end */
    uint16_t backlash;      /* uncounted pulses added after a direction reversal */
    uint8_t limit_debounce; /* consecutive active switch samples that count */
} axis_cfg_t;

/* Fields are private to axis.c; read them through the accessors. */
typedef struct {
    axis_cfg_t cfg;

    /* Kept across motions. */
    int32_t pos;   /* steps from the empty end; meaningful once homed */
    bool homed;    /* the switch has triggered since power-up */
    dir_t last_dir;
    bool has_moved; /* last_dir is valid */

    /* Current motion. */
    axis_status_t status;
    dir_t dir;
    int32_t steps;       /* counted steps requested, or AXIS_CONTINUOUS */
    int32_t backlash;    /* leading pulses of this motion that do not count */
    int32_t pos0;        /* pos at axis_start() */
    uint32_t v_q8;       /* current speed, steps/s * 256 */
    uint32_t period_us;  /* length of the current period */
    uint8_t limit_hits;  /* consecutive active switch samples */
} axis_t;

/* cfg is copied. Starts unhomed, at rest (status AXIS_HALTED). */
void axis_init(axis_t *a, const axis_cfg_t *cfg);

/*
 * Starts a motion of `steps` counted steps (>= 1) or AXIS_CONTINUOUS.
 * limit_active: the switch level right now. Checks, in this order:
 *   "in" and not homed                 -> AXIS_UNHOMED
 *   "in" and pos >= stroke             -> AXIS_LIMIT_IN
 *   "out" and limit_active             -> AXIS_LIMIT_OUT (and homes: pos = 0)
 * and returns AXIS_RUNNING otherwise. Must not be called while running.
 */
axis_status_t axis_start(axis_t *a, dir_t dir, int32_t steps, bool limit_active);

/*
 * Plans the period that starts now. pulses: hardware count since
 * axis_start(); limit_active: switch level now. Returns the period length in
 * microseconds (> 0, one pulse in it), or 0 to stop (status becomes
 * AXIS_DONE, AXIS_LIMIT_OUT or AXIS_LIMIT_IN). ISR-safe.
 */
uint32_t axis_next(axis_t *a, int32_t pulses, bool limit_active);

/*
 * Adds steps (or AXIS_CONTINUOUS) to the running motion if it runs in dir.
 * Returns false when it is not running in dir (finished or other way); the
 * caller then starts a new motion.
 */
bool axis_extend(axis_t *a, dir_t dir, int32_t steps);

/*
 * Closes the motion once no more pulses can come: pos from the final count
 * (stays 0 after AXIS_LIMIT_OUT). On a still-running axis this is the halt:
 * status becomes AXIS_HALTED. Idempotent.
 */
void axis_finish(axis_t *a, int32_t pulses);

static inline axis_status_t axis_status(const axis_t *a) { return a->status; }
static inline bool axis_homed(const axis_t *a) { return a->homed; }
static inline int32_t axis_pos(const axis_t *a) { return a->pos; }
