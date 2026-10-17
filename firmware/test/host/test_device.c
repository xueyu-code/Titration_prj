/* core/device.c with recording fake ports: protocol 3 behaviour, event order included. */
#include <string.h>

#include "unity.h"
#include "core/device.h"
#include "core/config.h"
#include "core/ph.h"

/* ---------------------------------------------------------------- fakes */

#define MAX_EVT 128
#define MAX_CALL 64
#define NOT_FOUND ((size_t)-1)

typedef enum { CALL_START, CALL_EXTEND, CALL_HALT } call_kind_t;

typedef struct {
    call_kind_t kind;
    uint8_t ch;
    dir_t dir;     /* START, EXTEND */
    int32_t steps; /* START, EXTEND */
    uint32_t tag;  /* START */
} call_t;

/* What the fake ports recorded, and what they answer. */
static struct {
    evt_t evt[MAX_EVT];
    size_t n_evt;
    call_t call[MAX_CALL];
    size_t n_call;
    axis_status_t start_result; /* answer of motor_start */
    bool extend_result;         /* answer of motor_extend */
    bool save_result;           /* answer of cal_save */
    uint32_t last_tag; /* of the last motor_start */
    int n_saved;
    cal_t saved;
} fk;

static device_t dev;
static cal_t s_cal; /* the calibration the device was last given: what the "electrode" is read with */
static uint32_t now;

static void port_emit(void *ctx, const evt_t *evt)
{
    (void)ctx;
    TEST_ASSERT_TRUE(fk.n_evt < MAX_EVT);
    fk.evt[fk.n_evt++] = *evt;
}

static call_t *new_call(call_kind_t kind, uint8_t ch)
{
    TEST_ASSERT_TRUE(fk.n_call < MAX_CALL);
    call_t *c = &fk.call[fk.n_call++];
    *c = (call_t){.kind = kind, .ch = ch};
    return c;
}

static axis_status_t port_motor_start(void *ctx, uint8_t ch, dir_t dir, int32_t steps, uint32_t tag)
{
    (void)ctx;
    call_t *c = new_call(CALL_START, ch);
    c->dir = dir;
    c->steps = steps;
    c->tag = tag;
    fk.last_tag = tag;
    return fk.start_result;
}

static bool port_motor_extend(void *ctx, uint8_t ch, dir_t dir, int32_t steps)
{
    (void)ctx;
    call_t *c = new_call(CALL_EXTEND, ch);
    c->dir = dir;
    c->steps = steps;
    return fk.extend_result;
}

static void port_motor_halt(void *ctx, uint8_t ch)
{
    (void)ctx;
    new_call(CALL_HALT, ch);
}

static bool port_cal_save(void *ctx, const cal_t *cal)
{
    (void)ctx;
    fk.n_saved++;
    fk.saved = *cal;
    return fk.save_result;
}

void setUp(void)
{
    memset(&fk, 0, sizeof fk);
    fk.start_result = AXIS_RUNNING;
    fk.extend_result = true;
    fk.save_result = true;

    const device_ports_t ports = {
        .emit = port_emit,
        .motor_start = port_motor_start,
        .motor_extend = port_motor_extend,
        .motor_halt = port_motor_halt,
        .cal_save = port_cal_save,
    };
    s_cal = ph_cal_default();
    now = 100000;
    device_init(&dev, &ports, &s_cal);
}

void tearDown(void) {}

/* -------------------------------------------------------------- helpers */

static const char *const TITRATE = "{\"cmd\":\"titrate\",\"target\":7.00}";
static const char *const STOP = "{\"cmd\":\"stop\"}";
static const char *const CAL_SET = "{\"cmd\":\"cal_set\",\"slope\":-57.92,\"offset\":4.35}";
static const char *const MOVE_1_OUT = "{\"cmd\":\"move\",\"ch\":1,\"dir\":\"out\"}";
static const char *const MOVE_1_IN = "{\"cmd\":\"move\",\"ch\":1,\"dir\":\"in\"}";
static const char *const MOVE_2_OUT = "{\"cmd\":\"move\",\"ch\":2,\"dir\":\"out\"}";
static const char *const MOVE_2_IN = "{\"cmd\":\"move\",\"ch\":2,\"dir\":\"in\"}";
static const char *const JOG_1_IN = "{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"in\"}";
static const char *const JOG_1_OUT = "{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"out\"}";

/* The number of steps of a dose of ul. */
static int32_t dose_steps(float ul)
{
    return (int32_t)(ul / UL_PER_STEP + 0.5f);
}

static void write(const char *json)
{
    device_on_write(&dev, json, strlen(json), now);
}

static void clear_log(void)
{
    fk.n_evt = 0;
    fk.n_call = 0;
}

static size_t count_calls(call_kind_t kind)
{
    size_t n = 0;
    for (size_t i = 0; i < fk.n_call; i++)
        n += fk.call[i].kind == kind;
    return n;
}

/* Index of the first error event with this code, or NOT_FOUND. */
static size_t find_error(err_code_t code)
{
    for (size_t i = 0; i < fk.n_evt; i++) {
        if (fk.evt[i].kind == EVT_ERROR && fk.evt[i].error.code == code)
            return i;
    }
    return NOT_FOUND;
}

