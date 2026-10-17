/*
 * Syringe axis, see core/axis.h.
 *
 * Integer arithmetic only (axis_next runs in an ISR). Speed is kept in
 * steps/s * 256 (v_q8); one period is 256e6 / v_q8 microseconds; per period
 * the speed changes by accel * period_us / 3906 (= accel * dt * 256). The
 * distance needed to stop from v is (v^2 - v_start^2) / (2 * accel).
 * The whole object is placed in IRAM by linker.lf.
 *
 * Counting. `pulses` is the hardware count since axis_start(), and the first
 * `backlash` of them do not move the plunger in the counted sense. With
 *     done = max(0, pulses - backlash)
 * a motion has `steps - done` counted steps left, and when the plunger moves
 * "in" it also has `stroke - pos0 - done` steps left before the soft limit.
 * axis_next() stops when either is used up (or when the switch confirms), so
 * a late call that sees one pulse too many still stops, and axis_finish()
 * books whatever the hardware really emitted.
 *
 * `steps == 0` means "no open motion": axis_init() leaves it so, axis_start()
 * sets it to >= 1, axis_finish() clears it again, which makes finishing twice
 * harmless.
 */
#include "core/axis.h"

#define Q8 256u
#define PERIOD_NUM 256000000u /* 1e6 us/s * 256: period_us = PERIOD_NUM / v_q8 */
#define ACCEL_DIV 3906u       /* 1e6 / 256: dv_q8 = accel * period_us / ACCEL_DIV */
#define V_LIMIT 65535u        /* v^2 must fit 32 bits */

/* The cfg is clamped to what the 32-bit arithmetic below can carry; the
 * values of config.h are far inside these bounds. */
void axis_init(axis_t *a, const axis_cfg_t *cfg)
{
    *a = (axis_t){.cfg = *cfg, .status = AXIS_HALTED};
    axis_cfg_t *c = &a->cfg;

    if (c->v_start < 1)
        c->v_start = 1;
    if (c->v_start > V_LIMIT)
        c->v_start = V_LIMIT;
    if (c->v_max < c->v_start)
        c->v_max = c->v_start;
    if (c->v_max > V_LIMIT)
        c->v_max = V_LIMIT;
    /* accel * period_us must fit 32 bits, and the longest period is 1e6 / v_start. */
    uint32_t accel_max = UINT32_MAX / (1000000u / c->v_start);
    if (c->accel < 1)
        c->accel = 1;
    if (c->accel > accel_max)
        c->accel = accel_max;
}

/* Steps needed to slow down from v_q8 to the start speed. */
static uint32_t stop_steps(const axis_cfg_t *c, uint32_t v_q8)
{
    uint32_t v = v_q8 / Q8;
    if (v <= c->v_start)
        return 0;
    return (v * v - c->v_start * c->v_start) / (2u * c->accel);
}

axis_status_t axis_start(axis_t *a, dir_t dir, int32_t steps, bool limit_active)
{
    /* Nothing to do: no motion starts and nothing else changes (steps == 0
     * must stay "no open motion"). The callers never ask for this. */
    if (steps <= 0)
        return AXIS_DONE;

    if (dir == DIR_IN) {
        if (!a->homed)
            return AXIS_UNHOMED;
        if (a->pos >= a->cfg.stroke)
            return AXIS_LIMIT_IN;
    } else if (limit_active) {
        /* The switch is the home position, so this is a homing as well. */
        a->pos = 0;
        a->homed = true;
        return AXIS_LIMIT_OUT;
    }

    a->status = AXIS_RUNNING;
    a->dir = dir;
    a->steps = steps;
    a->backlash = (a->has_moved && dir != a->last_dir) ? a->cfg.backlash : 0;
    a->pos0 = a->pos;
    a->v_q8 = a->cfg.v_start * Q8;
    a->period_us = 0;
    a->limit_hits = 0;
    return AXIS_RUNNING;
}

uint32_t axis_next(axis_t *a, int32_t pulses, bool limit_active)
{
    if (a->status != AXIS_RUNNING)
        return 0;

    /* The switch only matters towards the empty end. A confirmed hit is also
     * a homing, and it wins over "all steps done" because that is the only
     * place the position gets corrected. */
    if (a->dir == DIR_OUT) {
        if (!limit_active)
            a->limit_hits = 0;
        else if (a->limit_hits < UINT8_MAX)
            a->limit_hits++;
        if (a->limit_hits >= a->cfg.limit_debounce) {
            a->status = AXIS_LIMIT_OUT;
            a->pos = 0;
            a->homed = true;
            return 0;
        }
    }

    int32_t done = pulses > a->backlash ? pulses - a->backlash : 0;
    int32_t left = a->steps - done; /* counted steps still wanted */
    if (left <= 0) {
        a->status = AXIS_DONE;
        return 0;
    }
    if (a->dir == DIR_IN) {
        int32_t room = a->cfg.stroke - a->pos0 - done; /* steps to the soft limit */
        if (room <= 0) {
            a->status = AXIS_LIMIT_IN;
            return 0;
        }
        if (room < left)
            left = room;
    }

    /* This period runs at the current speed; then plan the speed of the next
     * one: slow down once the steps left after this one are no more than the
     * stopping distance, else speed up. Below v_start there is no ramp. */
    uint32_t period = PERIOD_NUM / a->v_q8;
    uint32_t dv = a->cfg.accel * period / ACCEL_DIV;
    uint32_t v_lo = a->cfg.v_start * Q8;
    uint32_t v_hi = a->cfg.v_max * Q8;

    if ((uint32_t)(left - 1) <= stop_steps(&a->cfg, a->v_q8))
        a->v_q8 = a->v_q8 > v_lo + dv ? a->v_q8 - dv : v_lo;
    else
        a->v_q8 = a->v_q8 + dv < v_hi ? a->v_q8 + dv : v_hi;

    a->period_us = period;
    return period;
}

bool axis_extend(axis_t *a, dir_t dir, int32_t steps)
{
    if (a->status != AXIS_RUNNING || a->dir != dir)
        return false;
    if (steps == AXIS_CONTINUOUS || a->steps == AXIS_CONTINUOUS || a->steps > INT32_MAX - steps)
        a->steps = AXIS_CONTINUOUS;
    else
        a->steps += steps;
    return true;
}

void axis_finish(axis_t *a, int32_t pulses)
{
    if (a->steps == 0)
        return; /* already closed */
    if (a->status == AXIS_RUNNING)
        a->status = AXIS_HALTED;

    /* The slack is only taken up once the motor really turned. */
    if (pulses > 0) {
        a->last_dir = a->dir;
        a->has_moved = true;
    }
    /* After the switch the position is 0 by definition (set in axis_next). */
    if (a->status != AXIS_LIMIT_OUT) {
        int32_t done = pulses > a->backlash ? pulses - a->backlash : 0;
        int32_t pos = a->dir == DIR_IN ? a->pos0 + done : a->pos0 - done;
        a->pos = pos > 0 ? pos : 0;
    }
    a->steps = 0;
}
