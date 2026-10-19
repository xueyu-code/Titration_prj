/* core/protocol.c: parse every command and encode every event exactly as docs/protocol.md shows. */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "unity.h"
#include "core/protocol.h"
#include "core/config.h"

void setUp(void) {}
void tearDown(void) {}

/* Parses a copy of s that has exactly strlen(s) bytes and no NUL, so
 * AddressSanitizer reports any read past the length given to the parser. */
static const char *parse(const char *s, cmd_t *out)
{
    size_t len = strlen(s);
    char *copy = malloc(len ? len : 1);
    const char *reason;

    memcpy(copy, s, len);
    reason = proto_parse_cmd(copy, len, out);
    free(copy);
    return reason;
}

static void assert_parses(const char *s, cmd_t *out)
{
    const char *reason = parse(s, out);

    TEST_ASSERT_NULL_MESSAGE(reason, s);
}

static void assert_rejected(const char *s, const char *expected_reason)
{
    cmd_t cmd;

    TEST_ASSERT_EQUAL_STRING_MESSAGE(expected_reason, parse(s, &cmd), s);
}

static evt_t error_evt(err_code_t code, int8_t ch, dir_t dir, const char *msg)
{
    evt_t e = {.kind = EVT_ERROR};

    e.error.code = code;
    e.error.ch = ch;
    e.error.dir = dir;
    e.error.msg = msg;
    return e;
}

/* Encodes evt and checks the exact text and the returned length. */
static void assert_encodes(const evt_t *evt, const char *expected)
{
    char buf[PROTO_MAX_MSG + 1];
    size_t n = proto_encode_evt(evt, buf, sizeof buf);

    TEST_ASSERT_EQUAL_STRING(expected, buf);
    TEST_ASSERT_EQUAL_UINT(strlen(expected), n);
}