static size_t count_errors(err_code_t code)
{
    size_t n = 0;
    for (size_t i = 0; i < fk.n_evt; i++)
        n += fk.evt[i].kind == EVT_ERROR && fk.evt[i].error.code == code;
    return n;
}

static size_t count_evts(evt_kind_t kind)
{
    size_t n = 0;
    for (size_t i = 0; i < fk.n_evt; i++)
        n += fk.evt[i].kind == kind;
    return n;
}

static size_t count_phs(void)
{
    return count_evts(EVT_PH);
}

static void expect_evt_count(size_t n)
{
    TEST_ASSERT_EQUAL_UINT(n, fk.n_evt);
}

static void expect_call_count(size_t n)
{
    TEST_ASSERT_EQUAL_UINT(n, fk.n_call);
}

static void expect_state(size_t i, dev_state_t s)
{
    TEST_ASSERT_TRUE(i < fk.n_evt);
    TEST_ASSERT_EQUAL_INT(EVT_STATE, fk.evt[i].kind);
    TEST_ASSERT_EQUAL_INT(s, fk.evt[i].state);
}

static void expect_cal(size_t i, float slope, float offset)
{
    TEST_ASSERT_TRUE(i < fk.n_evt);
    TEST_ASSERT_EQUAL_INT(EVT_CAL, fk.evt[i].kind);
    TEST_ASSERT_EQUAL_FLOAT(slope, fk.evt[i].cal.slope);
    TEST_ASSERT_EQUAL_FLOAT(offset, fk.evt[i].cal.offset);
}

/* ch: channel index, or -1 for an error without ch/dir. msg: NULL for none. */
static void expect_error(size_t i, err_code_t code, int ch, dir_t dir, const char *msg)
{
    TEST_ASSERT_TRUE(i < fk.n_evt);
    const evt_t *e = &fk.evt[i];
    TEST_ASSERT_EQUAL_INT(EVT_ERROR, e->kind);
    TEST_ASSERT_EQUAL_INT(code, e->error.code);
    TEST_ASSERT_EQUAL_INT(ch, e->error.ch);
    if (ch >= 0)
        TEST_ASSERT_EQUAL_INT(dir, e->error.dir);
    if (msg)
        TEST_ASSERT_EQUAL_STRING(msg, e->error.msg);
    else
        TEST_ASSERT_NULL(e->error.msg);
}

static void expect_start(size_t i, uint8_t ch, dir_t dir, int32_t steps)
{
    TEST_ASSERT_TRUE(i < fk.n_call);
    const call_t *c = &fk.call[i];
    TEST_ASSERT_EQUAL_INT(CALL_START, c->kind);
    TEST_ASSERT_EQUAL_UINT8(ch, c->ch);
    TEST_ASSERT_EQUAL_INT(dir, c->dir);
    TEST_ASSERT_EQUAL_INT32(steps, c->steps);
}

static void expect_extend(size_t i, uint8_t ch, dir_t dir, int32_t steps)
{
    TEST_ASSERT_TRUE(i < fk.n_call);
    const call_t *c = &fk.call[i];
    TEST_ASSERT_EQUAL_INT(CALL_EXTEND, c->kind);
    TEST_ASSERT_EQUAL_UINT8(ch, c->ch);
    TEST_ASSERT_EQUAL_INT(dir, c->dir);
    TEST_ASSERT_EQUAL_INT32(steps, c->steps);
}

static void expect_halt(size_t i, uint8_t ch)
{
    TEST_ASSERT_TRUE(i < fk.n_call);
    TEST_ASSERT_EQUAL_INT(CALL_HALT, fk.call[i].kind);
    TEST_ASSERT_EQUAL_UINT8(ch, fk.call[i].ch);
}

/* The tag of the last motor_start (it outlives clear_log). */
static uint32_t last_tag(void)
{
    return fk.last_tag;
}

static void end_motion(uint8_t ch, axis_status_t st, uint32_t tag)
{
    device_on_motion_end(&dev, ch, st, tag, now);
}

/* One ADC window: the electrode shows `ph` under the calibration s_cal. */
static void sample_ph(float ph)
{
    now += SAMPLE_PERIOD_MS;
    float mv = s_cal.offset + s_cal.slope * (ph - 7.0f);
    device_on_sample(&dev, true, FE_BIAS_MV + FE_GAIN * mv, now);
}

/* A window at the rail, and a failed ADC read. */
static void sample_rail(void)
{
    now += SAMPLE_PERIOD_MS;
    device_on_sample(&dev, true, 0.0f, now);
}

static void sample_failed(void)
{
    now += SAMPLE_PERIOD_MS;
    device_on_sample(&dev, false, 0.0f, now);
}

/* Samples at ph until the titration starts a dose (or ends). */
static void run_until_dose(float ph)
{
    size_t starts = count_calls(CALL_START);
    for (int i = 0; i < 200 && count_calls(CALL_START) == starts && device_state(&dev) == DEV_TITRATING; i++)
        sample_ph(ph);
}

/* A titration with the first dose (acid, 8.0 -> 7.0) under way; the log is cleared. */
static void titrating_with_dose(void)
{
    clear_log();
    write(TITRATE);
    run_until_dose(8.0f);
    TEST_ASSERT_EQUAL_INT(DEV_TITRATING, device_state(&dev));
    TEST_ASSERT_EQUAL_UINT(1, count_calls(CALL_START));
    clear_log();
}

