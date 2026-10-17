/* Titration control loop, see core/titration.h. TODO(WP3): implement. */
#include "core/titration.h"

void titr_start(titr_t *t, float target, uint32_t now_ms)
{
    *t = (titr_t){.target = target, .wait_from_ms = now_ms};
}

titr_action_t titr_on_ph(titr_t *t, float ph, uint32_t now_ms)
{
    (void)t;
    (void)ph;
    (void)now_ms;
    return (titr_action_t){.verdict = TITR_WAIT};
}

void titr_dose_done(titr_t *t, uint32_t now_ms)
{
    (void)t;
    (void)now_ms;
}
