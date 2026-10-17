/* Device behaviour, see core/device.h. TODO(WP3): implement. */
#include "core/device.h"

#include "core/clog.h"
#include "core/config.h"
#include "core/ph.h"

void device_init(device_t *d, const device_ports_t *ports, const cal_t *cal)
{
    *d = (device_t){.ports = *ports, .state = DEV_IDLE, .cal = *cal};
    sensor_fault_init(&d->sensor);
}

void device_on_write(device_t *d, const char *data, size_t len, uint32_t now_ms)
{
    (void)d;
    (void)data;
    (void)len;
    (void)now_ms;
}

void device_on_subscribe(device_t *d)
{
    (void)d;
}

void device_on_disconnect(device_t *d)
{
    (void)d;
}

void device_on_sample(device_t *d, bool read_ok, float v_adc_mv, uint32_t now_ms)
{
    (void)d;
    (void)read_ok;
    (void)v_adc_mv;
    (void)now_ms;
}

void device_on_motion_end(device_t *d, uint8_t ch, axis_status_t st, uint32_t tag, uint32_t now_ms)
{
    (void)d;
    (void)ch;
    (void)st;
    (void)tag;
    (void)now_ms;
}

void device_tick(device_t *d, uint32_t now_ms)
{
    (void)d;
    (void)now_ms;
}
