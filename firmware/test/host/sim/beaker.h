/*
 * The sample in the beaker: strong acid/base reagents added to plain water or
 * to a mix of three weak-acid buffers (pKa 4.76, 7.20, 9.25; 5 mM each in
 * 50 mL). pH from the charge balance by bisection on 0..14.
 * A C port of _Beaker in app/lib/sim/sim_titrator.dart; double precision.
 */
#pragma once

#include <stdbool.h>

typedef struct {
    bool buffered;
    double volume_l; /* starts at 0.050 */
    double base_mol; /* net strong base (base - acid), negative when acidic */
    double ph;
} beaker_t;

/* A 50 mL sample at pH ph: the net strong base is whatever balances it. */
void beaker_init(beaker_t *b, double ph, bool buffered);

/* Adds ul microlitres of reagent with net strong base molarity molar
 * (acid reagent < 0); updates ph. */
void beaker_dose(beaker_t *b, double ul, double molar);
