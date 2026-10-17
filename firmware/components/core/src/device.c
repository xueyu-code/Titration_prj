/* Device behaviour, see core/device.h. The firmware counterpart of
 * SimTitrator in app/lib/sim/sim_titrator.dart; DESIGN.md "状态机". */
#include "core/device.h"

#include "core/clog.h"
#include "core/config.h"
#include "core/ph.h"

static const char *TAG = "device";

static const char *const STATE_NAME[] = {
    [DEV_IDLE] = "idle",
    [DEV_TITRATING] = "titrating",
    [DEV_MOVING] = "moving",
};

/* --------------------------------------------------------------- events */

static void emit(const device_t *d, const evt_t *evt)
{
    d->ports.emit(d->ports.ctx, evt);
}

static void emit_state(const device_t *d)
{
    emit(d, &(evt_t){.kind = EVT_STATE, .state = d->state});
}

static void emit_cal(const device_t *d)
{
    emit(d, &(evt_t){.kind = EVT_CAL, .cal = d->cal});
}

/* ch < 0: an error without channel and direction. */
static void emit_error(const device_t *d, err_code_t code, int8_t ch, dir_t dir, const char *msg)
{
    emit(d, &(evt_t){.kind = EVT_ERROR, .error = {.code = code, .ch = ch, .dir = dir, .msg = msg}});
}

/* ---------------------------------------------------------------- state */

/* `state` is only sent when it changes. */
static void set_state(device_t *d, dev_state_t state)
{
    if (state == d->state)
        return;
    d->state = state;
    CLOGI(TAG, "state %s", STATE_NAME[state]);
    emit_state(d);
}

static void halt_motion(device_t *d)
{
    if (d->motion.kind == MOTION_NONE)
        return;
    d->ports.motor_halt(d->ports.ctx, d->motion.ch);
    d->motion.kind = MOTION_NONE;
}

/* Stops everything. A titration is over once the state is not titrating. */
static void go_idle(device_t *d)
{
    halt_motion(d);
    set_state(d, DEV_IDLE);
}

/* The motion was refused: say why, then idle. */
static void refuse(device_t *d, uint8_t ch, dir_t dir, axis_status_t st)
{
    CLOGI(TAG, "ch %u refused %s: status %d", (unsigned)ch + 1u, dir == DIR_IN ? "in" : "out", (int)st);
    emit_error(d, st == AXIS_UNHOMED ? ERR_UNHOMED : ERR_LIMIT, (int8_t)ch, dir, NULL);
    set_state(d, DEV_IDLE);
}

/* Starts a motion (the previous one has been halted). On a refusal the error
 * and idle are sent and false is returned. */
static bool start_motion(device_t *d, motion_kind_t kind, uint8_t ch, dir_t dir, int32_t steps,
                         uint32_t now_ms)
{
    uint32_t tag = ++d->next_tag;
    axis_status_t st = d->ports.motor_start(d->ports.ctx, ch, dir, steps, tag);

    if (st != AXIS_RUNNING) {
        refuse(d, ch, dir, st);
        return false;
    }
    d->motion.kind = kind;
    d->motion.ch = ch;
    d->motion.dir = dir;
    d->motion.tag = tag;
    d->motion.jog_deadline_ms = now_ms + JOG_TIMEOUT_MS;
    return true;
}

/* ----------------------------------------------------------- move / jog */

/* A move or jog in the direction of the running move or jog adds to it.
 * False: there is nothing to add to, the caller starts a new motion. */
static bool join_motion(device_t *d, uint8_t ch, dir_t dir, bool jog, uint32_t now_ms)
{
    if ((d->motion.kind != MOTION_MOVE && d->motion.kind != MOTION_JOG) || d->motion.ch != ch ||
        d->motion.dir != dir)
        return false;

    if (d->motion.kind == MOTION_JOG) { /* a jog goes on; a move does not change it */
        if (jog)
            d->motion.jog_deadline_ms = now_ms + JOG_TIMEOUT_MS;
        return true;
    }
    /* A move: false when it has just ended (its end is still on its way). */
    if (!d->ports.motor_extend(d->ports.ctx, ch, dir, jog ? AXIS_CONTINUOUS : MOVE_STEPS))
        return false;
    if (jog) {
        d->motion.kind = MOTION_JOG;
        d->motion.jog_deadline_ms = now_ms + JOG_TIMEOUT_MS;
    }
    return true;
}

/* Anything else ends the current activity, a titration included (no error). */
static void drive(device_t *d, uint8_t ch, dir_t dir, bool jog, uint32_t now_ms)
{
    if (join_motion(d, ch, dir, jog, now_ms))
        return;
    halt_motion(d);
    if (start_motion(d, jog ? MOTION_JOG : MOTION_MOVE, ch, dir, jog ? AXIS_CONTINUOUS : MOVE_STEPS,
                     now_ms))
        set_state(d, DEV_MOVING);
}

/* ------------------------------------------------------------ titration */