/* The command is turned down with busy, and nothing else happens. */
static void assert_busy(const char *json)
{
    int saved = fk.n_saved;
    dev_state_t state = device_state(&dev);

    clear_log();
    write(json);
    expect_evt_count(1);
    expect_error(0, ERR_BUSY, -1, DIR_IN, NULL);
    expect_call_count(0);
    TEST_ASSERT_EQUAL_INT(saved, fk.n_saved);
    TEST_ASSERT_EQUAL_INT(state, device_state(&dev));
}

/* ---------------------------------------------------------------- tests */

/* state then cal */
static void test_subscribe_reports_state_and_cal(void)
{
    device_on_subscribe(&dev);
    expect_evt_count(2);
    expect_state(0, DEV_IDLE);
    expect_cal(1, CAL_DEFAULT_SLOPE, CAL_DEFAULT_OFFSET);

    /* Whatever the state is by then, and the stored calibration. */
    write(CAL_SET);
    write(MOVE_1_OUT);
    clear_log();
    device_on_subscribe(&dev);
    expect_evt_count(2);
    expect_state(0, DEV_MOVING);
    expect_cal(1, -57.92f, 4.35f);
}

/* titrate and cal_set are busy while titrating or moving; stop/move/jog accepted */
static void test_state_table(void)
{
    /* idle: everything is accepted. */
    write(CAL_SET);
    write(MOVE_1_OUT);
    write(STOP);
    write(JOG_1_OUT);
    write(STOP);
    write(TITRATE);
    TEST_ASSERT_EQUAL_INT(DEV_TITRATING, device_state(&dev));
    TEST_ASSERT_EQUAL_INT(1, fk.n_saved);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));

    /* titrating: titrate and cal_set are busy ... */
    assert_busy(TITRATE);
    assert_busy(CAL_SET);
    /* ... stop, move and jog go through. */
    clear_log();
    write(MOVE_1_OUT);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));
    write(STOP);
    write(TITRATE);
    clear_log();
    write(JOG_1_OUT);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));
    write(STOP);
    write(TITRATE);
    write(STOP);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));

    /* moving: the same two are busy; stop, move and jog go through. */
    write(MOVE_1_OUT);
    assert_busy(TITRATE);
    assert_busy(CAL_SET);
    clear_log();
    write(MOVE_1_OUT);
    write(JOG_1_OUT);
    write(MOVE_2_OUT);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));
    write(STOP);
    expect_state(fk.n_evt - 1, DEV_IDLE);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));
    TEST_ASSERT_EQUAL_INT(1, fk.n_saved); /* only the first cal_set */
}

/* unparsable or out of range -> error bad_cmd with msg; parse errors win over busy */
static void test_bad_cmd_with_reason(void)
{
    struct {
        const char *json;
        const char *msg;
    } bad[] = {
        {"not json", "json"},
        {"{\"cmd\":\"fly\"}", "unknown cmd"},
        {"{\"cmd\":\"move\",\"ch\":3,\"dir\":\"in\"}", "ch"},
        {"{\"cmd\":\"jog\",\"ch\":1,\"dir\":\"up\"}", "dir"},
        {"{\"cmd\":\"titrate\",\"target\":15}", "target"},
        {"{\"cmd\":\"cal_set\",\"slope\":-30,\"offset\":0}", "cal"},
    };

    /* In every state: bad_cmd, never busy, nothing else. */
    for (int state = 0; state < 3; state++) {
        setUp();
        if (state == 1)
            write(TITRATE);
        if (state == 2)
            write(MOVE_1_OUT);
        dev_state_t before = device_state(&dev);

        for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
            clear_log();
            write(bad[i].json);
            expect_evt_count(1);
            expect_error(0, ERR_BAD_CMD, -1, DIR_IN, bad[i].msg);
            expect_call_count(0);
            TEST_ASSERT_EQUAL_INT(before, device_state(&dev));
        }

        /* A write longer than PROTO_MAX_MSG: the device is told by the length alone. */
        char big[PROTO_MAX_MSG + 1];
        memset(big, ' ', sizeof big);
        clear_log();
        device_on_write(&dev, big, sizeof big, now);
        expect_evt_count(1);
        expect_error(0, ERR_BAD_CMD, -1, DIR_IN, "too long");
    }
    TEST_ASSERT_EQUAL_INT(0, fk.n_saved);
}

/* titrate -> state titrating; stop -> halt + state idle; stop when idle emits nothing */
static void test_titrate_and_stop(void)
{
    write(TITRATE);
    expect_evt_count(1);
    expect_state(0, DEV_TITRATING);
    expect_call_count(0);

    /* Waiting between doses: nothing is running, so there is nothing to halt. */
    clear_log();
    write(STOP);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    expect_call_count(0);

    clear_log();
    write(STOP);
    expect_evt_count(0);
    expect_call_count(0);

    /* A dose under way is halted; its late end is ignored and nothing doses any more. */
    titrating_with_dose();
    uint32_t tag = last_tag();
    write(STOP);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    expect_call_count(1);
    expect_halt(0, CH_ACID);

    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    for (int i = 0; i < 40; i++)
        sample_ph(8.0f);
    expect_call_count(0);
    expect_evt_count(count_phs());
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));
}

