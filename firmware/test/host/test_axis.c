/* core/axis.c: drive axis_next() like the MCPWM ISR does (pulses = periods so far).
 * TODO(WP2): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/axis.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* in unhomed -> UNHOMED; in at stroke -> LIMIT_IN; out with switch -> LIMIT_OUT and homed at 0 */
static void test_start_refusals(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* N counted steps -> exactly N periods with a pulse, then 0 / AXIS_DONE */
static void test_finite_move_exact(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* first period 1e6/v_start; never faster than v_max; accelerates, cruises, decelerates to ~v_start */
static void test_profile_trapezoid(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* short move never reaches v_max and still ends slow */
static void test_profile_triangle(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* LIMIT_DEBOUNCE consecutive active samples -> 0 / LIMIT_OUT, pos 0, homed */
static void test_limit_out_homes(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* one active sample between inactive ones does not stop */
static void test_limit_glitch_ignored(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* homed at stroke - 10, continuous in -> LIMIT_IN after 10 steps, pos = stroke */
static void test_soft_limit_in(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* continuous out runs until the switch */
static void test_jog_out_until_switch(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* same dir adds steps; continuous; other dir or not running -> false */
static void test_extend(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* axis_finish on a running axis -> HALTED, pos from pulses */
static void test_halt_by_finish(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* an extra pulse after the stop decision is reflected in pos */
static void test_finish_uses_final_count(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* reversal adds cfg.backlash uncounted pulses; same direction does not; none on the first motion */
static void test_backlash(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

/* v_start..v_max and accel from config.h: no 32-bit overflow (UBSan clean) */
static void test_no_overflow_at_limits(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP2)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_start_refusals);
    RUN_TEST(test_finite_move_exact);
    RUN_TEST(test_profile_trapezoid);
    RUN_TEST(test_profile_triangle);
    RUN_TEST(test_limit_out_homes);
    RUN_TEST(test_limit_glitch_ignored);
    RUN_TEST(test_soft_limit_in);
    RUN_TEST(test_jog_out_until_switch);
    RUN_TEST(test_extend);
    RUN_TEST(test_halt_by_finish);
    RUN_TEST(test_finish_uses_final_count);
    RUN_TEST(test_backlash);
    RUN_TEST(test_no_overflow_at_limits);
    return UNITY_END();
}
