/*
 * Titration control loop (protocol section 4), the same algorithm as
 * _control/_decide in app/lib/sim/sim_titrator.dart:
 *
 *  1. After the start, a dose or a hold decision, ignore readings for
 *     SETTLE_SKIP_MS, then collect the last SETTLE_N readings. Decide on their
 *     average once they span <= SETTLE_SPAN_PH, or after SETTLE_MAX_MS anyway.
 *  2. |target - pH| <= HOLD_TOL_PH: hold (no dose), wait again.
 *  3. pH above target: acid (ch 1), below: base (ch 2). First dose
 *     FIRST_DOSE_UL. Then gain = how far the last dose moved the pH in its own
 *     direction; gain >= SETTLE_SPAN_PH: DOSE_GAIN * |err| * last / gain,
 *     else 2 * last.
 *  4. Direction differs from the last dose: a reversal. The MAX_REVERSALS-th
 *     reversal, or one right after a MIN_DOSE_UL dose: NO_CONVERGE. Otherwise
 *     halve the dose.
 *  5. Clamp to [MIN_DOSE_UL, MAX_DOSE_UL].
 *
 * One difference from the simulator, where a dose takes no time: the wait of
 * step 1 starts when the dose has been delivered (titr_dose_done).
 *
 * Pure: no I/O, the device executes the actions.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "core/config.h"

typedef enum {
    TITR_WAIT,        /* nothing to do now */
    TITR_DOSE,        /* dispense `ul` on channel `ch`, then call titr_dose_done() */
    TITR_NO_CONVERGE, /* give up: error no_converge, then idle */
} titr_verdict_t;

typedef struct {
    titr_verdict_t verdict;
    uint8_t ch;  /* TITR_DOSE: CH_ACID or CH_BASE */
    float ul;    /* TITR_DOSE: volume */
} titr_action_t;

/* Fields are private to titration.c. */
typedef struct {
    float target;
    bool dosing;              /* a dose is being delivered */
    uint32_t wait_from_ms;    /* start of the current wait */
    float window[SETTLE_N];   /* ring buffer of readings */
    uint8_t window_len;
    uint8_t window_head;
    bool has_last;            /* a dose has been given */
    uint8_t last_ch;
    float last_ul;
    float last_ph;            /* settled reading the last dose was decided on */
    uint8_t reversals;
} titr_t;

/* Starts a titration towards target; the first wait begins now. */
void titr_start(titr_t *t, float target, uint32_t now_ms);

/* Feeds one reading (2 Hz). Ignored (TITR_WAIT) while a dose is delivered. */
titr_action_t titr_on_ph(titr_t *t, float ph, uint32_t now_ms);

/* The dose asked for by the last TITR_DOSE has been delivered. */
void titr_dose_done(titr_t *t, uint32_t now_ms);
