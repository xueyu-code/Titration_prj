/* core/ph.c: protocol 2.4 conversions. */
#include <math.h>

#include "unity.h"
#include "core/ph.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* (V_adc - FE_BIAS_MV) / FE_GAIN */
static void test_electrode_mv(void)
{
    TEST_ASSERT_EQUAL_FLOAT(0.0f, ph_electrode_mv(FE_BIAS_MV));
    TEST_ASSERT_FLOAT_WITHIN(1e-3f, 10.0f, ph_electrode_mv(FE_BIAS_MV + 10.0f * FE_GAIN));
    TEST_ASSERT_FLOAT_WITHIN(1e-3f, -10.0f, ph_electrode_mv(FE_BIAS_MV - 10.0f * FE_GAIN));

    /* both ends of the ADC's 6 dB range */
    TEST_ASSERT_FLOAT_WITHIN(1e-2f, -FE_BIAS_MV / FE_GAIN, ph_electrode_mv(0.0f));
    TEST_ASSERT_FLOAT_WITHIN(1e-2f, (1600.0f - FE_BIAS_MV) / FE_GAIN, ph_electrode_mv(1600.0f));
}

/* 0 mV -> 7.00, +177.48 mV -> 4.00 at -59.16 mV/pH */
static void test_ph_from_mv_default_cal(void)
{
    const cal_t cal = ph_cal_default();

    TEST_ASSERT_EQUAL_FLOAT(7.0f, ph_from_mv(&cal, 0.0f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 4.0f, ph_from_mv(&cal, 177.48f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 10.0f, ph_from_mv(&cal, -177.48f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 6.0f, ph_from_mv(&cal, 59.16f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 0.0f, ph_from_mv(&cal, 414.12f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 14.0f, ph_from_mv(&cal, -414.12f));
}

/* offset and slope applied */
static void test_ph_from_mv_custom_cal(void)
{
    const cal_t cal = {.slope = -57.92f, .offset = 4.35f};

    /* pH 7 is at mv == offset; mv = offset + slope * (pH - 7) elsewhere */
    TEST_ASSERT_FLOAT_WITHIN(1e-5f, 7.0f, ph_from_mv(&cal, 4.35f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 4.0f, ph_from_mv(&cal, 4.35f + 3.0f * 57.92f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 10.0f, ph_from_mv(&cal, 4.35f - 3.0f * 57.92f));
    TEST_ASSERT_FLOAT_WITHIN(1e-4f, 7.0f + 4.35f / 57.92f, ph_from_mv(&cal, 0.0f));

    /* a steeper slope and a negative offset */
    {
        const cal_t steep = {.slope = -70.0f, .offset = -100.0f};

        TEST_ASSERT_FLOAT_WITHIN(1e-5f, 7.0f, ph_from_mv(&steep, -100.0f));
        TEST_ASSERT_FLOAT_WITHIN(1e-4f, 8.0f, ph_from_mv(&steep, -170.0f));
    }
}

/* boundaries inclusive, NaN invalid */
static void test_cal_valid_ranges(void)
{
    cal_t cal;

    /* the four corners and the factory values are inside */
    cal = (cal_t){.slope = CAL_SLOPE_MIN, .offset = CAL_OFFSET_MIN};
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = CAL_SLOPE_MAX, .offset = CAL_OFFSET_MAX};
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = CAL_SLOPE_MIN, .offset = CAL_OFFSET_MAX};
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = CAL_SLOPE_MAX, .offset = CAL_OFFSET_MIN};
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -59.16f, .offset = 0.0f};
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));

    /* one float step outside each bound */
    cal = (cal_t){.slope = nextafterf(CAL_SLOPE_MIN, -INFINITY), .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = nextafterf(CAL_SLOPE_MAX, 0.0f), .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -59.16f, .offset = nextafterf(CAL_OFFSET_MIN, -INFINITY)};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -59.16f, .offset = nextafterf(CAL_OFFSET_MAX, INFINITY)};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));

    /* a zero or positive slope (the conversion divides by it) */
    cal = (cal_t){.slope = 0.0f, .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = 59.16f, .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));

    /* NaN and infinity */
    cal = (cal_t){.slope = NAN, .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -59.16f, .offset = NAN};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -INFINITY, .offset = 0.0f};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
    cal = (cal_t){.slope = -59.16f, .offset = INFINITY};
    TEST_ASSERT_FALSE(ph_cal_valid(&cal));
}

/* -59.16 / 0 */
static void test_cal_default(void)
{
    const cal_t cal = ph_cal_default();

    TEST_ASSERT_EQUAL_FLOAT(-59.16f, cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(0.0f, cal.offset);
    TEST_ASSERT_TRUE(ph_cal_valid(&cal));
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_electrode_mv);
    RUN_TEST(test_ph_from_mv_default_cal);
    RUN_TEST(test_ph_from_mv_custom_cal);
    RUN_TEST(test_cal_valid_ranges);
    RUN_TEST(test_cal_default);
    return UNITY_END();
}
