/* core/titration.c: protocol 4 loop, same decisions as sim_titrator.dart.
 * TODO(WP3): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/titration.h"
#include "core/config.h"
#include "core/types.h"

void setUp(void) {}
void tearDown(void) {}

/* nothing before SETTLE_SKIP_MS; decides after SETTLE_N settled readings */
static void test_waits_skip_then_window(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* |err| <= HOLD_TOL_PH: no dose, the wait restarts */
static void test_holds_within_tol(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* FIRST_DOSE_UL; acid above target, base below */
static void test_first_dose(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* unsettled readings: decision at SETTLE_MAX_MS on the window average */
static void test_settle_max_uses_average(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* DOSE_GAIN * |err| * last / gain, clamped */
static void test_dose_from_response(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* gain < SETTLE_SPAN_PH -> 2 * last, clamped to MAX_DOSE_UL */
static void test_weak_response_doubles(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* direction change halves the dose */
static void test_reversal_halves(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* MAX_REVERSALS-th reversal -> TITR_NO_CONVERGE */
static void test_third_reversal_gives_up(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* reversal right after a MIN_DOSE_UL dose -> TITR_NO_CONVERGE */
static void test_reversal_after_min_dose_gives_up(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* TITR_WAIT until titr_dose_done; the wait starts there */
static void test_ignores_readings_while_dosing(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_waits_skip_then_window);
    RUN_TEST(test_holds_within_tol);
    RUN_TEST(test_first_dose);
    RUN_TEST(test_settle_max_uses_average);
    RUN_TEST(test_dose_from_response);
    RUN_TEST(test_weak_response_doubles);
    RUN_TEST(test_reversal_halves);
    RUN_TEST(test_third_reversal_gives_up);
    RUN_TEST(test_reversal_after_min_dose_gives_up);
    RUN_TEST(test_ignores_readings_while_dosing);
    return UNITY_END();
}
