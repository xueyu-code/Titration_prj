/* core/sensor_fault.c: protocol 3 electrode fault. */
#include <math.h>

#include "unity.h"
#include "core/sensor_fault.h"
#include "core/config.h"

#define SAMPLE_MS 500u /* one `ph` sample: SAMPLE_PERIOD_MS */

void setUp(void) {}
void tearDown(void) {}

/* Feeds `n` samples at the rail, SAMPLE_MS apart from t0; returns how many times the fault was
 * reported. */
static int feed_rail(sensor_fault_t *sf, uint32_t t0, int n)
{
    int reports = 0;

    for (int i = 0; i < n; i++)
        reports += sensor_fault_update(sf, true, t0 + (uint32_t)i * SAMPLE_MS);
    return reports;
}

/* below LO / above HI / failed read are at the rail; inside is not */
static void test_at_rail_thresholds(void)
{
    TEST_ASSERT_FALSE(sensor_fault_at_rail(true, 1000.0f));
    TEST_ASSERT_FALSE(sensor_fault_at_rail(true, SENSOR_RAIL_LO_MV + 0.5f));
    TEST_ASSERT_FALSE(sensor_fault_at_rail(true, SENSOR_RAIL_HI_MV - 0.5f));

    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, SENSOR_RAIL_LO_MV)); /* the rails themselves count */
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, SENSOR_RAIL_HI_MV));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, 0.0f));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, -5.0f));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, 1600.0f));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, 3300.0f));

    /* a failed read is at the rail whatever the value says */
    TEST_ASSERT_TRUE(sensor_fault_at_rail(false, 1000.0f));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(false, 0.0f));

    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, NAN));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, INFINITY));
    TEST_ASSERT_TRUE(sensor_fault_at_rail(true, -INFINITY));
}

/* rail for < SENSOR_FAULT_MS, then a good sample: nothing */
static void test_short_rail_is_no_fault(void)
{
    sensor_fault_t sf;

    sensor_fault_init(&sf);
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));

    /* samples at 0, 500, 1000, 1500 ms: 1.5 s at the rail */
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, 1000, 4));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));

    TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, 1000 + 4 * SAMPLE_MS));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));

    /* good samples alone never report */
    for (uint32_t t = 0; t < 10000; t += SAMPLE_MS)
        TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, t));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
}

/* true exactly once at >= SENSOR_FAULT_MS, then false while it lasts */
static void test_enters_once(void)
{
    sensor_fault_t sf;
    const uint32_t t0 = 5000;

    sensor_fault_init(&sf);
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, true, t0)); /* the run starts here */
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, true, t0 + SENSOR_FAULT_MS - 1));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
    TEST_ASSERT_TRUE(sensor_fault_update(&sf, true, t0 + SENSOR_FAULT_MS)); /* exactly the duration */
    TEST_ASSERT_TRUE(sensor_fault_active(&sf));

    /* while it lasts: never again */
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, t0 + SENSOR_FAULT_MS + SAMPLE_MS, 100));
    TEST_ASSERT_TRUE(sensor_fault_active(&sf));

    /* at the 2 Hz sampling rate it is reported by the fifth sample at the rail (2.0 s) */
    sensor_fault_init(&sf);
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, 0, 4));
    TEST_ASSERT_TRUE(sensor_fault_update(&sf, true, 4 * SAMPLE_MS));
}

/* active false after one good sample, no report */
static void test_clears_on_good_sample(void)
{
    sensor_fault_t sf;

    sensor_fault_init(&sf);
    TEST_ASSERT_EQUAL(1, feed_rail(&sf, 0, 10));
    TEST_ASSERT_TRUE(sensor_fault_active(&sf));

    TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, 10 * SAMPLE_MS));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, 11 * SAMPLE_MS));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
}

/* a new run at the rail reports again */
static void test_reenters(void)
{
    sensor_fault_t sf;

    sensor_fault_init(&sf);
    TEST_ASSERT_EQUAL(1, feed_rail(&sf, 0, 10));
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, 10 * SAMPLE_MS));

    /* the clock of the new run starts at its own first sample, not at the old one */
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, 11 * SAMPLE_MS, 4));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
    TEST_ASSERT_TRUE(sensor_fault_update(&sf, true, 11 * SAMPLE_MS + SENSOR_FAULT_MS));
    TEST_ASSERT_TRUE(sensor_fault_active(&sf));

    /* a good sample in the middle of a run restarts the timing */
    sensor_fault_init(&sf);
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, 0, 3));
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, false, 3 * SAMPLE_MS));
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, 4 * SAMPLE_MS, 4));
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
    TEST_ASSERT_EQUAL(1, feed_rail(&sf, 8 * SAMPLE_MS, 1));
}

/* works across the uint32_t millisecond wrap */
static void test_time_wraps(void)
{
    sensor_fault_t sf;
    const uint32_t t0 = UINT32_MAX - 1000; /* the run crosses the wrap after 1.0 s */

    sensor_fault_init(&sf);
    TEST_ASSERT_EQUAL(0, feed_rail(&sf, t0, 4)); /* t0 .. t0 + 1500: wraps after the third sample */
    TEST_ASSERT_FALSE(sensor_fault_active(&sf));
    TEST_ASSERT_TRUE(sensor_fault_update(&sf, true, t0 + SENSOR_FAULT_MS)); /* 999 after the wrap */
    TEST_ASSERT_TRUE(sensor_fault_active(&sf));

    /* a run that starts exactly at the last millisecond */
    sensor_fault_init(&sf);
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, true, UINT32_MAX));
    TEST_ASSERT_FALSE(sensor_fault_update(&sf, true, SENSOR_FAULT_MS - 2));
    TEST_ASSERT_TRUE(sensor_fault_update(&sf, true, SENSOR_FAULT_MS - 1));
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
