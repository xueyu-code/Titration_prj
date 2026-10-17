/* core/protocol.c: parse every command and encode every event exactly as docs/protocol.md shows.
 * TODO(WP1): implement every case below; none may stay ignored. */
#include "unity.h"
#include "core/protocol.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* {"cmd":"titrate","target":7.00} -> CMD_TITRATE, target 7 */
static void test_parse_titrate(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* {"cmd":"stop"} */
static void test_parse_stop(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* ch 1/2 -> index 0/1, dir "in"/"out" */
static void test_parse_move_and_jog(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* {"cmd":"cal_set","slope":-57.92,"offset":4.35} */
static void test_parse_cal_set(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* extra keys are fine */
static void test_parse_ignores_unknown_fields(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* not JSON, not an object, no cmd, cmd not a string, empty input */
static void test_parse_rejects_malformed(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* reason "unknown cmd" */
static void test_parse_rejects_unknown_cmd(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* ch 0, 3, 1.5, "1", missing; dir "up", 1, missing */
static void test_parse_rejects_bad_channel_and_dir(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* 0 and 14 accepted; -0.01, 14.01, missing, string rejected */
static void test_parse_target_range(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* slope -70/-40 and offset -100/100 accepted; just outside rejected */
static void test_parse_cal_ranges(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* len PROTO_MAX_MSG + 1 rejected without reading past data */
static void test_parse_rejects_too_long(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* data is not NUL-terminated (len bytes only) */
static void test_parse_needs_no_nul(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* exact text {"evt":"ph","v":6.98,"mv":1.2}; rounding; negative values */
static void test_encode_ph(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* idle / titrating / moving */
static void test_encode_state(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* {"evt":"cal","slope":-59.16,"offset":0.00} or equivalent numbers */
static void test_encode_cal(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* with and without ch/dir and msg; ch index 0 -> "ch":1 */
static void test_encode_error(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* NaN / Inf -> 0 */
static void test_encode_rejects_non_finite(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

/* too small buffer -> 0, worst case of every event <= PROTO_MAX_MSG */
static void test_encode_respects_cap(void)
{
    TEST_IGNORE_MESSAGE("TODO(WP1)");
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_parse_titrate);
    RUN_TEST(test_parse_stop);
    RUN_TEST(test_parse_move_and_jog);
    RUN_TEST(test_parse_cal_set);
    RUN_TEST(test_parse_ignores_unknown_fields);
    RUN_TEST(test_parse_rejects_malformed);
    RUN_TEST(test_parse_rejects_unknown_cmd);
    RUN_TEST(test_parse_rejects_bad_channel_and_dir);
    RUN_TEST(test_parse_target_range);
    RUN_TEST(test_parse_cal_ranges);
    RUN_TEST(test_parse_rejects_too_long);
    RUN_TEST(test_parse_needs_no_nul);
    RUN_TEST(test_encode_ph);
    RUN_TEST(test_encode_state);
    RUN_TEST(test_encode_cal);
    RUN_TEST(test_encode_error);
    RUN_TEST(test_encode_rejects_non_finite);
    RUN_TEST(test_encode_respects_cap);
    return UNITY_END();
}
