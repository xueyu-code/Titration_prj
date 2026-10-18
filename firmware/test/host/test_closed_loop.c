/* device + axis + titration in sim/rig.c. */
#include <stdio.h>

#include "unity.h"
#include "sim/rig.h"
#include "core/config.h"

#define TEN_MINUTES_MS (10u * 60u * 1000u)
#define NOT_FOUND ((size_t)-1)

static rig_t *s_rig; /* the rig of the running test; tearDown frees it, also after a failure */

void setUp(void) {}

void tearDown(void)
{
    rig_destroy(s_rig);
    s_rig = NULL;
}

static rig_t *new_rig(const rig_cfg_t *cfg)
{
    rig_destroy(s_rig);
    s_rig = rig_create(cfg);
    TEST_ASSERT_NOT_NULL(s_rig);
    return s_rig;
}

/* A calibrated 7.00 sample with plenty of reagent. */
static rig_cfg_t default_cfg(void)
{
    return (rig_cfg_t){
        .sample_ph = 7.0,
        .buffered = true,
        .syringe_ul = {8000.0, 8000.0},
        .seed = 1,
        .calibrated = true,
    };
}

/* Index of the first `error` event with this code at or after from. */
static size_t find_error(const rig_t *r, err_code_t code, size_t from)
{
    for (size_t i = from; i < rig_event_count(r); i++) {
        const evt_t *e = rig_event(r, i);
        if (e->kind == EVT_ERROR && e->error.code == code)
            return i;
    }
    return NOT_FOUND;
}

/* Event i is an error on channel ch, direction dir. */
static void assert_error_at(const rig_t *r, size_t i, uint8_t ch, dir_t dir)
{
    TEST_ASSERT_TRUE(i != NOT_FOUND);
    const evt_t *e = rig_event(r, i);
    TEST_ASSERT_EQUAL_INT(ch, e->error.ch);
    TEST_ASSERT_EQUAL_INT(dir, e->error.dir);
}

/* The device stops by itself: `state: idle` comes right after the error. */
static void assert_idle_follows(const rig_t *r, size_t i)
{
    TEST_ASSERT_TRUE(i != NOT_FOUND);
    const evt_t *next = rig_event(r, i + 1);
    TEST_ASSERT_NOT_NULL(next);
    TEST_ASSERT_EQUAL_INT(EVT_STATE, next->kind);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, next->state);
}

static int total_errors(const rig_result_t *res)
{
    int n = 0;
    for (int i = 0; i < ERR_COUNT; i++)
        n += res->errors[i];
    return n;
}

/* The jog button: resend every 300 ms until the device stops by itself. */
static void jog_until_idle(rig_t *r, const char *json)
{
    for (uint32_t t = 0; t < 60000; t += 300) {
        rig_write(r, json);
        rig_run(r, 300);
        if (rig_state(r) == DEV_IDLE)
            return;
    }
    TEST_FAIL_MESSAGE("jog did not end");
}

/* The plunger of ch is where the axis thinks it is. */
static void assert_position_matches(const rig_t *r, uint8_t ch)
{
    TEST_ASSERT_TRUE(axis_homed(rig_axis(r, ch)));
    TEST_ASSERT_DOUBLE_WITHIN(0.01, (double)axis_pos(rig_axis(r, ch)) * UL_PER_STEP,
                              rig_syringe_ul(r, ch));
}

