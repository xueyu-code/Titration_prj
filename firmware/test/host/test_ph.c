/* core/ph.c: protocol 2.4 conversions.
 * TODO(WP1): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/ph.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* (V_adc - FE_BIAS_MV) / FE_GAIN */
static void test_electrode_mv(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* 0 mV -> 7.00, +177.48 mV -> 4.00 at -59.16 mV/pH */
static void test_ph_from_mv_default_cal(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* offset and slope applied */
static void test_ph_from_mv_custom_cal(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* boundaries inclusive, NaN invalid */
static void test_cal_valid_ranges(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* -59.16 / 0 */
static void test_cal_default(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
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
