/* Electrode fault detection, see core/sensor_fault.h. */
#include "core/sensor_fault.h"

#include "core/config.h"

void sensor_fault_init(sensor_fault_t *sf)
{
    *sf = (sensor_fault_t){0};
}

/* Written so that NaN is at the rail. */
bool sensor_fault_at_rail(bool read_ok, float v_adc_mv)
{
    return !read_ok || !(v_adc_mv > SENSOR_RAIL_LO_MV && v_adc_mv < SENSOR_RAIL_HI_MV);
}

bool sensor_fault_update(sensor_fault_t *sf, bool at_rail, uint32_t now_ms)
{
    if (!at_rail) {
        sf->at_rail = false;
        sf->active = false;
        return false;
    }
    if (!sf->at_rail) {
        sf->at_rail = true;
        sf->since_ms = now_ms;
    }
    if (!sf->active && (uint32_t)(now_ms - sf->since_ms) >= SENSOR_FAULT_MS) {
        sf->active = true;
        return true;
    }
    return false;
}