/* start 5.5 / 6.5 / 8.5 x target 5.00 / 7.00 / 9.00: completed within 10 min, no errors */
static void test_buffered_converges(void)
{
    const double starts[] = {5.5, 6.5, 8.5};
    const double targets[] = {5.0, 7.0, 9.0};
    uint32_t seed = 1;

    for (size_t i = 0; i < 3; i++) {
        for (size_t j = 0; j < 3; j++) {
            char msg[64];
            snprintf(msg, sizeof msg, "start %.1f target %.2f", starts[i], targets[j]);

            rig_cfg_t cfg = default_cfg();
            cfg.sample_ph = starts[i];
            cfg.seed = seed++;
            rig_t *r = new_rig(&cfg);

            rig_result_t res = rig_titrate(r, targets[j], TEN_MINUTES_MS);
            TEST_ASSERT_TRUE_MESSAGE(res.completed, msg);
            TEST_ASSERT_EQUAL_INT_MESSAGE(0, total_errors(&res), msg);
            TEST_ASSERT_EQUAL_INT_MESSAGE(DEV_IDLE, res.final_state, msg);
            TEST_ASSERT_TRUE_MESSAGE(res.elapsed_ms < TEN_MINUTES_MS, msg);
            /* The app's band is 0.05 around the device's own reading. */
            TEST_ASSERT_DOUBLE_WITHIN_MESSAGE(0.1, targets[j], res.true_ph, msg);
            TEST_ASSERT_TRUE_MESSAGE(res.used_ul[CH_ACID] + res.used_ul[CH_BASE] > 0.0, msg);
        }
    }
}

/* plain water sample, target 7.00: error no_converge then idle */
static void test_unbuffered_gives_up(void)
{
    rig_cfg_t cfg = default_cfg();
    cfg.sample_ph = 6.0;
    cfg.buffered = false;
    rig_t *r = new_rig(&cfg);

    rig_result_t res = rig_titrate(r, 7.0, TEN_MINUTES_MS);
    TEST_ASSERT_FALSE(res.completed);
    TEST_ASSERT_EQUAL_INT(1, res.errors[ERR_NO_CONVERGE]);
    TEST_ASSERT_EQUAL_INT(1, total_errors(&res));
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, res.final_state);
    assert_idle_follows(r, find_error(r, ERR_NO_CONVERGE, 0));
}

/* 30 uL of base, far target: error limit ch 2 out, then idle, axis homed */
static void test_empty_syringe(void)
{
    rig_cfg_t cfg = default_cfg();
    cfg.sample_ph = 5.5;
    cfg.syringe_ul[CH_BASE] = 30.0;
    rig_t *r = new_rig(&cfg);

    rig_result_t res = rig_titrate(r, 9.0, TEN_MINUTES_MS);
    TEST_ASSERT_FALSE(res.completed);
    TEST_ASSERT_EQUAL_INT(1, res.errors[ERR_LIMIT]);
    TEST_ASSERT_EQUAL_INT(1, total_errors(&res));
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, res.final_state);

    size_t i = find_error(r, ERR_LIMIT, 0);
    assert_error_at(r, i, CH_BASE, DIR_OUT);
    assert_idle_follows(r, i);

    /* The whole 30 uL went into the beaker, and the switch homed the axis. */
    TEST_ASSERT_DOUBLE_WITHIN(1e-6, 30.0, res.used_ul[CH_BASE]);
    TEST_ASSERT_DOUBLE_WITHIN(1e-6, 0.0, rig_syringe_ul(r, CH_BASE));
    TEST_ASSERT_TRUE(axis_homed(rig_axis(r, CH_BASE)));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(rig_axis(r, CH_BASE)));
    TEST_ASSERT_FALSE(axis_homed(rig_axis(r, CH_ACID)));
}

/* fault mid-titration: error sensor then idle within ~2.5 s */
static void test_sensor_fault_stops(void)
{
    rig_cfg_t cfg = default_cfg();
    cfg.sample_ph = 8.5;
    rig_t *r = new_rig(&cfg);

    rig_write(r, "{\"cmd\":\"titrate\",\"target\":7.00}");
    rig_run(r, 8000);
    TEST_ASSERT_EQUAL_INT(DEV_TITRATING, rig_state(r));

    /* The fault needs 2 s at the rail, counted from the first bad window
     * (up to 0.5 s away): not before 2 s, certainly by 2.5 s. */
    rig_set_fault(r, true);
    size_t from = rig_event_count(r);
    rig_run(r, 1900);
    TEST_ASSERT_EQUAL_INT(DEV_TITRATING, rig_state(r));
    TEST_ASSERT_TRUE(find_error(r, ERR_SENSOR, from) == NOT_FOUND);

    rig_run(r, 600);
    size_t i = find_error(r, ERR_SENSOR, from);
    TEST_ASSERT_TRUE(i != NOT_FOUND);
    assert_idle_follows(r, i);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, rig_state(r));
    TEST_ASSERT_TRUE(find_error(r, ERR_SENSOR, i + 1) == NOT_FOUND); /* reported once */
    for (uint8_t ch = 0; ch < CH_COUNT; ch++)
        TEST_ASSERT_NOT_EQUAL(AXIS_RUNNING, axis_status(rig_axis(r, ch)));
}

