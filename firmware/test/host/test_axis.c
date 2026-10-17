/* core/axis.c: drive axis_next() like the MCPWM ISR does (pulses = periods so far). */
#include <stddef.h>
#include <stdint.h>

#include "unity.h"
#include "core/axis.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

#define MAX_PERIODS 30000
#define PERIOD_START_US (1000000u / V_START_SPS) /* 2500 */
#define PERIOD_MAX_V_US (1000000u / V_MAX_SPS)   /* 825 */
/* The last period of a move may still be a little faster than v_start: the
 * profile only needs to be at the start speed to within one step of speed. */
#define PERIOD_SLOW_ENOUGH_US (PERIOD_START_US * 10u / 11u)

/* Switch level as a function of the pulse count at the start of a period. */
typedef bool (*switch_fn)(int32_t n);

static int32_t g_from; /* sw_from(): switch active from this pulse count on */

static bool sw_never(int32_t n)
{
    (void)n;
    return false;
}
static bool sw_from(int32_t n) { return n >= g_from; }
static bool sw_glitch(int32_t n) { return n == 50; }
static bool sw_alternate(int32_t n) { return n % 2 == 1; }

static uint32_t g_periods[MAX_PERIODS]; /* period at pulse n of the last run */

static axis_cfg_t default_cfg(void)
{
    return (axis_cfg_t){
        .v_start = V_START_SPS,
        .v_max = V_MAX_SPS,
        .accel = ACCEL_SPS2,
        .stroke = STROKE_STEPS,
        .backlash = BACKLASH_STEPS,
        .limit_debounce = LIMIT_DEBOUNCE,
    };
}

static void new_axis(axis_t *a)
{
    axis_cfg_t c = default_cfg();
    axis_init(a, &c);
}

/* Plays the ISR from pulse count n0 on until axis_next() says stop, then
 * closes the motion with the count plus `extra` (pulses that slipped out
 * after the decision). Returns the number of pulses at the stop decision. */
static int32_t play_from(axis_t *a, int32_t n0, switch_fn sw, int32_t extra)
{
    int32_t n = n0;
    uint32_t p;
    while ((p = axis_next(a, n, sw(n))) != 0) {
        TEST_ASSERT_LESS_THAN_INT32(MAX_PERIODS, n);
        g_periods[n] = p;
        n++;
    }
    axis_finish(a, n + extra);
    return n;
}

static int32_t play(axis_t *a, switch_fn sw) { return play_from(a, 0, sw, 0); }

/* A motion of `steps` (or AXIS_CONTINUOUS) that must be accepted; returns the pulses. */
static int32_t move(axis_t *a, dir_t dir, int32_t steps, switch_fn sw)
{
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(a, dir, steps, false));
    return play(a, sw);
}

/* Homes through the refusal of "out" on the active switch: pos 0, homed. */
static void home(axis_t *a)
{
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_start(a, DIR_OUT, 1, true));
    TEST_ASSERT_TRUE(axis_homed(a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(a));
}

static void homed_at(axis_t *a, int32_t pos)
{
    new_axis(a);
    home(a);
    if (pos > 0) {
        move(a, DIR_IN, pos, sw_never);
        TEST_ASSERT_EQUAL_INT32(pos, axis_pos(a));
    }
}

/* in unhomed -> UNHOMED; in at stroke -> LIMIT_IN; out with switch -> LIMIT_OUT and homed at 0 */
static void test_start_refusals(void)
{
    axis_t a;
    new_axis(&a);
    TEST_ASSERT_FALSE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT(AXIS_UNHOMED, axis_start(&a, DIR_IN, 10, false));
    TEST_ASSERT_EQUAL_INT(AXIS_UNHOMED, axis_start(&a, DIR_IN, AXIS_CONTINUOUS, true));
    TEST_ASSERT_FALSE(axis_homed(&a));

    /* The switch refuses "out" and homes, wherever the axis believed it was. */
    homed_at(&a, 500);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_start(&a, DIR_OUT, 10, true));
    TEST_ASSERT_TRUE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
    /* From a fresh axis too. */
    new_axis(&a);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_start(&a, DIR_OUT, 10, true));
    TEST_ASSERT_TRUE(axis_homed(&a));
    /* With the switch active "in" is fine: that is how it leaves the end. */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 10, true));
    axis_finish(&a, 0);

    /* At the soft limit "in" is refused, one step short of it accepted. */
    homed_at(&a, STROKE_STEPS - 1);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 5, false));
    axis_finish(&a, 0);
    homed_at(&a, STROKE_STEPS);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_start(&a, DIR_IN, 5, false));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, axis_pos(&a));
    /* "Out" from there is fine. */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 5, false));
    axis_finish(&a, 0);
}

