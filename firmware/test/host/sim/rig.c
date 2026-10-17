/*
 * Closed-loop rig, see sim/rig.h.
 *
 * Virtual time in microseconds. The rig jumps from one event to the next:
 *
 *   - a motor: the pulse in the middle of a step period, and the end of the
 *     period, where the "MCPWM interrupt" calls axis_next() with the pulse
 *     count (exactly what platform/stepper.c does on the target);
 *   - an ADC window (SAMPLE_PERIOD_MS), delivered to device_on_sample();
 *   - a tick of the control task (50 ms, CTL_TICK_MS in main.c).
 *
 * Events due at the same instant run in this order: motors, sample, tick.
 * Between events the electrode follows the beaker with a first-order lag,
 * which is exact because the beaker only changes at pulses.
 */
#include "sim/rig.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/axis.h"
#include "core/config.h"
#include "core/ph.h"
#include "sim/beaker.h"

/* The rig does not model the dead travel after a reversal: one pulse, one step. */
_Static_assert(BACKLASH_STEPS == 0, "sim/rig.c assumes no backlash");

#define TICK_US 50000u
#define SAMPLE_US (SAMPLE_PERIOD_MS * 1000u)
#define MAX_EVENTS 8192

/* The true electrode, the same as SimTitrator's. */
#define ELECTRODE_SLOPE (-57.4) /* mV/pH */
#define ELECTRODE_OFFSET 6.5    /* mV at pH 7 */
#define ELECTRODE_TAU_S 1.5
#define ELECTRODE_NOISE_MV 0.25

/* The app's completion rule (protocol 3, lib/core/completion_detector.dart). */
#define DONE_BAND_PH 0.05
#define DONE_HOLD_US 5000000ull

/* Net strong base molarity of the reagent in each syringe. */
static const double REAGENT_MOLAR[CH_COUNT] = {-0.1, 0.1};

/* One MCPWM channel. */
typedef struct {
    bool running;
    dir_t dir;
    uint32_t tag;
    int32_t pulses;           /* what PCNT counts */
    uint64_t period_start_us;
    uint32_t period_us;
    bool pulsed;              /* the pulse of this period is out */
} motor_t;

struct rig {
    device_t device;
    axis_t axis[CH_COUNT];
    motor_t motor[CH_COUNT];
    beaker_t beaker;
    double syringe_ul[CH_COUNT];
    double dispensed_ul[CH_COUNT];
    double probe_ph;           /* what the electrode feels */
    bool fault;
    uint64_t rng;
    uint64_t now_us;
    uint64_t next_sample_us;
    uint64_t next_tick_us;
    evt_t events[MAX_EVENTS];
    size_t n_events;
};

static uint32_t now_ms(const rig_t *r)
{
    return (uint32_t)(r->now_us / 1000);
}

/* ---------------------------------------------------------------- noise */