/* a move or jog is stopped by stop */
static void test_stop_halts_motion(void)
{
    write(MOVE_2_OUT);
    clear_log();
    write(STOP);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    expect_call_count(1);
    expect_halt(0, CH_BASE);

    write(JOG_1_IN);
    clear_log();
    write(STOP);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    expect_halt(0, CH_ACID);

    /* The jog is gone: the watchdog has nothing to stop. */
    clear_log();
    device_tick(&dev, now + 5 * JOG_TIMEOUT_MS);
    expect_evt_count(0);
    expect_call_count(0);
}

/* error sensor, state unchanged */
static void test_titrate_refused_on_sensor_fault(void)
{
    for (int i = 0; i < 5; i++)
        sample_rail();
    TEST_ASSERT_EQUAL_UINT(1, count_errors(ERR_SENSOR));

    clear_log();
    write(TITRATE);
    expect_evt_count(1);
    expect_error(0, ERR_SENSOR, -1, DIR_IN, NULL);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));

    /* The fault ends with the first good window, silently. */
    clear_log();
    sample_ph(7.0f);
    expect_evt_count(1);
    TEST_ASSERT_EQUAL_INT(EVT_PH, fk.evt[0].kind);
    clear_log();
    write(TITRATE);
    expect_evt_count(1);
    expect_state(0, DEV_TITRATING);
}

/* same ch/dir: motor_extend(MOVE_STEPS); extend fails -> new start */
static void test_move_accumulates(void)
{
    write(MOVE_1_OUT);
    expect_call_count(1);
    expect_start(0, CH_ACID, DIR_OUT, MOVE_STEPS);
    expect_evt_count(1);
    expect_state(0, DEV_MOVING);
    uint32_t tag = last_tag();

    /* Taps add up, with no new event. */
    clear_log();
    write(MOVE_1_OUT);
    write(MOVE_1_OUT);
    expect_call_count(2);
    expect_extend(0, CH_ACID, DIR_OUT, MOVE_STEPS);
    expect_extend(1, CH_ACID, DIR_OUT, MOVE_STEPS);
    expect_evt_count(0);

    /* The motion has just ended (its end is still on its way): a new one starts. */
    fk.extend_result = false;
    clear_log();
    write(MOVE_1_OUT);
    expect_call_count(3);
    expect_extend(0, CH_ACID, DIR_OUT, MOVE_STEPS);
    expect_halt(1, CH_ACID);
    expect_start(2, CH_ACID, DIR_OUT, MOVE_STEPS);
    TEST_ASSERT_NOT_EQUAL(tag, last_tag());
    expect_evt_count(0); /* still moving */
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));

    /* The old end that arrives now is outdated; the new one is not. */
    uint32_t new_tag = last_tag();
    end_motion(CH_ACID, AXIS_DONE, tag);
    expect_evt_count(0);
    end_motion(CH_ACID, AXIS_DONE, new_tag);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
}

/* other ch or dir: halt, start the new one, no state change */
static void test_move_switches_motion(void)
{
    write(MOVE_1_OUT);

    clear_log();
    write(MOVE_2_OUT); /* other channel */
    expect_call_count(2);
    expect_halt(0, CH_ACID);
    expect_start(1, CH_BASE, DIR_OUT, MOVE_STEPS);
    expect_evt_count(0);

    clear_log();
    write(MOVE_2_IN); /* other direction */
    expect_call_count(2);
    expect_halt(0, CH_BASE);
    expect_start(1, CH_BASE, DIR_IN, MOVE_STEPS);
    expect_evt_count(0);

    clear_log();
    write(JOG_1_IN); /* a jog of another channel replaces a move */
    expect_call_count(2);
    expect_halt(0, CH_BASE);
    expect_start(1, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_evt_count(0);

    clear_log();
    write(MOVE_1_IN); /* a jog goes on when a move of its own kind is asked for */
    expect_call_count(0);
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));

    clear_log();
    write(JOG_1_OUT); /* a jog of the other direction replaces a jog */
    expect_call_count(2);
    expect_halt(0, CH_ACID);
    expect_start(1, CH_ACID, DIR_OUT, AXIS_CONTINUOUS);
    expect_evt_count(0);
}

/* move while titrating -> state moving, titration over */
static void test_move_ends_titration(void)
{
    /* With a dose under way: it is halted first. */
    titrating_with_dose();
    write(MOVE_2_IN);
    expect_call_count(2);
    expect_halt(0, CH_ACID);
    expect_start(1, CH_BASE, DIR_IN, MOVE_STEPS);
    expect_evt_count(1);
    expect_state(0, DEV_MOVING);
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));

    /* The titration is over: no more doses, whatever the pH. */
    clear_log();
    for (int i = 0; i < 60; i++)
        sample_ph(8.0f);
    expect_call_count(0);
    expect_evt_count(count_phs());
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));

    /* While waiting between doses: nothing to halt. */
    write(STOP);
    write(TITRATE);
    clear_log();
    write(JOG_1_IN);
    expect_call_count(1);
    expect_start(0, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_evt_count(1);
    expect_state(0, DEV_MOVING);
}