/* no steps, no motion: nothing starts, nothing changes (not even the homing of a switch) */
static void test_start_without_steps(void)
{
    axis_t a;
    homed_at(&a, 100);
    axis_status_t before = axis_status(&a);
    static const int32_t none[] = {0, -1, INT32_MIN};
    for (size_t i = 0; i < sizeof none / sizeof none[0]; i++) {
        TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_start(&a, DIR_IN, none[i], false));
        TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_start(&a, DIR_OUT, none[i], true));
        TEST_ASSERT_EQUAL_INT(before, axis_status(&a));
        TEST_ASSERT_EQUAL_INT32(100, axis_pos(&a)); /* the active switch did not home it */
        TEST_ASSERT_EQUAL_UINT32(0, axis_next(&a, 0, false));
        TEST_ASSERT_FALSE(axis_extend(&a, DIR_IN, 10));
        axis_finish(&a, 5); /* no open motion: ignored */
        TEST_ASSERT_EQUAL_INT32(100, axis_pos(&a));
    }
    new_axis(&a);
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_start(&a, DIR_IN, 0, false)); /* not UNHOMED: it is no motion */
    TEST_ASSERT_FALSE(axis_homed(&a));
}

/* N counted steps -> exactly N periods with a pulse, then 0 / AXIS_DONE */
static void test_finite_move_exact(void)
{
    static const int32_t counts[] = {1, 2, 3, 61, 121, 122, 1212, STROKE_STEPS};
    for (size_t i = 0; i < sizeof counts / sizeof counts[0]; i++) {
        int32_t steps = counts[i];
        axis_t a;
        homed_at(&a, 0);

        TEST_ASSERT_EQUAL_INT32(steps, move(&a, DIR_IN, steps, sw_never));
        TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a)); /* also when it ends exactly at the stroke */
        TEST_ASSERT_EQUAL_INT32(steps, axis_pos(&a));
        for (int32_t n = 0; n < steps; n++) {
            TEST_ASSERT_GREATER_OR_EQUAL_UINT32(PERIOD_MAX_V_US, g_periods[n]);
            TEST_ASSERT_LESS_OR_EQUAL_UINT32(PERIOD_START_US, g_periods[n]);
        }

        TEST_ASSERT_EQUAL_INT32(steps, move(&a, DIR_OUT, steps, sw_never));
        TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
        TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
    }
}

/* first period 1e6/v_start; never faster than v_max; accelerates, cruises, decelerates to ~v_start */
static void test_profile_trapezoid(void)
{
    axis_t a;
    homed_at(&a, 0);
    int32_t steps = 2000;
    TEST_ASSERT_EQUAL_INT32(steps, move(&a, DIR_IN, steps, sw_never));

    TEST_ASSERT_EQUAL_UINT32(PERIOD_START_US, g_periods[0]);
    int32_t first_fast = -1, last_fast = -1;
    for (int32_t n = 0; n < steps; n++) {
        TEST_ASSERT_GREATER_OR_EQUAL_UINT32(PERIOD_MAX_V_US, g_periods[n]);
        TEST_ASSERT_LESS_OR_EQUAL_UINT32(PERIOD_START_US, g_periods[n]);
        if (g_periods[n] == PERIOD_MAX_V_US) {
            if (first_fast < 0)
                first_fast = n;
            last_fast = n;
        }
    }
    TEST_ASSERT_TRUE_MESSAGE(first_fast > 0, "v_max never reached");

    /* up, flat, down */
    for (int32_t n = 1; n <= first_fast; n++)
        TEST_ASSERT_LESS_OR_EQUAL_UINT32(g_periods[n - 1], g_periods[n]);
    for (int32_t n = first_fast; n <= last_fast; n++)
        TEST_ASSERT_EQUAL_UINT32(PERIOD_MAX_V_US, g_periods[n]);
    for (int32_t n = last_fast + 1; n < steps; n++)
        TEST_ASSERT_GREATER_OR_EQUAL_UINT32(g_periods[n - 1], g_periods[n]);

    /* DESIGN 4.4: 400 -> 1212 steps/s takes 82 steps, and it ends slow. */
    int32_t ramp_up = first_fast, ramp_down = steps - 1 - last_fast;
    TEST_ASSERT_INT32_WITHIN(8, 82, ramp_up);
    TEST_ASSERT_INT32_WITHIN(8, 82, ramp_down);
    TEST_ASSERT_GREATER_OR_EQUAL_UINT32(PERIOD_SLOW_ENOUGH_US, g_periods[steps - 1]);
}

