/* Titration control loop, see core/titration.h. Mirrors _control/_decide in
 * app/lib/sim/sim_titrator.dart. */
#include "core/titration.h"

#include <math.h>

#include "core/clog.h"
#include "core/types.h"

static const char *TAG = "titr";

/* Restarts the wait for a settled reading. */
static void start_wait(titr_t *t, uint32_t now_ms)
{
    t->wait_from_ms = now_ms;
    t->window_len = 0;
    t->window_head = 0;
}

/* The ring buffer fills from index 0, so the first window_len slots are the
 * last readings in both the filling and the full state. */
static void window_push(titr_t *t, float ph)
{
    t->window[t->window_head] = ph;
    t->window_head = (uint8_t)((t->window_head + 1u) % SETTLE_N);
    if (t->window_len < SETTLE_N)
        t->window_len++;
}

/* Span (max - min) of the window; *mean gets its average. window_len >= 1. */
static float window_stats(const titr_t *t, float *mean)
{
    float lo = t->window[0];
    float hi = lo;
    float sum = 0.0f;

    for (uint8_t i = 0; i < t->window_len; i++) {
        float v = t->window[i];
        if (v < lo)
            lo = v;
        if (v > hi)
            hi = v;
        sum += v;
    }
    *mean = sum / (float)t->window_len;
    return hi - lo;
}

/* Holds or doses at the settled reading ph. The dose is half the volume the
 * last dose's response says is needed, halved again after a reversal; without
 * a usable response it is twice the last dose. */
static titr_action_t decide(titr_t *t, float ph, uint32_t now_ms)
{
    start_wait(t, now_ms);
    float err = t->target - ph;
    if (fabsf(err) <= HOLD_TOL_PH) {
        CLOGI(TAG, "hold: pH %.2f, err %.2f", (double)ph, (double)err);
        return (titr_action_t){.verdict = TITR_WAIT};
    }

    uint8_t ch = err > 0.0f ? CH_BASE : CH_ACID;
    float ul = FIRST_DOSE_UL;
    if (t->has_last) {
        /* Gain: how far the last dose moved the pH in the direction it pushes. */
        float gain = (t->last_ch == CH_BASE ? 1.0f : -1.0f) * (ph - t->last_ph);
        ul = gain >= SETTLE_SPAN_PH ? DOSE_GAIN * fabsf(err) * t->last_ul / gain : 2.0f * t->last_ul;
        if (t->last_ch != ch) {
            if (++t->reversals >= MAX_REVERSALS || t->last_ul <= MIN_DOSE_UL) {
                CLOGI(TAG, "no convergence: pH %.2f, %u reversals", (double)ph, (unsigned)t->reversals);
                return (titr_action_t){.verdict = TITR_NO_CONVERGE};
            }
            ul /= 2.0f;
        }
    }
    if (ul < MIN_DOSE_UL)
        ul = MIN_DOSE_UL;
    else if (ul > MAX_DOSE_UL)
        ul = MAX_DOSE_UL;

    CLOGI(TAG, "dose: pH %.2f, err %.2f, ch %u, %.1f uL, %u reversals", (double)ph, (double)err,
          (unsigned)ch + 1u, (double)ul, (unsigned)t->reversals);
    t->has_last = true;
    t->last_ch = ch;
    t->last_ul = ul;
    t->last_ph = ph;
    t->dosing = true;
    return (titr_action_t){.verdict = TITR_DOSE, .ch = ch, .ul = ul};
}

void titr_start(titr_t *t, float target, uint32_t now_ms)
{
    *t = (titr_t){.target = target, .wait_from_ms = now_ms};
}

titr_action_t titr_on_ph(titr_t *t, float ph, uint32_t now_ms)
{
    const titr_action_t wait = {.verdict = TITR_WAIT};

    if (t->dosing)
        return wait;
    uint32_t waited = now_ms - t->wait_from_ms;
    if (waited < SETTLE_SKIP_MS)
        return wait;

    window_push(t, ph);
    float mean;
    float span = window_stats(t, &mean);
    bool settled = t->window_len == SETTLE_N && span <= SETTLE_SPAN_PH;
    if (!settled && waited < SETTLE_MAX_MS)
        return wait;
    return decide(t, mean, now_ms);
}

void titr_dose_done(titr_t *t, uint32_t now_ms)
{
    t->dosing = false;
    start_wait(t, now_ms);
}