/* refresh keeps it going; JOG_TIMEOUT_MS without jog -> halt + state idle */
static void test_jog_watchdog(void)
{
    uint32_t t0 = now;

    write(JOG_1_IN);
    expect_call_count(1);
    expect_start(0, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_evt_count(1);
    expect_state(0, DEV_MOVING);

    clear_log();
    device_tick(&dev, t0 + 900);
    expect_evt_count(0);
    now = t0 + 900;
    write(JOG_1_IN); /* the app resends: only the deadline moves */
    expect_call_count(0);
    expect_evt_count(0);

    device_tick(&dev, t0 + JOG_TIMEOUT_MS); /* 1000 ms after the first jog, 100 after the second */
    device_tick(&dev, t0 + 900 + JOG_TIMEOUT_MS - 1);
    expect_evt_count(0);
    expect_call_count(0);

    device_tick(&dev, t0 + 900 + JOG_TIMEOUT_MS);
    expect_call_count(1);
    expect_halt(0, CH_ACID);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE); /* a normal end: no error */

    device_tick(&dev, t0 + 5000);
    expect_call_count(1);
    expect_evt_count(1);
}

/* the 32-bit millisecond clock wraps; the watchdog works across it */
static void test_jog_watchdog_across_clock_wrap(void)
{
    now = UINT32_MAX - 500;
    uint32_t t0 = now;

    write(JOG_1_OUT);
    clear_log();
    device_tick(&dev, t0 + 100); /* the deadline has wrapped, the clock not yet */
    expect_evt_count(0);
    expect_call_count(0);
    device_tick(&dev, t0 + JOG_TIMEOUT_MS - 1); /* wrapped past zero */
    expect_evt_count(0);
    expect_call_count(0);
    device_tick(&dev, t0 + JOG_TIMEOUT_MS);
    expect_halt(0, CH_ACID);
    expect_state(0, DEV_IDLE);
}

/* jog continues */
static void test_move_during_jog_is_noop(void)
{
    uint32_t t0 = now;

    write(JOG_1_IN);
    clear_log();
    now = t0 + 500;
    write(MOVE_1_IN);
    expect_call_count(0);
    expect_evt_count(0);

    /* It did not change the jog: the deadline is still the one of the jog command. */
    device_tick(&dev, t0 + JOG_TIMEOUT_MS - 1);
    expect_evt_count(0);
    device_tick(&dev, t0 + JOG_TIMEOUT_MS);
    expect_halt(0, CH_ACID);
    expect_state(0, DEV_IDLE);
}

/* a jog of the move's own channel and direction makes the move a jog */
static void test_jog_takes_over_move(void)
{
    uint32_t t0 = now;

    write(MOVE_1_IN);
    clear_log();
    write(JOG_1_IN);
    expect_call_count(1);
    expect_extend(0, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_evt_count(0);

    /* Now the watchdog is on. */
    device_tick(&dev, t0 + JOG_TIMEOUT_MS);
    expect_halt(1, CH_ACID);
    expect_state(0, DEV_IDLE);

    /* The move has just ended: a new motion starts, without the old one's help. */
    write(MOVE_1_IN);
    fk.extend_result = false;
    clear_log();
    write(JOG_1_IN);
    expect_call_count(3);
    expect_extend(0, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_halt(1, CH_ACID);
    expect_start(2, CH_ACID, DIR_IN, AXIS_CONTINUOUS);
    expect_evt_count(0);
}

/* unhomed / limit refusal -> error with ch/dir, then state idle (if not idle) */
static void test_refused_motion(void)
{
    /* From idle: the error alone. Nothing was moving. */
    fk.start_result = AXIS_UNHOMED;
    write(JOG_1_IN);
    expect_call_count(1);
    expect_evt_count(1);
    expect_error(0, ERR_UNHOMED, CH_ACID, DIR_IN, NULL);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));

    clear_log();
    fk.start_result = AXIS_LIMIT_OUT;
    write(MOVE_2_OUT);
    expect_evt_count(1);
    expect_error(0, ERR_LIMIT, CH_BASE, DIR_OUT, NULL);

    clear_log();
    fk.start_result = AXIS_LIMIT_IN;
    write(MOVE_2_IN);
    expect_evt_count(1);
    expect_error(0, ERR_LIMIT, CH_BASE, DIR_IN, NULL);

    /* From a move: the old motion is halted, the error comes, then idle. */
    fk.start_result = AXIS_RUNNING;
    write(MOVE_1_OUT);
    uint32_t move_tag = last_tag();
    clear_log();
    fk.start_result = AXIS_UNHOMED;
    write(MOVE_1_IN);
    expect_call_count(2);
    expect_halt(0, CH_ACID);
    expect_evt_count(2);
    expect_error(0, ERR_UNHOMED, CH_ACID, DIR_IN, NULL);
    expect_state(1, DEV_IDLE);

    /* The refused motion is not running: no watchdog, no halt, no stale end. */
    clear_log();
    device_tick(&dev, now + 5 * JOG_TIMEOUT_MS);
    end_motion(CH_ACID, AXIS_DONE, move_tag);
    expect_evt_count(0);
    expect_call_count(0);

    /* From a titration: the titration is over as well. */
    fk.start_result = AXIS_RUNNING;
    titrating_with_dose();
    fk.start_result = AXIS_LIMIT_IN;
    write(MOVE_2_IN);
    expect_call_count(2);
    expect_halt(0, CH_ACID);
    expect_evt_count(2);
    expect_error(0, ERR_LIMIT, CH_BASE, DIR_IN, NULL);
    expect_state(1, DEV_IDLE);
    clear_log();
    fk.start_result = AXIS_RUNNING;
    for (int i = 0; i < 60; i++)
        sample_ph(8.0f);
    expect_call_count(0);
}