/* {"cmd":"titrate","target":7.00} -> CMD_TITRATE, target 7 */
static void test_parse_titrate(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"titrate\",\"target\":7.00}", &cmd);
    TEST_ASSERT_EQUAL(CMD_TITRATE, cmd.kind);
    TEST_ASSERT_EQUAL_FLOAT(7.0f, cmd.target);

    assert_parses("{\"cmd\":\"titrate\",\"target\":6.86}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(6.86f, cmd.target);
    assert_parses("{\"cmd\":\"titrate\",\"target\":4}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(4.0f, cmd.target);
}

/* {"cmd":"stop"} */
static void test_parse_stop(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"stop\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_STOP, cmd.kind);
}

/* {"cmd":"sync"} */
static void test_parse_sync(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"sync\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_SYNC, cmd.kind);
}

/* ch 1/2 -> index 0/1, dir "in"/"out" */
static void test_parse_move_and_jog(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"move\",\"ch\":1,\"dir\":\"in\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_MOVE, cmd.kind);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, cmd.motion.ch);
    TEST_ASSERT_EQUAL(DIR_IN, cmd.motion.dir);

    assert_parses("{\"cmd\":\"move\",\"ch\":2,\"dir\":\"out\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_MOVE, cmd.kind);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, cmd.motion.ch);
    TEST_ASSERT_EQUAL(DIR_OUT, cmd.motion.dir);

    assert_parses("{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"in\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_JOG, cmd.kind);
    TEST_ASSERT_EQUAL_UINT8(CH_ACID, cmd.motion.ch);
    TEST_ASSERT_EQUAL(DIR_IN, cmd.motion.dir);

    assert_parses("{\"dir\":\"out\",\"ch\":2,\"cmd\":\"jog\"}", &cmd); /* key order is free */
    TEST_ASSERT_EQUAL(CMD_JOG, cmd.kind);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, cmd.motion.ch);
    TEST_ASSERT_EQUAL(DIR_OUT, cmd.motion.dir);
}

/* {"cmd":"cal_set","slope":-57.92,"offset":4.35} */
static void test_parse_cal_set(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"cal_set\",\"slope\":-57.92,\"offset\":4.35}", &cmd);
    TEST_ASSERT_EQUAL(CMD_CAL_SET, cmd.kind);
    TEST_ASSERT_EQUAL_FLOAT(-57.92f, cmd.cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(4.35f, cmd.cal.offset);

    assert_parses("{\"cmd\":\"cal_set\",\"slope\":-59.16,\"offset\":-12}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(-59.16f, cmd.cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(-12.0f, cmd.cal.offset);
}

/* extra keys are fine */
static void test_parse_ignores_unknown_fields(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"stop\",\"seq\":7,\"note\":\"x\"}", &cmd);
    TEST_ASSERT_EQUAL(CMD_STOP, cmd.kind);

    assert_parses("{\"ts\":1,\"cmd\":\"jog\",\"ch\":2,\"dir\":\"in\",\"extra\":{\"a\":[1,2]}}", &cmd);
    TEST_ASSERT_EQUAL(CMD_JOG, cmd.kind);
    TEST_ASSERT_EQUAL_UINT8(CH_BASE, cmd.motion.ch);

    assert_parses(" \n{\"cmd\":\"stop\"} \r\n", &cmd); /* blanks around the object */
    TEST_ASSERT_EQUAL(CMD_STOP, cmd.kind);
}

/* not JSON, not an object, no cmd, cmd not a string, empty input */
static void test_parse_rejects_malformed(void)
{
    assert_rejected("", "json");
    assert_rejected("   ", "json");
    assert_rejected("stop", "json");
    assert_rejected("{\"cmd\":\"stop\"", "json");          /* truncated */
    assert_rejected("{\"cmd\":\"stop\"}}", "json");        /* trailing characters */
    assert_rejected("{\"cmd\":\"stop\"} x", "json");
    assert_rejected("{\"cmd\":\"stop\"}{\"cmd\":\"stop\"}", "json");
    assert_rejected("[\"stop\"]", "json");                 /* not an object */
    assert_rejected("\"stop\"", "json");
    assert_rejected("7", "json");
    assert_rejected("null", "json");
    assert_rejected("{}", "unknown cmd");                  /* no cmd */
    assert_rejected("{\"command\":\"stop\"}", "unknown cmd");
    assert_rejected("{\"cmd\":7}", "unknown cmd");         /* cmd not a string */
    assert_rejected("{\"cmd\":null}", "unknown cmd");
    assert_rejected("{\"cmd\":[\"stop\"]}", "unknown cmd");

    /* An embedded NUL is not JSON; the bytes after it are not ignored. */
    {
        static const char nul[] = "{\"cmd\":\"stop\"}\0";
        cmd_t cmd;

        TEST_ASSERT_EQUAL_STRING("json", proto_parse_cmd(nul, sizeof nul - 1, &cmd));
    }
}

/* reason "unknown cmd" */
static void test_parse_rejects_unknown_cmd(void)
{
    assert_rejected("{\"cmd\":\"reboot\"}", "unknown cmd");
    assert_rejected("{\"cmd\":\"\"}", "unknown cmd");
    assert_rejected("{\"cmd\":\"STOP\"}", "unknown cmd"); /* case matters */
    assert_rejected("{\"cmd\":\"stop \"}", "unknown cmd");
    assert_rejected("{\"cmd\":\"cal\"}", "unknown cmd");
}

/* ch 0, 3, 1.5, "1", missing; dir "up", 1, missing */
static void test_parse_rejects_bad_channel_and_dir(void)
{
    assert_rejected("{\"cmd\":\"move\",\"ch\":0,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":3,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":-1,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1.5,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":\"1\",\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1e99,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"ch\":null,\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"move\",\"dir\":\"in\"}", "ch");
    assert_rejected("{\"cmd\":\"jog\",\"ch\":3,\"dir\":\"in\"}", "ch");

    assert_rejected("{\"cmd\":\"move\",\"ch\":1,\"dir\":\"up\"}", "dir");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1,\"dir\":1}", "dir");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1,\"dir\":\"IN\"}", "dir");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1,\"dir\":\"\"}", "dir");
    assert_rejected("{\"cmd\":\"move\",\"ch\":1}", "dir");
    assert_rejected("{\"cmd\":\"jog\",\"ch\":2,\"dir\":null}", "dir");

    /* ch is checked first */
    assert_rejected("{\"cmd\":\"move\",\"ch\":9,\"dir\":\"up\"}", "ch");
}

