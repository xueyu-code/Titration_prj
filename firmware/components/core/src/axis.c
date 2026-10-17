/*
 * Syringe axis, see core/axis.h. TODO(WP2): implement.
 *
 * Integer arithmetic only (axis_next runs in an ISR). Speed is kept in
 * steps/s * 256 (v_q8); one period is 256e6 / v_q8 microseconds; per period
 * the speed changes by accel * period_us / 3906 (= accel * dt * 256). The
 * distance needed to stop from v is (v^2 - v_start^2) / (2 * accel).
 * The whole object is placed in IRAM by linker.lf.
 */
#include "core/axis.h"

void axis_init(axis_t *a, const axis_cfg_t *cfg)
{
    *a = (axis_t){.cfg = *cfg, .status = AXIS_HALTED};
}

axis_status_t axis_start(axis_t *a, dir_t dir, int32_t steps, bool limit_active)
{
    (void)a;
    (void)dir;
    (void)steps;
    (void)limit_active;
    return AXIS_HALTED;
}

uint32_t axis_next(axis_t *a, int32_t pulses, bool limit_active)
{
    (void)a;
    (void)pulses;
    (void)limit_active;
    return 0;
}

bool axis_extend(axis_t *a, dir_t dir, int32_t steps)
{
    (void)a;
    (void)dir;
    (void)steps;
    return false;
}

void axis_finish(axis_t *a, int32_t pulses)
{
    (void)a;
    (void)pulses;
}