/* short move never reaches v_max and still ends slow */
static void test_profile_triangle(void)
{
    axis_t a;
    homed_at(&a, 0);
    int32_t steps = MOVE_STEPS; /* 121: the default `move` */
    TEST_ASSERT_EQUAL_INT32(steps, move(&a, DIR_IN, steps, sw_never));

    TEST_ASSERT_EQUAL_UINT32(PERIOD_START_US, g_periods[0]);
    int32_t peak = 0;
    for (int32_t n = 1; n < steps; n++)
        if (g_periods[n] < g_periods[peak])
            peak = n;
    TEST_ASSERT_GREATER_THAN_UINT32(PERIOD_MAX_V_US, g_periods[peak]); /* never at v_max */
    TEST_ASSERT_INT32_WITHIN(steps / 5, steps / 2, peak);              /* about half way */
    for (int32_t n = 1; n <= peak; n++)
        TEST_ASSERT_LESS_OR_EQUAL_UINT32(g_periods[n - 1], g_periods[n]);
    for (int32_t n = peak + 1; n < steps; n++)
        TEST_ASSERT_GREATER_OR_EQUAL_UINT32(g_periods[n - 1], g_periods[n]);
    TEST_ASSERT_GREATER_OR_EQUAL_UINT32(PERIOD_SLOW_ENOUGH_US, g_periods[steps - 1]);
}

/* LIMIT_DEBOUNCE consecutive active samples -> 0 / LIMIT_OUT, pos 0, homed */
static void test_limit_out_homes(void)
{
    axis_t a;
    axis_cfg_t c = default_cfg();
    g_from = 100;

    /* Moving out, away from a known position. */
    homed_at(&a, 5000);
    int32_t n = move(&a, DIR_OUT, 1000, sw_from);
    TEST_ASSERT_EQUAL_INT32(g_from + (int32_t)c.limit_debounce - 1, n); /* the pulse of the last active sample is suppressed */
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_status(&a));
    TEST_ASSERT_TRUE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));

    /* From an axis that never homed: the switch is what homes it. */
    new_axis(&a);
    TEST_ASSERT_FALSE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 1000, false));
    n = play(&a, sw_from);
    TEST_ASSERT_EQUAL_INT32(g_from + (int32_t)c.limit_debounce - 1, n);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_status(&a));
    TEST_ASSERT_TRUE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));

    /* The result holds when the hardware count ran a step past the decision. */
    homed_at(&a, 5000);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 1000, false));
    play_from(&a, 0, sw_from, 1);
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
}

/* one active sample between inactive ones does not stop */
static void test_limit_glitch_ignored(void)
{
    axis_t a;
    homed_at(&a, 500);
    TEST_ASSERT_EQUAL_INT32(100, move(&a, DIR_OUT, 100, sw_glitch));
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(400, axis_pos(&a));

    /* never two in a row */
    TEST_ASSERT_EQUAL_INT32(100, move(&a, DIR_OUT, 100, sw_alternate));
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(300, axis_pos(&a));
}

/* the switch means nothing on the way in */
static void test_limit_ignored_moving_in(void)
{
    axis_t a;
    homed_at(&a, 0);
    g_from = 0;
    TEST_ASSERT_EQUAL_INT32(300, move(&a, DIR_IN, 300, sw_from));
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(300, axis_pos(&a));
}

/* homed at stroke - 10, continuous in -> LIMIT_IN after 10 steps, pos = stroke */
static void test_soft_limit_in(void)
{
    axis_t a;
    homed_at(&a, STROKE_STEPS - 10);
    TEST_ASSERT_EQUAL_INT32(10, move(&a, DIR_IN, AXIS_CONTINUOUS, sw_never));
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, axis_pos(&a));

    /* Over the whole stroke the planner brakes for the limit. */
    homed_at(&a, 0);
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, move(&a, DIR_IN, AXIS_CONTINUOUS, sw_never));
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, axis_pos(&a));
    TEST_ASSERT_EQUAL_UINT32(PERIOD_MAX_V_US, g_periods[STROKE_STEPS / 2]);
    TEST_ASSERT_GREATER_OR_EQUAL_UINT32(PERIOD_SLOW_ENOUGH_US, g_periods[STROKE_STEPS - 1]);

    /* A finite request that reaches the limit first stops there, too. */
    homed_at(&a, STROKE_STEPS - 20);
    TEST_ASSERT_EQUAL_INT32(20, move(&a, DIR_IN, 50, sw_never));
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, axis_pos(&a));
}

