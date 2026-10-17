/*
 * Closed-loop test rig: the real device (core/device.c with core/axis.c and
 * core/titration.c) against a simulated world, in virtual time.
 *
 *  - Ports: emit records events; motor_* drive two real axis_t, stepped at the
 *    periods axis_next() returns (that is what MCPWM does on the target); the
 *    pulse count is exact. Each counted "out" step moves UL_PER_STEP of
 *    reagent into the beaker; the limit switch is active when the syringe is
 *    empty. cal_save just succeeds.
 *  - Electrode: true slope -57.4 mV/pH, offset +6.5 mV, first-order lag
 *    tau 1.5 s, Gaussian noise 0.25 mV (seeded); front end
 *    V_adc = FE_BIAS_MV + FE_GAIN * mv; with the fault set, V_adc sits at
 *    0 mV. One device_on_sample() every SAMPLE_PERIOD_MS.
 *  - device_tick() every 50 ms, like the control task.
 *  - Reagents: ch 1 0.1 M acid, ch 2 0.1 M base.
 *  - rig_titrate() plays the app: subscribe, send titrate, and send stop once
 *    the device's own readings stayed within 0.05 pH of the target for 5 s
 *    (protocol 3, completion is decided by the app).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "core/device.h"
#include "core/protocol.h"
#include "core/types.h"

typedef struct {
    double sample_ph;              /* start pH of the 50 mL sample */
    bool buffered;
    double syringe_ul[CH_COUNT];   /* initial contents; the axes start unhomed */
    uint32_t seed;                 /* noise */
    bool calibrated;               /* send cal_set with the true electrode first */
} rig_cfg_t;

typedef struct {
    bool completed;                /* the app's completion rule fired */
    uint32_t elapsed_ms;
    int errors[ERR_COUNT];         /* error events by code */
    double used_ul[CH_COUNT];      /* reagent dispensed */
    double true_ph;                /* sample pH at the end */
    dev_state_t final_state;
} rig_result_t;

typedef struct rig rig_t;

rig_t *rig_create(const rig_cfg_t *cfg);
void rig_destroy(rig_t *r);

/* App -> device: one CMD write (a JSON string). */
void rig_write(rig_t *r, const char *json);

/* Advances virtual time. */
void rig_run(rig_t *r, uint32_t ms);

/* Subscribes, titrates to target like the app, until the app stops it, the
 * device goes idle by itself, or max_ms passed. */
rig_result_t rig_titrate(rig_t *r, double target, uint32_t max_ms);

/* Electrode / front-end fault on or off from now on. */
void rig_set_fault(rig_t *r, bool fault);

/* Inspection. */
dev_state_t rig_state(const rig_t *r);
size_t rig_event_count(const rig_t *r);
const evt_t *rig_event(const rig_t *r, size_t i);
double rig_syringe_ul(const rig_t *r, uint8_t ch);
const axis_t *rig_axis(const rig_t *r, uint8_t ch);