/* splitmix64 -> uniform in [0, 1) */
static double uniform(rig_t *r)
{
    uint64_t z = (r->rng += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return (double)(z >> 11) / 9007199254740992.0;
}

/* Box-Muller */
static double gaussian(rig_t *r)
{
    return sqrt(-2.0 * log(1.0 - uniform(r))) * cos(2.0 * M_PI * uniform(r));
}

/* ---------------------------------------------------------------- world */

/* The empty-end switch: active when the syringe is empty. */
static bool limit_active(const rig_t *r, uint8_t ch)
{
    return r->syringe_ul[ch] <= 0.0;
}

/* One STEP pulse reaches the plunger. */
static void plunger_step(rig_t *r, uint8_t ch)
{
    double ul = UL_PER_STEP;
    if (r->motor[ch].dir == DIR_IN) {
        r->syringe_ul[ch] += ul;
        return;
    }
    double moved = fmin(ul, r->syringe_ul[ch]); /* an empty syringe cannot go further */
    if (moved <= 0.0)
        return;
    r->syringe_ul[ch] -= moved;
    r->dispensed_ul[ch] += moved;
    beaker_dose(&r->beaker, moved, REAGENT_MOLAR[ch]);
}

/* Moves time forward; the electrode lags behind the beaker meanwhile. */
static void advance_to(rig_t *r, uint64_t t_us)
{
    double dt = (double)(t_us - r->now_us) / 1e6;
    r->probe_ph += (r->beaker.ph - r->probe_ph) * (1.0 - exp(-dt / ELECTRODE_TAU_S));
    r->now_us = t_us;
}

/* ---------------------------------------------------------------- ports */

static void port_emit(void *ctx, const evt_t *evt)
{
    rig_t *r = ctx;
    assert(r->n_events < MAX_EVENTS);
    r->events[r->n_events++] = *evt;
}

static void motor_halt(rig_t *r, uint8_t ch)
{
    motor_t *m = &r->motor[ch];
    if (!m->running)
        return;
    m->running = false;
    axis_finish(&r->axis[ch], m->pulses);
}

static axis_status_t port_motor_start(void *ctx, uint8_t ch, dir_t dir, int32_t steps, uint32_t tag)
{
    rig_t *r = ctx;
    motor_t *m = &r->motor[ch];
    motor_halt(r, ch);

    bool limit = limit_active(r, ch);
    axis_status_t st = axis_start(&r->axis[ch], dir, steps, limit);
    if (st != AXIS_RUNNING)
        return st;

    uint32_t period = axis_next(&r->axis[ch], 0, limit);
    assert(period > 0);
    *m = (motor_t){.running = true, .dir = dir, .tag = tag, .period_start_us = r->now_us,
                   .period_us = period};
    return AXIS_RUNNING;
}

static bool port_motor_extend(void *ctx, uint8_t ch, dir_t dir, int32_t steps)
{
    rig_t *r = ctx;
    return axis_extend(&r->axis[ch], dir, steps);
}

static void port_motor_halt(void *ctx, uint8_t ch)
{
    motor_halt(ctx, ch);
}

static bool port_cal_save(void *ctx, const cal_t *cal)
{
    (void)ctx;
    (void)cal;
    return true;
}

/* --------------------------------------------------------------- events */

/* When the motor does its next thing, or UINT64_MAX when it is stopped. */
static uint64_t motor_due_us(const motor_t *m)
{
    if (!m->running)
        return UINT64_MAX;
    return m->period_start_us + (m->pulsed ? m->period_us : m->period_us / 2);
}

/* The pulse in the middle of a period, or the interrupt at its end. */
static void motor_event(rig_t *r, uint8_t ch)
{
    motor_t *m = &r->motor[ch];
    if (!m->pulsed) {
        m->pulsed = true;
        m->pulses++;
        plunger_step(r, ch);
        return;
    }

    uint32_t period = axis_next(&r->axis[ch], m->pulses, limit_active(r, ch));
    if (period > 0) {
        m->period_start_us += m->period_us;
        m->period_us = period;
        m->pulsed = false;
        return;
    }
    m->running = false;
    axis_finish(&r->axis[ch], m->pulses);
    device_on_motion_end(&r->device, ch, axis_status(&r->axis[ch]), m->tag, now_ms(r));
}

/* One ADC window: electrode with noise, through the front end. */
static void sample_event(rig_t *r)
{
    double mv = ELECTRODE_OFFSET + ELECTRODE_SLOPE * (r->probe_ph - 7.0) +
                ELECTRODE_NOISE_MV * gaussian(r);
    double v_adc = r->fault ? 0.0 : (double)FE_BIAS_MV + (double)FE_GAIN * mv;
    device_on_sample(&r->device, true, (float)v_adc, now_ms(r));
}

/* Runs the next event due at or before until_us. With none, time jumps to
 * until_us and false is returned. */
static bool step(rig_t *r, uint64_t until_us)
{
    uint64_t t = r->next_sample_us < r->next_tick_us ? r->next_sample_us : r->next_tick_us;
    for (uint8_t ch = 0; ch < CH_COUNT; ch++) {
        uint64_t due = motor_due_us(&r->motor[ch]);
        if (due < t)
            t = due;
    }
    if (t > until_us) {
        advance_to(r, until_us);
        return false;
    }

    advance_to(r, t);
    for (uint8_t ch = 0; ch < CH_COUNT; ch++) {
        if (motor_due_us(&r->motor[ch]) == t)
            motor_event(r, ch);
    }
    if (r->next_sample_us == t) {
        r->next_sample_us += SAMPLE_US;
        sample_event(r);
    }
    if (r->next_tick_us == t) {
        r->next_tick_us += TICK_US;
        device_tick(&r->device, now_ms(r));
    }
    return true;
}

/* ------------------------------------------------------------------ API */

rig_t *rig_create(const rig_cfg_t *cfg)
{
    rig_t *r = calloc(1, sizeof *r);
    if (!r)
        return NULL;
    r->rng = cfg->seed;
    r->next_sample_us = SAMPLE_US;
    r->next_tick_us = TICK_US;
    beaker_init(&r->beaker, cfg->sample_ph, cfg->buffered);
    r->probe_ph = cfg->sample_ph;

    const axis_cfg_t axis_cfg = {
        .v_start = V_START_SPS,
        .v_max = V_MAX_SPS,
        .accel = ACCEL_SPS2,
        .stroke = STROKE_STEPS,
        .backlash = BACKLASH_STEPS,
        .limit_debounce = LIMIT_DEBOUNCE,
    };
    for (uint8_t ch = 0; ch < CH_COUNT; ch++) {
        axis_init(&r->axis[ch], &axis_cfg);
        r->syringe_ul[ch] = cfg->syringe_ul[ch];
    }

    const device_ports_t ports = {
        .ctx = r,
        .emit = port_emit,
        .motor_start = port_motor_start,
        .motor_extend = port_motor_extend,
        .motor_halt = port_motor_halt,
        .cal_save = port_cal_save,
    };
    cal_t cal = ph_cal_default();
    device_init(&r->device, &ports, &cal);

    if (cfg->calibrated) {
        char json[96];
        snprintf(json, sizeof json, "{\"cmd\":\"cal_set\",\"slope\":%.2f,\"offset\":%.2f}",
                 ELECTRODE_SLOPE, ELECTRODE_OFFSET);
        rig_write(r, json);
    }
    return r;
}

void rig_destroy(rig_t *r)
{
    free(r);
}

void rig_write(rig_t *r, const char *json)
{
    device_on_write(&r->device, json, strlen(json), now_ms(r));
}

void rig_run(rig_t *r, uint32_t ms)
{
    uint64_t until_us = r->now_us + (uint64_t)ms * 1000;
    while (step(r, until_us))
        ;
}

rig_result_t rig_titrate(rig_t *r, double target, uint32_t max_ms)
{
    const uint64_t start_us = r->now_us;
    const uint64_t end_us = start_us + (uint64_t)max_ms * 1000;
    const size_t first_event = r->n_events;
    double dispensed0[CH_COUNT];
    memcpy(dispensed0, r->dispensed_ul, sizeof dispensed0);

    /* The app: subscribe, then titrate. */
    device_on_subscribe(&r->device);
    char json[64];
    snprintf(json, sizeof json, "{\"cmd\":\"titrate\",\"target\":%.2f}", target);
    rig_write(r, json);

    rig_result_t res = {0};
    size_t seen = first_event;
    bool in_band = false;
    uint64_t in_band_since_us = 0;
    while (!res.completed && device_state(&r->device) != DEV_IDLE && r->now_us < end_us) {
        step(r, end_us);
        for (; seen < r->n_events; seen++) {
            const evt_t *e = &r->events[seen];
            if (e->kind != EVT_PH)
                continue;
            double ph = round((double)e->ph.ph * 100.0) / 100.0; /* the app reads 2 decimals */
            if (fabs(ph - target) > DONE_BAND_PH + 1e-9) {
                in_band = false;
                continue;
            }
            if (!in_band) {
                in_band = true;
                in_band_since_us = r->now_us;
            }
            if (r->now_us - in_band_since_us >= DONE_HOLD_US)
                res.completed = true;
        }
    }
    if (res.completed)
        rig_write(r, "{\"cmd\":\"stop\"}");

    res.elapsed_ms = (uint32_t)((r->now_us - start_us) / 1000);
    for (size_t i = first_event; i < r->n_events; i++) {
        if (r->events[i].kind == EVT_ERROR)
            res.errors[r->events[i].error.code]++;
    }
    for (uint8_t ch = 0; ch < CH_COUNT; ch++)
        res.used_ul[ch] = r->dispensed_ul[ch] - dispensed0[ch];
    res.true_ph = r->beaker.ph;
    res.final_state = device_state(&r->device);
    return res;
}

void rig_set_fault(rig_t *r, bool fault)
{
    r->fault = fault;
}

dev_state_t rig_state(const rig_t *r)
{
    return device_state(&r->device);
}

size_t rig_event_count(const rig_t *r)
{
    return r->n_events;
}

const evt_t *rig_event(const rig_t *r, size_t i)
{
    return i < r->n_events ? &r->events[i] : NULL;
}

double rig_syringe_ul(const rig_t *r, uint8_t ch)
{
    return r->syringe_ul[ch];
}

const axis_t *rig_axis(const rig_t *r, uint8_t ch)
{
    return &r->axis[ch];
}