/* continuous out runs until the switch */
static void test_jog_out_until_switch(void)
{
    axis_t a;
    axis_cfg_t c = default_cfg();
    homed_at(&a, 3000);
    g_from = 3000; /* the switch is 3000 steps away */
    int32_t n = move(&a, DIR_OUT, AXIS_CONTINUOUS, sw_from);
    TEST_ASSERT_EQUAL_INT32(3000 + (int32_t)c.limit_debounce - 1, n);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
    /* Cruising at full speed into the switch: stopping there needs no ramp. */
    TEST_ASSERT_EQUAL_UINT32(PERIOD_MAX_V_US, g_periods[n - 1]);

    /* Without a switch it just keeps going (the caller's jog timeout ends it). */
    homed_at(&a, 3000);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, AXIS_CONTINUOUS, false));
    for (int32_t k = 0; k < 10000; k++)
        TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, k, false));
    axis_finish(&a, 10000);
    TEST_ASSERT_EQUAL_INT(AXIS_HALTED, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a)); /* clamped: the plunger cannot be past the end */
}

/* same dir adds steps; continuous; other dir or not running -> false */
static void test_extend(void)
{
    axis_t a;
    homed_at(&a, 0);

    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 100, false));
    for (int32_t n = 0; n < 20; n++)
        TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, n, false));
    TEST_ASSERT_FALSE(axis_extend(&a, DIR_OUT, 10));
    TEST_ASSERT_TRUE(axis_extend(&a, DIR_IN, 50));
    TEST_ASSERT_EQUAL_INT32(150, play_from(&a, 20, sw_never, 0));
    TEST_ASSERT_EQUAL_INT32(150, axis_pos(&a));
    TEST_ASSERT_FALSE(axis_extend(&a, DIR_IN, 10)); /* finished */

    /* a move that becomes a jog: runs on to the soft limit */
    homed_at(&a, 0);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 100, false));
    TEST_ASSERT_TRUE(axis_extend(&a, DIR_IN, AXIS_CONTINUOUS));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, play(&a, sw_never));
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(&a));

    /* a sum that does not fit becomes continuous instead of wrapping */
    homed_at(&a, 0);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 100, false));
    TEST_ASSERT_TRUE(axis_extend(&a, DIR_IN, INT32_MAX - 10));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, play(&a, sw_never));

    /* a jog stays a jog */
    homed_at(&a, 0);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, AXIS_CONTINUOUS, false));
    TEST_ASSERT_TRUE(axis_extend(&a, DIR_IN, 50));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS, play(&a, sw_never));

    /* too late: the stop was decided, only the bookkeeping is left */
    homed_at(&a, 0);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 3, false));
    for (int32_t n = 0; n < 3; n++)
        TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, n, false));
    TEST_ASSERT_EQUAL_UINT32(0, axis_next(&a, 3, false));
    TEST_ASSERT_FALSE(axis_extend(&a, DIR_IN, 10));
    axis_finish(&a, 3);
    TEST_ASSERT_EQUAL_INT32(3, axis_pos(&a));
}

/* axis_finish on a running axis -> HALTED, pos from pulses */
static void test_halt_by_finish(void)
{
    axis_t a;
    homed_at(&a, 100);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 1000, false));
    for (int32_t n = 0; n < 50; n++)
        TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, n, false));
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_status(&a));

    axis_finish(&a, 50);
    TEST_ASSERT_EQUAL_INT(AXIS_HALTED, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(150, axis_pos(&a));
    TEST_ASSERT_TRUE(axis_homed(&a));

    /* idempotent, and a late ISR call gets nothing more */
    axis_finish(&a, 99);
    TEST_ASSERT_EQUAL_INT(AXIS_HALTED, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(150, axis_pos(&a));
    TEST_ASSERT_EQUAL_UINT32(0, axis_next(&a, 51, false));
    TEST_ASSERT_FALSE(axis_extend(&a, DIR_IN, 10));

    /* and the other way */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, AXIS_CONTINUOUS, false));
    for (int32_t n = 0; n < 30; n++)
        axis_next(&a, n, false);
    axis_finish(&a, 30);
    TEST_ASSERT_EQUAL_INT32(120, axis_pos(&a));
}

