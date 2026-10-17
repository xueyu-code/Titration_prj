/* core/titration.c: protocol 4 loop, same decisions as sim_titrator.dart. */
#include "unity.h"
#include "core/titration.h"
#include "core/config.h"
#include "core/types.h"

#define SAMPLE_MS SAMPLE_PERIOD_MS /* one reading */

/* Virtual clock; every reading advances it by one sample period. */
static uint32_t s_now;

void setUp(void)
{
    s_now = 0;
}

void tearDown(void) {}

/* Feeds `ph` once per sample period until the loop acts or until_ms has passed;
 * s_now is then the time of the action. */
static titr_action_t feed(titr_t *t, float ph, uint32_t until_ms)
{
    titr_action_t a = {.verdict = TITR_WAIT};

    while (a.verdict == TITR_WAIT && s_now < until_ms) {
        s_now += SAMPLE_MS;
        a = titr_on_ph(t, ph, s_now);
    }
    return a;
}

/* The same with two readings alternating (never settled): a at even
 * multiples of the sample period, b at odd ones. */
static titr_action_t feed_alternating(titr_t *t, float a, float b, uint32_t until_ms)
{
    titr_action_t act = {.verdict = TITR_WAIT};

    while (act.verdict == TITR_WAIT && s_now < until_ms) {
        s_now += SAMPLE_MS;
        act = titr_on_ph(t, (s_now / SAMPLE_MS) % 2 ? b : a, s_now);
    }
    return act;
}

/* The loop decides on a steady reading, the dose is delivered at once: the
 * next dose (or verdict) that steady `ph` leads to. */
static titr_action_t dose_at(titr_t *t, float ph)
{
    titr_action_t a = feed(t, ph, s_now + 2 * SETTLE_MAX_MS);

    if (a.verdict == TITR_DOSE)
        titr_dose_done(t, s_now);
    return a;
}

/* Time from the start of a wait to the decision on steady readings: the
 * skipped ones, then SETTLE_N readings. */
#define DECISION_MS (SETTLE_SKIP_MS + (SETTLE_N - 1) * SAMPLE_MS)

