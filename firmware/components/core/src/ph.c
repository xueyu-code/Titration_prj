/* Voltage and pH conversion, see core/ph.h. */
#include "core/ph.h"

#include "core/config.h"

float ph_electrode_mv(float v_adc_mv)
{
    return (v_adc_mv - FE_BIAS_MV) / FE_GAIN;
}

float ph_from_mv(const cal_t *cal, float mv)
{
    return 7.0f + (mv - cal->offset) / cal->slope;
}

/* Written so that NaN fails every comparison and is invalid. */
bool ph_cal_valid(const cal_t *cal)
{
    return cal->slope >= CAL_SLOPE_MIN && cal->slope <= CAL_SLOPE_MAX &&
           cal->offset >= CAL_OFFSET_MIN && cal->offset <= CAL_OFFSET_MAX;
}

cal_t ph_cal_default(void)
{
    return (cal_t){.slope = CAL_DEFAULT_SLOPE, .offset = CAL_DEFAULT_OFFSET};
}