/* an extra pulse after the stop decision is reflected in pos */
static void test_finish_uses_final_count(void)
{
    axis_t a;
    homed_at(&a, 200);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 100, false));
    TEST_ASSERT_EQUAL_INT32(100, play_from(&a, 0, sw_never, 1));
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(301, axis_pos(&a));

    /* the decision itself may come a period late: it still stops, and counts what came out */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 10, false));
    for (int32_t n = 0; n < 10; n++)
        TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, n, false));
    TEST_ASSERT_EQUAL_UINT32(0, axis_next(&a, 11, false));
    axis_finish(&a, 11);
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(290, axis_pos(&a));

    /* the soft limit, too */
    homed_at(&a, STROKE_STEPS - 5);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, AXIS_CONTINUOUS, false));
    TEST_ASSERT_EQUAL_INT32(5, play_from(&a, 0, sw_never, 1));
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_IN, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(STROKE_STEPS + 1, axis_pos(&a));

    /* the pulse that reached the switch is not a position: 0 stays 0 */
    g_from = 20;
    homed_at(&a, 300);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, AXIS_CONTINUOUS, false));
    play_from(&a, 0, sw_from, 3);
    TEST_ASSERT_EQUAL_INT(AXIS_LIMIT_OUT, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
}

/* reversal adds cfg.backlash uncounted pulses; same direction does not; none on the first motion */
static void test_backlash(void)
{
    axis_t a;
    axis_cfg_t c = default_cfg();
    c.backlash = 4;
    axis_init(&a, &c);
    home(&a); /* the refusal is no motion: nothing to reverse from yet */

    TEST_ASSERT_EQUAL_INT32(100, move(&a, DIR_IN, 100, sw_never)); /* first motion */
    TEST_ASSERT_EQUAL_INT32(100, axis_pos(&a));

    TEST_ASSERT_EQUAL_INT32(34, move(&a, DIR_OUT, 30, sw_never)); /* reversal */
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_EQUAL_INT32(70, axis_pos(&a));

    TEST_ASSERT_EQUAL_INT32(30, move(&a, DIR_OUT, 30, sw_never)); /* same direction */
    TEST_ASSERT_EQUAL_INT32(40, axis_pos(&a));

    TEST_ASSERT_EQUAL_INT32(14, move(&a, DIR_IN, 10, sw_never)); /* reversal again */
    TEST_ASSERT_EQUAL_INT32(50, axis_pos(&a));

    /* Halted inside the slack: nothing counted yet. */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 100, false));
    axis_finish(&a, 3);
    TEST_ASSERT_EQUAL_INT32(50, axis_pos(&a));
    /* ...and when the motor did turn, the slack is gone: no second backlash the same way. */
    TEST_ASSERT_EQUAL_INT32(20, move(&a, DIR_OUT, 20, sw_never));
    TEST_ASSERT_EQUAL_INT32(30, axis_pos(&a));

    /* A motion halted before its first pulse leaves the direction memory alone. */
    axis_init(&a, &c);
    home(&a);
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_IN, 10, false));
    axis_finish(&a, 0);
    TEST_ASSERT_EQUAL_INT32(10, move(&a, DIR_OUT, 10, sw_never)); /* still the first real motion */

    /* The backlash pulses count for the switch, and the position stays right. */
    axis_init(&a, &c);
    home(&a);
    move(&a, DIR_IN, 100, sw_never);
    g_from = 60;
    int32_t n = move(&a, DIR_OUT, AXIS_CONTINUOUS, sw_from);
    TEST_ASSERT_EQUAL_INT32(g_from + (int32_t)c.limit_debounce - 1, n);
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
}

/* without a switch the position cannot go below the end */
static void test_position_clamped(void)
{
    axis_t a;
    new_axis(&a); /* unhomed: nothing says where the end is */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, 100, false));
    TEST_ASSERT_EQUAL_INT32(100, play(&a, sw_never));
    TEST_ASSERT_EQUAL_INT(AXIS_DONE, axis_status(&a));
    TEST_ASSERT_FALSE(axis_homed(&a));
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));

    homed_at(&a, 5);
    TEST_ASSERT_EQUAL_INT32(100, move(&a, DIR_OUT, 100, sw_never)); /* broken switch */
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
}

