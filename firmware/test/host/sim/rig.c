/* Closed-loop rig, see sim/rig.h. TODO(WP4): implement. */
#include "sim/rig.h"

#include <stdlib.h>

#include "core/axis.h"
#include "core/config.h"
#include "sim/beaker.h"

struct rig {
    rig_cfg_t cfg;
    device_t device;
    axis_t axis[CH_COUNT];
    beaker_t beaker;
};

rig_t *rig_create(const rig_cfg_t *cfg)
{
    rig_t *r = calloc(1, sizeof *r);
    if (r)
        r->cfg = *cfg;
    return r;
}

void rig_destroy(rig_t *r)
{
    free(r);
}

void rig_write(rig_t *r, const char *json)
{
    (void)r;
    (void)json;
}

void rig_run(rig_t *r, uint32_t ms)
{
    (void)r;
    (void)ms;
}

rig_result_t rig_titrate(rig_t *r, double target, uint32_t max_ms)
{
    (void)r;
    (void)target;
    (void)max_ms;
    return (rig_result_t){0};
}

void rig_set_fault(rig_t *r, bool fault)
{
    (void)r;
    (void)fault;
}

dev_state_t rig_state(const rig_t *r)
{
    return device_state(&r->device);
}

size_t rig_event_count(const rig_t *r)
{
    (void)r;
    return 0;
}

const evt_t *rig_event(const rig_t *r, size_t i)
{
    (void)r;
    (void)i;
    return NULL;
}

double rig_syringe_ul(const rig_t *r, uint8_t ch)
{
    (void)r;
    (void)ch;
    return 0.0;
}

const axis_t *rig_axis(const rig_t *r, uint8_t ch)
{
    return &r->axis[ch];
}
