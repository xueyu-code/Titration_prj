/* core/sensor_fault.c: protocol 3 electrode fault.
 * TODO(WP1): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/sensor_fault.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* below LO / above HI / failed read are at the rail; inside is not */
static void test_at_rail_thresholds(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* rail for < SENSOR_FAULT_MS, then a good sample: nothing */
static void test_short_rail_is_no_fault(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* true exactly once at >= SENSOR_FAULT_MS, then false while it lasts */
static void test_enters_once(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* active false after one good sample, no report */
static void test_clears_on_good_sample(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* a new run at the rail reports again */
static void test_reenters(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* works across the uint32_t millisecond wrap */
static void test_time_wraps(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_at_rail_thresholds);
    RUN_TEST(test_short_rail_is_no_fault);
    RUN_TEST(test_enters_once);
    RUN_TEST(test_clears_on_good_sample);
    RUN_TEST(test_reenters);
    RUN_TEST(test_time_wraps);
    return UNITY_END();
}