/* DONE -> idle; LIMIT_OUT/IN -> error limit ch/dir then idle; stale tag ignored */
static void test_motion_end(void)
{
    /* A move that ends by itself: idle, no error. */
    write(MOVE_1_OUT);
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, last_tag());
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    expect_call_count(0);

    /* The empty-end switch stops a jog out. */
    write(JOG_1_OUT);
    clear_log();
    end_motion(CH_ACID, AXIS_LIMIT_OUT, last_tag());
    expect_evt_count(2);
    expect_error(0, ERR_LIMIT, CH_ACID, DIR_OUT, NULL);
    expect_state(1, DEV_IDLE);
    expect_call_count(0); /* it has stopped by itself: nothing to halt */

    /* The soft limit stops a move in. */
    write(MOVE_2_IN);
    clear_log();
    end_motion(CH_BASE, AXIS_LIMIT_IN, last_tag());
    expect_evt_count(2);
    expect_error(0, ERR_LIMIT, CH_BASE, DIR_IN, NULL);
    expect_state(1, DEV_IDLE);

    /* An end that arrives after the motion was replaced (other tag), or for the other channel, is
     * outdated. */
    write(MOVE_1_OUT);
    uint32_t old_tag = last_tag();
    write(MOVE_2_OUT);
    uint32_t tag = last_tag();
    TEST_ASSERT_NOT_EQUAL(old_tag, tag);
    clear_log();
    end_motion(CH_ACID, AXIS_LIMIT_OUT, old_tag);
    end_motion(CH_BASE, AXIS_DONE, old_tag);
    end_motion(CH_ACID, AXIS_DONE, tag);
    expect_evt_count(0);
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));
    end_motion(CH_BASE, AXIS_LIMIT_OUT, tag);
    expect_evt_count(2);
    expect_error(0, ERR_LIMIT, CH_BASE, DIR_OUT, NULL);
    expect_state(1, DEV_IDLE);

    /* Nothing runs any more: the same end again, and the end of a stopped motion, change nothing. */
    clear_log();
    end_motion(CH_BASE, AXIS_LIMIT_OUT, tag);
    write(MOVE_1_OUT);
    tag = last_tag();
    write(STOP);
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    expect_evt_count(0);
    expect_call_count(0);
}

/* TITR_DOSE -> motor_start(out, round(ul / UL_PER_STEP)); DONE -> next wait */
static void test_dose_cycle(void)
{
    write(TITRATE);
    uint32_t t_titrate = now;
    clear_log();

    /* The first decision comes SETTLE_SKIP_MS + (SETTLE_N - 1) readings after the start: the first
     * dose is FIRST_DOSE_UL of acid (ch 1), the pH being above the target. */
    run_until_dose(8.0f);
    TEST_ASSERT_EQUAL_UINT32(t_titrate + SETTLE_SKIP_MS + (SETTLE_N - 1) * SAMPLE_PERIOD_MS, now);
    expect_call_count(1);
    expect_start(0, CH_ACID, DIR_OUT, dose_steps(FIRST_DOSE_UL));
    TEST_ASSERT_EQUAL_INT32(121, fk.call[0].steps);
    TEST_ASSERT_EQUAL_UINT(0, count_evts(EVT_STATE)); /* still titrating, no event */
    TEST_ASSERT_EQUAL_UINT(0, count_errors(ERR_BUSY));
    TEST_ASSERT_EQUAL_INT(DEV_TITRATING, device_state(&dev));
    uint32_t tag = last_tag();

    /* While it is delivered the readings count for nothing. */
    clear_log();
    for (int i = 0; i < 40; i++)
        sample_ph(5.0f);
    expect_call_count(0);
    TEST_ASSERT_EQUAL_UINT(0, count_evts(EVT_STATE));

    /* Delivered: the wait begins now; the next decision is on the same footing. */
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    uint32_t t_done = now;
    expect_evt_count(0);
    run_until_dose(7.6f);
    TEST_ASSERT_EQUAL_UINT32(t_done + SETTLE_SKIP_MS + (SETTLE_N - 1) * SAMPLE_PERIOD_MS, now);
    expect_call_count(1);
    /* 8.0 -> 7.6 after 50 uL: 0.5 * 0.6 * 50 / 0.4 = 37.5 uL. */
    expect_start(0, CH_ACID, DIR_OUT, dose_steps(37.5f));
    TEST_ASSERT_NOT_EQUAL(tag, last_tag());
    TEST_ASSERT_EQUAL_UINT(0, count_evts(EVT_STATE));

    /* The end of the earlier dose is outdated now. */
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    for (int i = 0; i < 40; i++)
        sample_ph(7.6f);
    expect_call_count(0);

    /* Below the target: base (ch 2). */
    write(STOP);
    write(TITRATE);
    clear_log();
    run_until_dose(6.0f);
    expect_call_count(1);
    expect_start(0, CH_BASE, DIR_OUT, dose_steps(FIRST_DOSE_UL));
}