/* v_start..v_max and accel from config.h: no 32-bit overflow (UBSan clean) */
static void test_no_overflow_at_limits(void)
{
    /* config.h: the product that axis_next() forms must fit 32 bits. */
    axis_t a;
    axis_cfg_t c = default_cfg();
    homed_at(&a, 0);
    move(&a, DIR_IN, AXIS_CONTINUOUS, sw_never);
    for (int32_t n = 0; n < STROKE_STEPS; n++) {
        TEST_ASSERT_TRUE((uint64_t)c.accel * g_periods[n] <= UINT32_MAX);
        TEST_ASSERT_TRUE(g_periods[n] >= 1000000u / c.v_max && g_periods[n] <= 1000000u / c.v_start);
    }

    /* The widest range the arithmetic accepts, with the largest acceleration. */
    c = (axis_cfg_t){.v_start = 16, .v_max = 65535, .accel = UINT32_MAX, .stroke = INT32_MAX, .backlash = 65535, .limit_debounce = 2};
    axis_init(&a, &c);
    home(&a);
    TEST_ASSERT_EQUAL_INT32(MAX_PERIODS - 1, move(&a, DIR_IN, MAX_PERIODS - 1, sw_never));
    for (int32_t n = 0; n < MAX_PERIODS - 1; n++) {
        TEST_ASSERT_GREATER_OR_EQUAL_UINT32(15, g_periods[n]); /* 1e6 / 65535 */
        TEST_ASSERT_LESS_OR_EQUAL_UINT32(62500, g_periods[n]); /* 1e6 / 16 */
    }
    TEST_ASSERT_EQUAL_INT32(MAX_PERIODS - 1, axis_pos(&a));

    /* Counts near the top of int32 do not wrap either. */
    TEST_ASSERT_EQUAL_INT(AXIS_RUNNING, axis_start(&a, DIR_OUT, AXIS_CONTINUOUS, false));
    TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, 0, false));
    TEST_ASSERT_NOT_EQUAL_UINT32(0, axis_next(&a, INT32_MAX - 1, false));
    axis_finish(&a, INT32_MAX);
    TEST_ASSERT_EQUAL_INT32(0, axis_pos(&a));
}

/* a cfg that would divide by zero or overflow is brought into range */
static void test_cfg_clamped(void)
{
    axis_t a;
    axis_cfg_t c = {.v_start = 0, .v_max = 0, .accel = 0, .stroke = 1000, .backlash = 0, .limit_debounce = 2};
    axis_init(&a, &c);
    home(&a);
    TEST_ASSERT_EQUAL_INT32(50, move(&a, DIR_IN, 50, sw_never));
    TEST_ASSERT_EQUAL_UINT32(1000000u, g_periods[0]); /* v_start 0 became 1 step/s */
    TEST_ASSERT_EQUAL_INT32(50, axis_pos(&a));

    c = (axis_cfg_t){.v_start = 500, .v_max = 100, .accel = 8000, .stroke = 1000, .backlash = 0, .limit_debounce = 2};
    axis_init(&a, &c);
    home(&a);
    TEST_ASSERT_EQUAL_INT32(50, move(&a, DIR_IN, 50, sw_never));
    for (int32_t n = 0; n < 50; n++)
        TEST_ASSERT_EQUAL_UINT32(2000, g_periods[n]); /* v_max raised to v_start: no ramp at all */
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_start_refusals);
    RUN_TEST(test_start_without_steps);
    RUN_TEST(test_finite_move_exact);
    RUN_TEST(test_profile_trapezoid);
    RUN_TEST(test_profile_triangle);
    RUN_TEST(test_limit_out_homes);
    RUN_TEST(test_limit_glitch_ignored);
    RUN_TEST(test_limit_ignored_moving_in);
    RUN_TEST(test_soft_limit_in);
    RUN_TEST(test_jog_out_until_switch);
    RUN_TEST(test_extend);
    RUN_TEST(test_halt_by_finish);
    RUN_TEST(test_finish_uses_final_count);
    RUN_TEST(test_backlash);
    RUN_TEST(test_position_clamped);
    RUN_TEST(test_no_overflow_at_limits);
    RUN_TEST(test_cfg_clamped);
    return UNITY_END();
}
