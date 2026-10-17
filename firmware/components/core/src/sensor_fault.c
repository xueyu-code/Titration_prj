/* Electrode fault detection, see core/sensor_fault.h. TODO(WP1): implement. */
#include "core/sensor_fault.h"

#include "core/config.h"

void sensor_fault_init(sensor_fault_t *sf)
{
    *sf = (sensor_fault_t){0};
}

bool sensor_fault_at_rail(bool read_ok, float v_adc_mv)
{
    (void)read_ok;
    (void)v_adc_mv;
    return false;
}

bool sensor_fault_update(sensor_fault_t *sf, bool at_rail, uint32_t now_ms)
{
    (void)sf;
    (void)at_rail;
    (void)now_ms;
    return false;
}