/* LIMIT_OUT during a dose -> error limit ch out, then idle */
static void test_dose_hits_empty_syringe(void)
{
    titrating_with_dose();
    end_motion(CH_ACID, AXIS_LIMIT_OUT, last_tag());
    expect_evt_count(2);
    expect_error(0, ERR_LIMIT, CH_ACID, DIR_OUT, NULL);
    expect_state(1, DEV_IDLE);
    expect_call_count(0); /* the motor stopped by itself */

    clear_log();
    for (int i = 0; i < 40; i++)
        sample_ph(8.0f);
    expect_call_count(0); /* the titration is over */
    expect_evt_count(count_phs());

    /* The same when the switch is active already: the dose is refused. */
    setUp();
    fk.start_result = AXIS_LIMIT_OUT;
    write(TITRATE);
    run_until_dose(6.0f);
    expect_call_count(1);
    expect_start(0, CH_BASE, DIR_OUT, dose_steps(FIRST_DOSE_UL));
    size_t i = find_error(ERR_LIMIT);
    TEST_ASSERT_TRUE(i != NOT_FOUND);
    expect_error(i, ERR_LIMIT, CH_BASE, DIR_OUT, NULL);
    expect_state(i + 1, DEV_IDLE);
    TEST_ASSERT_EQUAL_UINT(i + 2, fk.n_evt); /* the idle is the last event */
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));
}

/* error no_converge, then idle */
static void test_no_converge(void)
{
    write(TITRATE);

    /* 6.0: base, 50 uL. Then 6.96: the response asks for 1 uL, so the smallest dose, 5 uL. */
    run_until_dose(6.0f);
    expect_start(count_calls(CALL_START) - 1, CH_BASE, DIR_OUT, dose_steps(FIRST_DOSE_UL));
    end_motion(CH_BASE, AXIS_DONE, last_tag());
    run_until_dose(6.96f);
    expect_start(count_calls(CALL_START) - 1, CH_BASE, DIR_OUT, dose_steps(MIN_DOSE_UL));
    end_motion(CH_BASE, AXIS_DONE, last_tag());

    /* The pH jumps over the target: acid after a smallest dose of base. */
    clear_log();
    run_until_dose(7.5f);
    size_t i = find_error(ERR_NO_CONVERGE);
    TEST_ASSERT_TRUE(i != NOT_FOUND);
    expect_error(i, ERR_NO_CONVERGE, -1, DIR_IN, NULL);
    expect_state(i + 1, DEV_IDLE);
    TEST_ASSERT_EQUAL_UINT(1, count_evts(EVT_ERROR));
    TEST_ASSERT_EQUAL_UINT(1, count_evts(EVT_STATE));
    expect_call_count(0);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));
}

/* during titration: error sensor then idle; otherwise only the error, motion goes on */
static void test_sensor_fault_events(void)
{
    /* Titrating, a dose under way: the fault stops it, error first. It needs SENSOR_FAULT_MS at the
     * rail, counted from the first window there: the fifth. */
    titrating_with_dose();
    for (int n = 0; n < 10; n++)
        sample_rail();
    TEST_ASSERT_EQUAL_UINT(1, count_errors(ERR_SENSOR)); /* once */
    size_t i = find_error(ERR_SENSOR);
    TEST_ASSERT_EQUAL_UINT(4, i); /* after the `ph` of the first four windows */
    expect_error(i, ERR_SENSOR, -1, DIR_IN, NULL);
    expect_state(i + 1, DEV_IDLE);
    TEST_ASSERT_EQUAL_UINT(1, count_evts(EVT_STATE));
    expect_call_count(1);
    expect_halt(0, CH_ACID);
    TEST_ASSERT_EQUAL_INT(DEV_IDLE, device_state(&dev));

    /* Moving: the error only, the motion goes on and ends in its own way. */
    setUp();
    write(MOVE_1_OUT);
    uint32_t tag = last_tag();
    clear_log();
    for (int n = 0; n < 10; n++)
        sample_rail();
    TEST_ASSERT_EQUAL_UINT(1, count_errors(ERR_SENSOR));
    TEST_ASSERT_EQUAL_UINT(0, count_evts(EVT_STATE));
    expect_call_count(0);
    TEST_ASSERT_EQUAL_INT(DEV_MOVING, device_state(&dev));
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    expect_state(0, DEV_IDLE);

    /* Idle: the error only. A failed read is at the rail, and gives no `ph`. */
    setUp();
    for (int n = 0; n < 4; n++)
        sample_failed();
    expect_evt_count(0); /* 1.5 s: not yet */
    sample_failed();
    expect_evt_count(1);
    expect_error(0, ERR_SENSOR, -1, DIR_IN, NULL);
    for (int n = 0; n < 5; n++)
        sample_failed();
    expect_evt_count(1);

    /* A good window ends the fault; the next one is reported again. */
    sample_ph(7.0f);
    for (int n = 0; n < 5; n++)
        sample_rail();
    TEST_ASSERT_EQUAL_UINT(2, count_errors(ERR_SENSOR));
}