/* in before homing -> unhomed; jog out to the switch -> limit out; jog in -> limit in at the stroke; positions match the rig */
static void test_manual_homing(void)
{
    rig_cfg_t cfg = default_cfg();
    cfg.syringe_ul[CH_ACID] = 100.0;
    cfg.calibrated = false;
    rig_t *r = new_rig(&cfg);
    const char *jog_in = "{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"in\"}";
    const char *jog_out = "{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"out\"}";
    size_t from;

    /* Before the first homing, "in" is refused and nothing moves. */
    from = rig_event_count(r);
    rig_write(r, jog_in);
    assert_error_at(r, find_error(r, ERR_UNHOMED, from), CH_ACID, DIR_IN);
    TEST_ASSERT_EQUAL_UINT(from + 1, rig_event_count(r)); /* no state event: idle stayed idle */
    rig_run(r, 1000);
    TEST_ASSERT_DOUBLE_WITHIN(1e-9, 100.0, rig_syringe_ul(r, CH_ACID));

    /* Out to the switch: limit out, the axis is homed at 0. */
    from = rig_event_count(r);
    jog_until_idle(r, jog_out);
    size_t i = find_error(r, ERR_LIMIT, from);
    assert_error_at(r, i, CH_ACID, DIR_OUT);
    assert_idle_follows(r, i);
    TEST_ASSERT_EQUAL_INT(EVT_STATE, rig_event(r, from)->kind);
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, rig_event(r, from)->state);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_status(rig_axis(r, CH_ACID)));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(rig_axis(r, CH_ACID)));
    TEST_ASSERT_DOUBLE_WITHIN(1e-9, 0.0, rig_syringe_ul(r, CH_ACID));
    assert_position_matches(r, CH_ACID);

    /* At the switch, "out" is answered with limit at once. */
    from = rig_event_count(r);
    rig_write(r, jog_out);
    assert_error_at(r, find_error(r, ERR_LIMIT, from), CH_ACID, DIR_OUT);
    TEST_ASSERT_EQUAL_UINT(from + 1, rig_event_count(r));

    /* One `move` is exactly MOVE_STEPS. */
    rig_write(r, "{\"cmd\":\"move\",\"ch\":1,\"dir\":\"in\"}");
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, rig_state(r));
    rig_run(r, 2000);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, rig_state(r));
    TEST_ASSERT_EQUAL_INT32(MOVE_STEPS, axis_pos(rig_axis(r, CH_ACID)));
    assert_position_matches(r, CH_ACID);

    /* In to the soft limit. */
    from = rig_event_count(r);
    jog_until_idle(r, jog_in);
    i = find_error(r, ERR_LIMIT, from);
    assert_error_at(r, i, CH_ACID, DIR_IN);
    assert_idle_follows(r, i);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(rig_axis(r, CH_ACID)));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, axis_pos(rig_axis(r, CH_ACID)));
    assert_position_matches(r, CH_ACID);

    /* And all the way back to the switch. */
    from = rig_event_count(r);
    jog_until_idle(r, jog_out);
    assert_error_at(r, find_error(r, ERR_LIMIT, from), CH_ACID, DIR_OUT);
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(rig_axis(r, CH_ACID)));
    TEST_ASSERT_DOUBLE_WITHIN(1e-6, 0.0, rig_syringe_ul(r, CH_ACID));

    /* The other channel never moved and is still unhomed. */
    TEST_ASSERT_FALSE(axis_homed(rig_axis(r, CH_BASE)));
    TEST_ASSERT_DOUBLE_WITHIN(1e-9, 8000.0, rig_syringe_ul(r, CH_BASE));
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
