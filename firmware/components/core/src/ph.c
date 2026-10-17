/* Voltage and pH conversion, see core/ph.h. TODO(WP1): implement. */
#include "core/ph.h"

#include "core/config.h"

float ph_electrode_mv(float v_adc_mv)
{
    (void)v_adc_mv;
    return 0.0f;
}

float ph_from_mv(const cal_t *cal, float mv)
{
    (void)cal;
    (void)mv;
    return 7.0f;
}

bool ph_cal_valid(const cal_t *cal)
{
    (void)cal;
    return false;
}

cal_t ph_cal_default(void)
{
    return (cal_t){.slope = CAL_DEFAULT_SLOPE, .offset = CAL_DEFAULT_OFFSET};
}