/* 0 and 14 accepted; -0.01, 14.01, missing, string rejected */
static void test_parse_target_range(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"titrate\",\"target\":0}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(0.0f, cmd.target);
    assert_parses("{\"cmd\":\"titrate\",\"target\":14}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(14.0f, cmd.target);
    assert_parses("{\"cmd\":\"titrate\",\"target\":14.00}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(14.0f, cmd.target);

    assert_rejected("{\"cmd\":\"titrate\",\"target\":-0.01}", "target");
    assert_rejected("{\"cmd\":\"titrate\",\"target\":14.01}", "target");
    assert_rejected("{\"cmd\":\"titrate\",\"target\":1e999}", "target"); /* strtod gives inf */
    assert_rejected("{\"cmd\":\"titrate\",\"target\":-1e999}", "target");
    assert_rejected("{\"cmd\":\"titrate\"}", "target");
    assert_rejected("{\"cmd\":\"titrate\",\"target\":\"7\"}", "target");
    assert_rejected("{\"cmd\":\"titrate\",\"target\":null}", "target");
    assert_rejected("{\"cmd\":\"titrate\",\"target\":[7]}", "target");
}

/* slope -70/-40 and offset -100/100 accepted; just outside rejected */
static void test_parse_cal_ranges(void)
{
    cmd_t cmd;

    assert_parses("{\"cmd\":\"cal_set\",\"slope\":-70,\"offset\":-100}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(-70.0f, cmd.cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(-100.0f, cmd.cal.offset);
    assert_parses("{\"cmd\":\"cal_set\",\"slope\":-40,\"offset\":100}", &cmd);
    TEST_ASSERT_EQUAL_FLOAT(-40.0f, cmd.cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(100.0f, cmd.cal.offset);

    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-70.01,\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-39.99,\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-59.16,\"offset\":-100.01}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-59.16,\"offset\":100.01}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":59.16,\"offset\":0}", "cal"); /* sign */
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":0,\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-1e999,\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-59.16}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":\"-59.16\",\"offset\":0}", "cal");
    assert_rejected("{\"cmd\":\"cal_set\",\"slope\":-59.16,\"offset\":null}", "cal");
}

/* len PROTO_MAX_MSG + 1 rejected without reading past data */
static void test_parse_rejects_too_long(void)
{
    static const char stop[] = "{\"cmd\":\"stop\"}";
    cmd_t cmd;
    char *msg = malloc(PROTO_MAX_MSG + 1);

    /* exactly the limit: padded with blanks, still a stop */
    memset(msg, ' ', PROTO_MAX_MSG);
    memcpy(msg, stop, sizeof stop - 1);
    TEST_ASSERT_NULL(proto_parse_cmd(msg, PROTO_MAX_MSG, &cmd));
    TEST_ASSERT_EQUAL(CMD_STOP, cmd.kind);

    /* one more byte: refused from the length alone (a valid command otherwise) */
    msg[PROTO_MAX_MSG] = ' ';
    TEST_ASSERT_EQUAL_STRING("too long", proto_parse_cmd(msg, PROTO_MAX_MSG + 1, &cmd));

    /* a length far beyond any buffer is refused without touching the data */
    TEST_ASSERT_EQUAL_STRING("too long", proto_parse_cmd(msg, (size_t)1 << 30, &cmd));
    free(msg);
}

/* data is not NUL-terminated (len bytes only) */
static void test_parse_needs_no_nul(void)
{
    /* parse() hands over heap copies without a terminator; check the edge cases there. */
    cmd_t cmd;

    assert_parses("{\"cmd\":\"stop\"}", &cmd);
    assert_parses("{\"cmd\":\"titrate\",\"target\":7}", &cmd); /* a number right before the end */
    assert_rejected("{\"cmd\":\"titrate\",\"target\":7", "json");
    assert_rejected("{\"cmd\":\"sto", "json");
    assert_rejected("{\"cmd\":\"stop\\", "json");
    assert_rejected("{", "json");
    assert_rejected("\"", "json");

    /* only the first len bytes count: a longer buffer with the rest of a command behind it */
    {
        static const char two[] = "{\"cmd\":\"stop\"}{\"cmd\":\"jog\"}";
        TEST_ASSERT_NULL(proto_parse_cmd(two, 14, &cmd));
        TEST_ASSERT_EQUAL(CMD_STOP, cmd.kind);
    }
}

/* Nesting is bounded so that a 100 B write cannot exhaust the control task's stack. */
static void test_parse_bounds_nesting(void)
{
    char msg[PROTO_MAX_MSG + 1];
    cmd_t cmd;

    memset(msg, '[', PROTO_MAX_MSG);
    msg[PROTO_MAX_MSG] = '\0';
    assert_rejected(msg, "json");

    memcpy(msg, "{\"cmd\":\"stop\",\"x\":", 18);
    memset(msg + 18, '[', 60);
    msg[78] = '\0';
    assert_rejected(msg, "json");

    /* brackets inside strings do not count as nesting */
    assert_parses("{\"cmd\":\"stop\",\"x\":\"[[[[[[[[[[{{{{{{{{{{\"}", &cmd);
    assert_parses("{\"cmd\":\"stop\",\"x\":\"\\\"[[[[[[[[[[\"}", &cmd);
    /* and a few levels are allowed */
    assert_parses("{\"cmd\":\"stop\",\"x\":{\"y\":[1,{\"z\":2}]}}", &cmd);
}

/* exact text {"evt":"ph","v":6.98,"mv":1.2}; rounding; negative values */
static void test_encode_ph(void)
{
    evt_t e = {.kind = EVT_PH};

    e.ph.ph = 6.98f;
    e.ph.mv = 1.2f;
    assert_encodes(&e, "{\"evt\":\"ph\",\"v\":6.98,\"mv\":1.2}");

    e.ph.ph = 7.0f;
    e.ph.mv = 0.0f;
    assert_encodes(&e, "{\"evt\":\"ph\",\"v\":7.00,\"mv\":0.0}");

    e.ph.ph = 4.126f; /* 2 and 1 decimals, rounded */
    e.ph.mv = 177.46f;
    assert_encodes(&e, "{\"evt\":\"ph\",\"v\":4.13,\"mv\":177.5}");

    e.ph.ph = -1.5f;
    e.ph.mv = -833.3333f;
    assert_encodes(&e, "{\"evt\":\"ph\",\"v\":-1.50,\"mv\":-833.3}");

    e.ph.ph = 14.0f;
    e.ph.mv = 500.04f;
    assert_encodes(&e, "{\"evt\":\"ph\",\"v\":14.00,\"mv\":500.0}");
}

/* idle / titrating / moving */
static void test_encode_state(void)
{
    evt_t e = {.kind = EVT_STATE};

    e.state = DEV_IDLE;
    assert_encodes(&e, "{\"evt\":\"state\",\"s\":\"idle\"}");
    e.state = DEV_TITRATING;
    assert_encodes(&e, "{\"evt\":\"state\",\"s\":\"titrating\"}");
    e.state = DEV_MOVING;
    assert_encodes(&e, "{\"evt\":\"state\",\"s\":\"moving\"}");
}

/* {"evt":"cal","slope":-59.16,"offset":0.00} or equivalent numbers */
static void test_encode_cal(void)
{
    evt_t e = {.kind = EVT_CAL};

    e.cal = (cal_t){.slope = CAL_DEFAULT_SLOPE, .offset = CAL_DEFAULT_OFFSET};
    assert_encodes(&e, "{\"evt\":\"cal\",\"slope\":-59.16,\"offset\":0.00}");

    e.cal = (cal_t){.slope = -57.92f, .offset = 4.35f};
    assert_encodes(&e, "{\"evt\":\"cal\",\"slope\":-57.92,\"offset\":4.35}");

    e.cal = (cal_t){.slope = -70.0f, .offset = -100.0f};
    assert_encodes(&e, "{\"evt\":\"cal\",\"slope\":-70.00,\"offset\":-100.00}");
}

/* with and without ch/dir and msg; ch index 0 -> "ch":1 */
static void test_encode_error(void)
{
    evt_t e;

    e = error_evt(ERR_BUSY, -1, DIR_IN, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"busy\"}");

    e = error_evt(ERR_LIMIT, CH_ACID, DIR_IN, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"limit\",\"ch\":1,\"dir\":\"in\"}");

    e = error_evt(ERR_LIMIT, CH_BASE, DIR_OUT, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"limit\",\"ch\":2,\"dir\":\"out\"}");

    e = error_evt(ERR_UNHOMED, CH_BASE, DIR_IN, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"unhomed\",\"ch\":2,\"dir\":\"in\"}");

    e = error_evt(ERR_BAD_CMD, -1, DIR_IN, "unknown cmd");
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"bad_cmd\",\"msg\":\"unknown cmd\"}");

    e = error_evt(ERR_LIMIT, CH_ACID, DIR_OUT, "empty");
    assert_encodes(&e,
                   "{\"evt\":\"error\",\"code\":\"limit\",\"ch\":1,\"dir\":\"out\",\"msg\":\"empty\"}");

    /* the remaining codes */
    e = error_evt(ERR_NO_CONVERGE, -1, DIR_IN, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"no_converge\"}");
    e = error_evt(ERR_SENSOR, -1, DIR_IN, NULL);
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"sensor\"}");
}