/* one ph per good sample with 2.4 conversion and current cal; none on failed read */
static void test_ph_events(void)
{
    /* Factory calibration: 1000 mV at the ADC is 0 mV at the electrode, pH 7. */
    device_on_sample(&dev, true, FE_BIAS_MV, now);
    expect_evt_count(1);
    TEST_ASSERT_EQUAL_INT(EVT_PH, fk.evt[0].kind);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 7.0f, fk.evt[0].ph.ph);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 0.0f, fk.evt[0].ph.mv);

    /* One slope below: pH 8. */
    clear_log();
    device_on_sample(&dev, true, FE_BIAS_MV + FE_GAIN * CAL_DEFAULT_SLOPE, now);
    expect_evt_count(1);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 8.0f, fk.evt[0].ph.ph);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, CAL_DEFAULT_SLOPE, fk.evt[0].ph.mv);

    /* A failed read has no value to report. */
    clear_log();
    device_on_sample(&dev, false, FE_BIAS_MV, now);
    expect_evt_count(0);

    /* The stored calibration is the one used from now on. */
    write(CAL_SET);
    s_cal = (cal_t){.slope = -57.92f, .offset = 4.35f};
    clear_log();
    sample_ph(6.0f);
    expect_evt_count(1);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 6.0f, fk.evt[0].ph.ph);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 4.35f + 57.92f, fk.evt[0].ph.mv);

    /* In every state. */
    write(MOVE_1_OUT);
    clear_log();
    sample_ph(6.5f);
    expect_evt_count(1);
    TEST_ASSERT_EQUAL_INT(EVT_PH, fk.evt[0].kind);
    write(STOP);
    write(TITRATE);
    clear_log();
    sample_ph(6.5f);
    expect_evt_count(1);
    TEST_ASSERT_EQUAL_INT(EVT_PH, fk.evt[0].kind);
}

/* idle: saved, applied, cal event; save failure still applies; busy otherwise */
static void test_cal_set(void)
{
    write(CAL_SET);
    TEST_ASSERT_EQUAL_INT(1, fk.n_saved);
    TEST_ASSERT_EQUAL_FLOAT(-57.92f, fk.saved.slope);
    TEST_ASSERT_EQUAL_FLOAT(4.35f, fk.saved.offset);
    expect_evt_count(1);
    expect_cal(0, -57.92f, 4.35f);

    /* Saving fails: the device still uses it and tells the app. */
    fk.save_result = false;
    clear_log();
    write("{\"cmd\":\"cal_set\",\"slope\":-55.5,\"offset\":-3}");
    TEST_ASSERT_EQUAL_INT(2, fk.n_saved);
    expect_evt_count(1);
    expect_cal(0, -55.5f, -3.0f);
    s_cal = (cal_t){.slope = -55.5f, .offset = -3.0f};
    clear_log();
    sample_ph(7.5f);
    TEST_ASSERT_FLOAT_WITHIN(0.001f, 7.5f, fk.evt[0].ph.ph);

    /* Not while titrating or moving (see the state table), and not out of range. */
    write(TITRATE);
    assert_busy(CAL_SET);
    write(STOP);
    clear_log();
    write("{\"cmd\":\"cal_set\",\"slope\":-71,\"offset\":0}");
    expect_evt_count(1);
    expect_error(0, ERR_BAD_CMD, -1, DIR_IN, "cal");
    TEST_ASSERT_EQUAL_INT(2, fk.n_saved);
}

/* halt, titration over, idle */
static void test_disconnect_stops(void)
{
    /* Nothing going on: nothing to say. */
    device_on_disconnect(&dev);
    expect_evt_count(0);
    expect_call_count(0);

    write(MOVE_2_OUT);
    clear_log();
    device_on_disconnect(&dev);
    expect_call_count(1);
    expect_halt(0, CH_BASE);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);

    /* A jog: the watchdog has nothing left to stop. */
    write(JOG_1_IN);
    device_on_disconnect(&dev);
    clear_log();
    device_tick(&dev, now + 5 * JOG_TIMEOUT_MS);
    expect_call_count(0);
    expect_evt_count(0);

    /* A titration with a dose under way: halted, over for good. */
    titrating_with_dose();
    uint32_t tag = last_tag();
    device_on_disconnect(&dev);
    expect_call_count(1);
    expect_halt(0, CH_ACID);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
    clear_log();
    end_motion(CH_ACID, AXIS_DONE, tag);
    for (int i = 0; i < 40; i++)
        sample_ph(8.0f);
    expect_call_count(0);
    expect_evt_count(count_phs());

    /* A titration between two doses. */
    write(TITRATE);
    clear_log();
    device_on_disconnect(&dev);
    expect_call_count(0);
    expect_evt_count(1);
    expect_state(0, DEV_IDLE);
}

int main(void)
{
    UNITY_BEGIN();
    RUN_TEST(test_subscribe_reports_state_and_cal);
    RUN_TEST(test_state_table);
    RUN_TEST(test_bad_cmd_with_reason);
    RUN_TEST(test_titrate_and_stop);
    RUN_TEST(test_stop_halts_motion);
    RUN_TEST(test_titrate_refused_on_sensor_fault);
    RUN_TEST(test_move_accumulates);
    RUN_TEST(test_move_switches_motion);
    RUN_TEST(test_move_ends_titration);
    RUN_TEST(test_jog_watchdog);
    RUN_TEST(test_jog_watchdog_across_clock_wrap);
    RUN_TEST(test_move_during_jog_is_noop);
    RUN_TEST(test_jog_takes_over_move);
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