/* nothing before SETTLE_SKIP_MS; decides after SETTLE_N settled readings */
static void test_waits_skip_then_window(void)
{
    titr_t t;
    titr_start(&t, 7.0f, 0);

    /* Readings during the skip time are thrown away, whatever they are:
     * 3.0 would mean base, the settled 8.0 afterwards means acid. */
    for (uint32_t ms = SAMPLE_MS; ms < SETTLE_SKIP_MS; ms += SAMPLE_MS)
        TEST_ASSERT_EQUAL_INT(TITR_WAIT, titr_on_ph(&t, 3.0f, ms).verdict);

    /* The first kept reading is at SETTLE_SKIP_MS; the window fills at DECISION_MS. */
    s_now = SETTLE_SKIP_MS - SAMPLE_MS;
    titr_action_t a = feed(&t, 8.0f, DECISION_MS - SAMPLE_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(DECISION_MS - SAMPLE_MS, s_now);

    a = feed(&t, 8.0f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(DECISION_MS, s_now);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
}

/* the window slides: older, unsettled readings drop out of it */
static void test_window_slides(void)
{
    titr_t t;
    titr_start(&t, 7.0f, 0);

    /* After the skip time: SETTLE_N swinging readings (the last one 8.2), then steady ones. */
    s_now = SETTLE_SKIP_MS - SAMPLE_MS;
    titr_action_t a = feed_alternating(&t, 8.0f, 8.2f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);

    /* It takes SETTLE_N steady readings to push the swing out, ... */
    for (unsigned i = 0; i + 1 < SETTLE_N; i++)
        TEST_ASSERT_EQUAL_INT(TITR_WAIT, titr_on_ph(&t, 8.0f, s_now += SAMPLE_MS).verdict);
    /* ... and then the loop decides on the steady value (the wide span is gone). */
    a = titr_on_ph(&t, 8.0f, s_now += SAMPLE_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
}

/* |err| <= HOLD_TOL_PH: no dose, the wait restarts */
static void test_holds_within_tol(void)
{
    titr_t t;
    titr_start(&t, 7.0f, 0);

    /* 0.015 off: hold. The decision is made, so a new wait starts at that time. */
    titr_action_t a = feed(&t, 7.015f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(DECISION_MS, s_now);

    /* The wait is a full one: nothing before another DECISION_MS, ... */
    a = feed(&t, 8.0f, 2 * DECISION_MS - SAMPLE_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    /* ... then the decision, now on the new reading, which is outside the band. */
    a = feed(&t, 8.0f, 2 * DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(2 * DECISION_MS, s_now);

    /* The other side, and just outside the band: 0.03 > HOLD_TOL_PH. */
    titr_start(&t, 7.0f, 0);
    s_now = 0;
    a = feed(&t, 6.97f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
}

/* FIRST_DOSE_UL; acid above target, base below */
static void test_first_dose(void)
{
    titr_t t;

    titr_start(&t, 7.0f, 0);
    titr_action_t a = feed(&t, 8.0f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(FIRST_DOSE_UL, a.ul);

    s_now = 0;
    titr_start(&t, 7.0f, 0);
    a = feed(&t, 6.0f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(FIRST_DOSE_UL, a.ul);
}

/* unsettled readings: decision at SETTLE_MAX_MS on the window average */
static void test_settle_max_uses_average(void)
{
    titr_t t;
    titr_start(&t, 7.0f, 0);

    /* 8.0 / 8.2 never settle; they are 8.1 on average. */
    titr_action_t a = feed_alternating(&t, 8.0f, 8.2f, SETTLE_MAX_MS - SAMPLE_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    a = feed_alternating(&t, 8.0f, 8.2f, SETTLE_MAX_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(SETTLE_MAX_MS, s_now);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    titr_dose_done(&t, s_now);

    /* The average is the reading the dose was decided on: the response to
     * it is 8.1 - 7.6 = 0.5, so 0.5 * 0.6 * 50 / 0.5 = 30 uL. */
    a = feed(&t, 7.6f, s_now + 2 * SETTLE_MAX_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 30.0f, a.ul);
}

/* DOSE_GAIN * |err| * last / gain, clamped */
static void test_dose_from_response(void)
{
    titr_t t;

    /* 8.0 -> 7.6 after 50 uL of acid: gain 0.4, err 0.6, 0.5 * 0.6 * 50 / 0.4. */
    titr_start(&t, 7.0f, s_now);
    titr_action_t a = dose_at(&t, 8.0f);
    TEST_ASSERT_EQUAL_FLOAT(FIRST_DOSE_UL, a.ul);
    a = dose_at(&t, 7.6f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 37.5f, a.ul);

    /* The same for base (the response is a rise): 6.0 -> 6.5, err 0.5. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 6.0f);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    a = dose_at(&t, 6.5f);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.5f * 0.5f * 50.0f / 0.5f, a.ul);

    /* The volume is the one the dose was decided with (after the clamp). */
    a = dose_at(&t, 6.75f); /* gain 0.25, err 0.25: 0.5 * 0.25 * 25 / 0.25 */
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 12.5f, a.ul);

    /* Clamped to MIN_DOSE_UL: a tiny error. 7.5 -> 7.04. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 7.5f);
    a = dose_at(&t, 7.04f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_FLOAT(MIN_DOSE_UL, a.ul);

    /* Clamped to MAX_DOSE_UL: a big error and a response just usable. 9.0 -> 8.96. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 9.0f);
    a = dose_at(&t, 8.96f); /* gain 0.04: 0.5 * 1.96 * 50 / 0.04 = 1225 */
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_FLOAT(MAX_DOSE_UL, a.ul);
}

/* gain < SETTLE_SPAN_PH -> 2 * last, clamped to MAX_DOSE_UL */
static void test_weak_response_doubles(void)
{
    titr_t t;
    titr_start(&t, 7.0f, s_now);

    /* Acid, and the pH hardly drops (0.01 < SETTLE_SPAN_PH): twice as much. */
    titr_action_t a = dose_at(&t, 8.0f);
    TEST_ASSERT_EQUAL_FLOAT(50.0f, a.ul);
    a = dose_at(&t, 7.99f);
    TEST_ASSERT_EQUAL_FLOAT(100.0f, a.ul);
    a = dose_at(&t, 7.98f);
    TEST_ASSERT_EQUAL_FLOAT(200.0f, a.ul);
    a = dose_at(&t, 7.97f);
    TEST_ASSERT_EQUAL_FLOAT(400.0f, a.ul);
    a = dose_at(&t, 7.96f);
    TEST_ASSERT_EQUAL_FLOAT(MAX_DOSE_UL, a.ul); /* 800, clamped */
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);

    /* A response the wrong way (acid, pH up) is no response either. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 8.0f);
    a = dose_at(&t, 8.3f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(100.0f, a.ul);
}

/* direction change halves the dose */
static void test_reversal_halves(void)
{
    titr_t t;
    titr_start(&t, 7.0f, s_now);

    titr_action_t a = dose_at(&t, 6.0f);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);

    /* Overshoot to 7.8: acid now. gain 1.8, err 0.8: 0.5 * 0.8 * 50 / 1.8, halved. */
    a = dose_at(&t, 7.8f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.5f * 0.8f * 50.0f / 1.8f / 2.0f, a.ul);

    /* Without a reversal the same numbers give twice that. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 8.0f);
    a = dose_at(&t, 7.2f); /* acid again: gain 0.8, err 0.2 */
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.5f * 0.2f * 50.0f / 0.8f, a.ul);
}

/* MAX_REVERSALS-th reversal -> TITR_NO_CONVERGE */
static void test_third_reversal_gives_up(void)
{
    titr_t t;
    titr_start(&t, 7.0f, s_now);

    /* Weak responses first, to get a big dose: 50, 100, 200, 400, 500 uL of base. */
    const float weak[] = {6.01f, 6.02f, 6.03f, 6.04f};
    titr_action_t a = dose_at(&t, 6.00f);
    for (size_t i = 0; i < sizeof weak / sizeof weak[0]; i++)
        a = dose_at(&t, weak[i]);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(MAX_DOSE_UL, a.ul);

    /* Reversal 1: 500 uL took the pH to 8.0. Acid, 0.5 * 1 * 500 / 1.96 / 2. */
    a = dose_at(&t, 8.0f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.5f * 1.0f * 500.0f / 1.96f / 2.0f, a.ul);
    float acid_ul = a.ul;

    /* Reversal 2: base again, still no reason to give up (the last dose is far above MIN_DOSE_UL). */
    a = dose_at(&t, 6.0f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 0.5f * 1.0f * acid_ul / 2.0f / 2.0f, a.ul);
    TEST_ASSERT_TRUE(a.ul > MIN_DOSE_UL);

    /* Reversal 3 (MAX_REVERSALS): give up. */
    a = dose_at(&t, 8.0f);
    TEST_ASSERT_EQUAL_INT(TITR_NO_CONVERGE, a.verdict);
}

/* reversal right after a MIN_DOSE_UL dose -> TITR_NO_CONVERGE */
static void test_reversal_after_min_dose_gives_up(void)
{
    titr_t t;
    titr_start(&t, 7.0f, s_now);

    titr_action_t a = dose_at(&t, 6.0f);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    a = dose_at(&t, 6.96f); /* close: 0.5 * 0.04 * 50 / 0.96 = 1 uL, clamped up */
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(MIN_DOSE_UL, a.ul);

    /* The pH went over the target although the dose was the smallest: the first reversal already ends it. */
    a = dose_at(&t, 7.5f);
    TEST_ASSERT_EQUAL_INT(TITR_NO_CONVERGE, a.verdict);

    /* A dose just above MIN_DOSE_UL is not enough reason to give up. */
    titr_start(&t, 7.0f, s_now);
    a = dose_at(&t, 6.0f);
    a = dose_at(&t, 6.7f); /* 0.5 * 0.3 * 50 / 0.7 = 10.7 uL */
    TEST_ASSERT_TRUE(a.ul > MIN_DOSE_UL);
    a = dose_at(&t, 7.2f);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
}

/* TITR_WAIT until titr_dose_done; the wait starts there */
static void test_ignores_readings_while_dosing(void)
{
    titr_t t;
    titr_start(&t, 7.0f, 0);

    titr_action_t a = feed(&t, 8.0f, DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);

    /* A minute of readings while the dose is delivered: nothing happens. */
    uint32_t dose_end = s_now + 60000;
    a = feed(&t, 5.0f, dose_end);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(dose_end, s_now);

    /* Delivered: a full wait from now (skip time, then SETTLE_N readings). */
    titr_dose_done(&t, s_now);
    a = feed(&t, 8.0f, dose_end + DECISION_MS - SAMPLE_MS);
    TEST_ASSERT_EQUAL_INT(TITR_WAIT, a.verdict);
    /* The 5.0 readings of the dose are not in the window: it is 8.0 (acid) all through. No response
     * (8.0 after 8.0) doubles the dose. */
    a = feed(&t, 8.0f, dose_end + DECISION_MS);
    TEST_ASSERT_EQUAL_INT(TITR_DOSE, a.verdict);
    TEST_ASSERT_EQUAL_UINT32(dose_end + DECISION_MS, s_now);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, a.ch);
    TEST_ASSERT_EQUAL_FLOAT(2.0f * FIRST_DOSE_UL, a.ul);
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_waits_skip_then_window);
    RUN_TEST(test_window_slides);
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