/* Carries out what the control loop decided. */
static void act(device_t *d, const titr_action_t *a, uint32_t now_ms)
{
    switch (a->verdict) {
    case TITR_WAIT:
        break;
    case TITR_DOSE: {
        int32_t steps = (int32_t)(a->ul / UL_PER_STEP + 0.5f);
        start_motion(d, MOTION_DOSE, a->ch, DIR_OUT, steps < 1 ? 1 : steps, now_ms);
        break;
    }
    case TITR_NO_CONVERGE:
        emit_error(d, ERR_NO_CONVERGE, -1, DIR_IN, NULL);
        go_idle(d);
        break;
    }
}

/* ------------------------------------------------------------------ API */

void device_init(device_t *d, const device_ports_t *ports, const cal_t *cal)
{
    *d = (device_t){.ports = *ports, .state = DEV_IDLE, .cal = *cal};
    sensor_fault_init(&d->sensor);
}

void device_on_write(device_t *d, const char *data, size_t len, uint32_t now_ms)
{
    cmd_t cmd;
    const char *bad = proto_parse_cmd(data, len, &cmd);

    if (bad) {
        CLOGI(TAG, "bad command: %s", bad);
        emit_error(d, ERR_BAD_CMD, -1, DIR_IN, bad);
        return;
    }
    if (d->state != DEV_IDLE && (cmd.kind == CMD_TITRATE || cmd.kind == CMD_CAL_SET)) {
        emit_error(d, ERR_BUSY, -1, DIR_IN, NULL);
        return;
    }

    switch (cmd.kind) {
    case CMD_TITRATE:
        if (sensor_fault_active(&d->sensor)) {
            emit_error(d, ERR_SENSOR, -1, DIR_IN, NULL);
            return;
        }
        CLOGI(TAG, "titrate to pH %.2f", (double)cmd.target);
        titr_start(&d->titr, cmd.target, now_ms);
        set_state(d, DEV_TITRATING);
        break;
    case CMD_STOP:
        go_idle(d);
        break;
    case CMD_MOVE:
    case CMD_JOG:
        drive(d, cmd.motion.ch, cmd.motion.dir, cmd.kind == CMD_JOG, now_ms);
        break;
    case CMD_CAL_SET:
        d->cal = cmd.cal; /* applied even when it cannot be saved */
        if (!d->ports.cal_save(d->ports.ctx, &d->cal))
            CLOGW(TAG, "calibration not saved");
        CLOGI(TAG, "calibration slope %.2f, offset %.2f", (double)d->cal.slope, (double)d->cal.offset);
        emit_cal(d);
        break;
    }
}

void device_on_subscribe(device_t *d)
{
    emit_state(d);
    emit_cal(d);
}

void device_on_disconnect(device_t *d)
{
    CLOGI(TAG, "disconnected");
    go_idle(d);
}

void device_on_sample(device_t *d, bool read_ok, float v_adc_mv, uint32_t now_ms)
{
    /* The fault first, like the simulator: a titration it ends does not
     * dose on this reading. */
    if (sensor_fault_update(&d->sensor, sensor_fault_at_rail(read_ok, v_adc_mv), now_ms)) {
        CLOGI(TAG, "sensor fault");
        emit_error(d, ERR_SENSOR, -1, DIR_IN, NULL);
        if (d->state == DEV_TITRATING)
            go_idle(d);
    }
    if (!read_ok)
        return;

    float mv = ph_electrode_mv(v_adc_mv);
    float ph = ph_from_mv(&d->cal, mv);
    emit(d, &(evt_t){.kind = EVT_PH, .ph = {.ph = ph, .mv = mv}});

    if (d->state == DEV_TITRATING) {
        titr_action_t a = titr_on_ph(&d->titr, ph, now_ms);
        act(d, &a, now_ms);
    }
}

void device_on_motion_end(device_t *d, uint8_t ch, axis_status_t st, uint32_t tag, uint32_t now_ms)
{
    /* The end of a motion that is already over (stopped, replaced). */
    if (d->motion.kind == MOTION_NONE || ch != d->motion.ch || tag != d->motion.tag)
        return;

    motion_kind_t kind = d->motion.kind;
    dir_t dir = d->motion.dir;
    d->motion.kind = MOTION_NONE;

    if (st == AXIS_LIMIT_OUT || st == AXIS_LIMIT_IN) {
        CLOGI(TAG, "ch %u reached the %s limit", (unsigned)ch + 1u, st == AXIS_LIMIT_OUT ? "empty" : "full");
        emit_error(d, ERR_LIMIT, (int8_t)ch, dir, NULL);
        set_state(d, DEV_IDLE);
    } else if (kind == MOTION_DOSE) { /* AXIS_DONE: the titration goes on */
        titr_dose_done(&d->titr, now_ms);
    } else {
        set_state(d, DEV_IDLE);
    }
}

void device_tick(device_t *d, uint32_t now_ms)
{
    /* Compared as a difference: the clock wraps. */
    if (d->motion.kind == MOTION_JOG && (int32_t)(now_ms - d->motion.jog_deadline_ms) >= 0) {
        CLOGI(TAG, "jog timed out");
        go_idle(d);
    }
}
