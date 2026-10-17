/* Beaker model, see sim/beaker.h. TODO(WP4): port _Beaker from sim_titrator.dart. */
#include "sim/beaker.h"

void beaker_init(beaker_t *b, double ph, bool buffered)
{
    *b = (beaker_t){.buffered = buffered, .volume_l = 0.050, .ph = ph};
}

void beaker_dose(beaker_t *b, double ul, double molar)
{
    (void)b;
    (void)ul;
    (void)molar;
}