/* NaN / Inf -> 0 */
static void test_encode_rejects_non_finite(void)
{
    char buf[PROTO_MAX_MSG + 1];
    evt_t e = {.kind = EVT_PH};
    const float bad[] = {NAN, INFINITY, -INFINITY};

    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        e.kind = EVT_PH;
        e.ph.ph = bad[i];
        e.ph.mv = 1.0f;
        TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
        TEST_ASSERT_EQUAL_STRING("", buf);

        e.ph.ph = 7.0f;
        e.ph.mv = bad[i];
        TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));

        e.kind = EVT_CAL;
        e.cal = (cal_t){.slope = bad[i], .offset = 0.0f};
        TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
        e.cal = (cal_t){.slope = -59.16f, .offset = bad[i]};
        TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
    }
}

/* too small buffer -> 0, worst case of every event <= PROTO_MAX_MSG */
static void test_encode_respects_cap(void)
{
    char buf[PROTO_MAX_MSG + 1];
    evt_t e = {.kind = EVT_STATE, .state = DEV_TITRATING};
    const char *text = "{\"evt\":\"state\",\"s\":\"titrating\"}";
    size_t len = strlen(text);

    /* exactly the length plus the NUL fits; one byte less does not */
    TEST_ASSERT_EQUAL_UINT(len, proto_encode_evt(&e, buf, len + 1));
    TEST_ASSERT_EQUAL_STRING(text, buf);
    memset(buf, 'x', sizeof buf);
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, len));
    TEST_ASSERT_EQUAL_STRING("", buf);
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, 1));
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, NULL, 0));

    /* Far beyond the values a device can produce, still within the limit. */
    {
        const evt_t worst[] = {
            {.kind = EVT_PH, .ph = {.ph = -9999.99f, .mv = -99999.9f}},
            {.kind = EVT_CAL, .cal = {.slope = -9999.99f, .offset = -99999.99f}},
            {.kind = EVT_STATE, .state = DEV_TITRATING},
            error_evt(ERR_NO_CONVERGE, CH_BASE, DIR_OUT, "unknown cmd"),
        };

        for (size_t i = 0; i < sizeof worst / sizeof worst[0]; i++) {
            size_t n = proto_encode_evt(&worst[i], buf, sizeof buf);

            TEST_ASSERT_GREATER_THAN_UINT(0, n);
            TEST_ASSERT_LESS_OR_EQUAL_UINT(PROTO_MAX_MSG, n);
            TEST_ASSERT_EQUAL_UINT(strlen(buf), n);
        }
    }

    /* A finite value that does not fit in PROTO_MAX_MSG is refused, however large the buffer. */
    {
        char big[256];

        e = (evt_t){.kind = EVT_PH, .ph = {.ph = 3.0e38f, .mv = 3.0e38f}};
        TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, big, sizeof big));
        TEST_ASSERT_EQUAL_STRING("", big);
    }

    /* A msg that does not fit is left out; the error itself is still sent. */
    {
        const char *bare = "{\"evt\":\"error\",\"code\":\"bad_cmd\"}";
        char msg[PROTO_MAX_MSG + 1];
        size_t room = PROTO_MAX_MSG - strlen(bare) - strlen(",\"msg\":\"\""); /* longest msg that fits */

        memset(msg, 'a', sizeof msg);
        msg[room] = '\0';
        e = error_evt(ERR_BAD_CMD, -1, DIR_IN, msg);
        TEST_ASSERT_EQUAL_UINT(PROTO_MAX_MSG, proto_encode_evt(&e, buf, sizeof buf));
        TEST_ASSERT_NOT_NULL(strstr(buf, msg));

        msg[room] = 'a';
        msg[room + 1] = '\0';
        e = error_evt(ERR_BAD_CMD, -1, DIR_IN, msg);
        assert_encodes(&e, bare);

        e = error_evt(ERR_BAD_CMD, -1, DIR_IN,
                      "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789");
        assert_encodes(&e, bare);

        /* ch and dir are kept */
        e = error_evt(ERR_LIMIT, CH_BASE, DIR_OUT, msg);
        assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"limit\",\"ch\":2,\"dir\":\"out\"}");
    }
}

