/*
 * Beaker model, see sim/beaker.h: a C port of _Beaker in
 * app/lib/sim/sim_titrator.dart. The pH follows from the charge balance
 *
 *   [H+] + (base - dissociated) / V - Kw / [H+] = 0
 *
 * where `dissociated` is the amount of weak-acid anions at that [H+]. The
 * left side falls strictly with pH, so bisection finds the root.
 */
#include "sim/beaker.h"

#include <math.h>

#define KW 1e-14
#define ACID_COUNT 3
#define ACID_MOL (0.005 * 0.050) /* 5 mM of each weak acid in the first 50 mL */

static const double PKA[ACID_COUNT] = {4.76, 7.20, 9.25};

/* Moles of weak-acid anions at hydrogen ion concentration h. */
static double dissociated(const beaker_t *b, double h)
{
    if (!b->buffered)
        return 0.0;
    double mol = 0.0;
    for (int i = 0; i < ACID_COUNT; i++) {
        double ka = pow(10.0, -PKA[i]);
        mol += ACID_MOL * ka / (ka + h);
    }
    return mol;
}

/* Charge balance residual at pH ph. */
static double charge(const beaker_t *b, double ph)
{
    double h = pow(10.0, -ph);
    return h + (b->base_mol - dissociated(b, h)) / b->volume_l - KW / h;
}

/* Bisection on pH 0..14; a sample beyond that range clamps to its ends. */
static double solve(const beaker_t *b)
{
    double lo = 0.0, hi = 14.0;
    for (int i = 0; i < 50; i++) {
        double mid = (lo + hi) / 2;
        if (charge(b, mid) > 0)
            lo = mid;
        else
            hi = mid;
    }
    return (lo + hi) / 2;
}

void beaker_init(beaker_t *b, double ph, bool buffered)
{
    *b = (beaker_t){.buffered = buffered, .volume_l = 0.050, .ph = ph};
    double h = pow(10.0, -ph);
    b->base_mol = b->volume_l * (KW / h - h) + dissociated(b, h);
}

void beaker_dose(beaker_t *b, double ul, double molar)
{
    b->volume_l += ul / 1e6;
    b->base_mol += ul / 1e6 * molar;
    b->ph = solve(b);
}
