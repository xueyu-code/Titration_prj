/* core/device.c with recording fake ports: protocol 3 behaviour, event order included.
 * TODO(WP3): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/device.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* state then cal */
static void test_subscribe_reports_state_and_cal(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* titrate and cal_set are busy while titrating or moving; stop/move/jog accepted */
static void test_state_table(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* unparsable or out of range -> error bad_cmd with msg; parse errors win over busy */
static void test_bad_cmd_with_reason(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* titrate -> state titrating; stop -> halt + state idle; stop when idle emits nothing */
static void test_titrate_and_stop(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* error sensor, state unchanged */
static void test_titrate_refused_on_sensor_fault(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* same ch/dir: motor_extend(MOVE_STEPS); extend fails -> new start */
static void test_move_accumulates(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* other ch or dir: halt, start the new one, no state change */
static void test_move_switches_motion(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* move while titrating -> state moving, titration over */
static void test_move_ends_titration(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* refresh keeps it going; JOG_TIMEOUT_MS without jog -> halt + state idle */
static void test_jog_watchdog(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* jog continues */
static void test_move_during_jog_is_noop(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* unhomed / limit refusal -> error with ch/dir, then state idle (if not idle) */
static void test_refused_motion(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* DONE -> idle; LIMIT_OUT/IN -> error limit ch/dir then idle; stale tag ignored */
static void test_motion_end(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* TITR_DOSE -> motor_start(out, round(ul / UL_PER_STEP)); DONE -> next wait */
static void test_dose_cycle(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* LIMIT_OUT during a dose -> error limit ch out, then idle */
static void test_dose_hits_empty_syringe(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* error no_converge, then idle */
static void test_no_converge(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* during titration: error sensor then idle; otherwise only the error, motion goes on */
static void test_sensor_fault_events(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* one ph per good sample with 2.4 conversion and current cal; none on failed read */
static void test_ph_events(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* idle: saved, applied, cal event; save failure still applies; busy otherwise */
static void test_cal_set(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

/* halt, titration over, idle */
static void test_disconnect_stops(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP3)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_subscribe_reports_state_and_cal);
    RUN_TEST(test_state_table);
    RUN_TEST(test_bad_cmd_with_reason);
    RUN_TEST(test_titrate_and_stop);
    RUN_TEST(test_titrate_refused_on_sensor_fault);
    RUN_TEST(test_move_accumulates);
    RUN_TEST(test_move_switches_motion);
    RUN_TEST(test_move_ends_titration);
    RUN_TEST(test_jog_watchdog);
    RUN_TEST(test_move_during_jog_is_noop);
    RUN_TEST(test_refused_motion);
    RUN_TEST(test_motion_end);
    RUN_TEST(test_dose_cycle);
    RUN_TEST(test_dose_hits_empty_syringe);
    RUN_TEST(test_no_converge);
    RUN_TEST(test_sensor_fault_events);
    RUN_TEST(test_ph_events);
    RUN_TEST(test_cal_set);
    RUN_TEST(test_disconnect_stops);
    return UNITY_END();
}