/* Anything that has no valid wire form is refused instead of producing broken JSON; only an
 * error's optional msg is dropped instead. */
static void test_encode_rejects_invalid_values(void)
{
    char buf[PROTO_MAX_MSG + 1];
    evt_t e = {.kind = EVT_STATE};

    e.state = (dev_state_t)7;
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
    e.state = (dev_state_t)-1;
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));

    e = error_evt(ERR_COUNT, -1, DIR_IN, NULL);
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
    e = error_evt(ERR_LIMIT, CH_COUNT, DIR_IN, NULL);
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));
    e = error_evt(ERR_LIMIT, CH_ACID, (dir_t)2, NULL);
    TEST_ASSERT_EQUAL_UINT(0, proto_encode_evt(&e, buf, sizeof buf));

    /* A msg that would need escaping is left out; the error is still sent. */
    e = error_evt(ERR_BAD_CMD, -1, DIR_IN, "say \"x\"");
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"bad_cmd\"}");
    e = error_evt(ERR_BAD_CMD, -1, DIR_IN, "a\\b");
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"bad_cmd\"}");
    e = error_evt(ERR_BAD_CMD, -1, DIR_IN, "a\nb");
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"bad_cmd\"}");
    e = error_evt(ERR_LIMIT, CH_ACID, DIR_IN, "a\"b");
    assert_encodes(&e, "{\"evt\":\"error\",\"code\":\"limit\",\"ch\":1,\"dir\":\"in\"}");
}

