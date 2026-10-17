/* device + axis + titration in sim/rig.c. Passes once WP1-WP3 are merged.
 * TODO(WP4): implement every case below; none may stay ignored. */
#include "unity.h"
#include "sim/rig.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* start 5.5 / 6.5 / 8.5 x target 5.00 / 7.00 / 9.00: completed within 10 min, no errors */
static void test_buffered_converges(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* plain water sample, target 7.00: error no_converge then idle */
static void test_unbuffered_gives_up(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* 30 uL of base, far target: error limit ch 2 out, then idle, axis homed */
static void test_empty_syringe(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* fault mid-titration: error sensor then idle within ~2.5 s */
static void test_sensor_fault_stops(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

/* in before homing -> unhomed; jog out to the switch -> limit out; jog in -> limit in at the stroke; positions match the rig */
static void test_manual_homing(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP4)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_buffered_converges);
    RUN_TEST(test_unbuffered_gives_up);
    RUN_TEST(test_empty_syringe);
    RUN_TEST(test_sensor_fault_stops);
    RUN_TEST(test_manual_homing);
    return UNITY_END();
}