/* Everything the encoder emits is something the app can parse back as one JSON object. */
static void test_encode_output_is_parseable_json(void)
{
    char buf[PROTO_MAX_MSG + 1];
    evt_t e = error_evt(ERR_LIMIT, CH_BASE, DIR_OUT, "x");
    cmd_t cmd;
    size_t n = proto_encode_evt(&e, buf, sizeof buf);

    /* The parser reports an unknown cmd (no `cmd` key) only for a well-formed object. */
    TEST_ASSERT_GREATER_THAN_UINT(0, n);
    TEST_ASSERT_EQUAL_STRING("unknown cmd", proto_parse_cmd(buf, n, &cmd));
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_parse_titrate);
    RUN_TEST(test_parse_stop);
    RUN_TEST(test_parse_sync);
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
    RUN_TEST(test_parse_bounds_nesting);
    RUN_TEST(test_encode_ph);
    RUN_TEST(test_encode_state);
    RUN_TEST(test_encode_cal);
    RUN_TEST(test_encode_error);
    RUN_TEST(test_encode_rejects_non_finite);
    RUN_TEST(test_encode_respects_cap);
    RUN_TEST(test_encode_rejects_invalid_values);
    RUN_TEST(test_encode_output_is_parseable_json);
    return UNITY_END();
}
