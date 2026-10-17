/*
 * Firmware constants: mechanics, motion, measurement, titration.
 *
 * Units are in the names: _MS milliseconds, _UL microlitres, _SPS steps per
 * second, _SPS2 steps per second squared, _MV millivolts, _PH pH units.
 * "Steps" are microsteps as seen on the STEP pin.
 *
 * [待确认] marks values that depend on hardware nobody has measured yet; see
 * DESIGN.md "待确认清单". Board wiring (GPIOs, ADC channel) lives in
 * platform/board.h, not here.
 */
#pragma once

#include <stdint.h>

/* ------------------------------------------------- syringe drive [待确认] */

#define MOTOR_FULL_STEPS 200     /* 1.8 degree 42 stepper */
#define MICROSTEPS 16            /* TMC2209 MS1 = MS2 = VIO */
#define LEAD_MM 8.0f             /* lead screw travel per revolution (T8x8) */
#define SYRINGE_UL_PER_MM 165.0f /* 10 mL syringe, inner diameter ~14.5 mm */
#define STROKE_MM 58.0f          /* usable travel from the empty-end switch */

#define STEPS_PER_MM ((float)(MOTOR_FULL_STEPS * MICROSTEPS) / LEAD_MM) /* 400 */
#define UL_PER_STEP (SYRINGE_UL_PER_MM / STEPS_PER_MM)                  /* 0.4125 uL */
#define STROKE_STEPS ((int32_t)(STROKE_MM * STEPS_PER_MM))              /* 23200: soft limit of "in" */

/* One `move` (protocol 2.1); the simulator uses the same volume. */
#define MOVE_UL 50.0f
#define MOVE_STEPS ((int32_t)(MOVE_UL / UL_PER_STEP + 0.5f)) /* 121 */

/* ------------------------------------------------------- motion profile */

#define PUMP_UL_PER_S 500.0f                                     /* top speed, 0.5 mL/s like the simulator */
#define V_MAX_SPS ((uint32_t)(PUMP_UL_PER_S / UL_PER_STEP))     /* 1212 steps/s = 0.38 rev/s */
#define V_START_SPS 400u                                         /* start/stop speed, no ramp below it */
#define ACCEL_SPS2 8000u                                         /* 400 -> 1212 steps/s in 0.1 s */
#define BACKLASH_STEPS 0u   /* uncounted steps after a direction reversal [待实测] */
#define LIMIT_DEBOUNCE 2u   /* consecutive active samples (one per step) that confirm the switch */

/* A `jog` stops when no new `jog` arrived for this long (protocol 2.1). */
#define JOG_TIMEOUT_MS 1000u

/* ------------------------------------------- pH measurement (protocol 2.4) */

/* One `ph` event per window; the ADC averages over the whole window, which
 * also cancels 50 Hz and 60 Hz mains pickup (25 / 30 full cycles). */
#define SAMPLE_PERIOD_MS 500u

/* Front end: PH-4502C (5 V) Po -> 15k/10k divider -> ESP32-S3 ADC1.
 * Po ~= 2.5 V + 3.0 * E_electrode, i.e. about -0.18 V/pH and 2.5 V at pH 7
 * once the reference potentiometer is set. */
#define FE_MODULE_GAIN 3.0f                      /* PH-4502C Po per electrode volt [待实测] */
#define FE_DIVIDER 0.4f                          /* 10k / (15k + 10k) [待确认] */
#define FE_GAIN (FE_MODULE_GAIN * FE_DIVIDER)    /* 1.2: ADC mV per electrode mV */
#define FE_BIAS_MV 1000.0f                       /* ADC mV with the BNC shorted: 2.5 V * 0.4 [待实测] */

/* `sensor` fault (protocol 3): the ADC reading sits outside this window for
 * SENSOR_FAULT_MS. Low end: Po 0.375 V, impossible for a working electrode.
 * High end: Po 3.45 V, just below the PH-4502C op-amp saturation (~3.5 V at a
 * 5 V supply), i.e. readings below ~pH 1.6 count as a fault. [待实测] */
#define SENSOR_RAIL_LO_MV 150.0f
#define SENSOR_RAIL_HI_MV 1380.0f
#define SENSOR_FAULT_MS 2000u

/* ------------------------------------------------ calibration (protocol 2) */

#define CAL_DEFAULT_SLOPE (-59.16f) /* ideal electrode at 25 C */
#define CAL_DEFAULT_OFFSET 0.0f
#define CAL_SLOPE_MIN (-70.0f)
#define CAL_SLOPE_MAX (-40.0f)
#define CAL_OFFSET_MIN (-100.0f)
#define CAL_OFFSET_MAX 100.0f

#define TARGET_PH_MIN 0.0f
#define TARGET_PH_MAX 14.0f

/* ------------------------------------- titration loop (protocol section 4)
 * Same values and names as app/lib/sim/sim_titrator.dart. */

#define SETTLE_SKIP_MS 2000u   /* readings this soon after a dose or decision are ignored */
#define SETTLE_N 8u            /* window of readings (4 s) */
#define SETTLE_SPAN_PH 0.03f   /* settled when the window spans no more than this; also the
                                  smallest usable response of a dose */
#define SETTLE_MAX_MS 30000u   /* then go on with the window average anyway */
#define HOLD_TOL_PH 0.02f      /* no dose this close to the target; < app completion band 0.05 */
#define FIRST_DOSE_UL 50.0f
#define MIN_DOSE_UL 5.0f
#define MAX_DOSE_UL 500.0f
#define DOSE_GAIN 0.5f         /* fraction of the volume the last response says is needed */
#define MAX_REVERSALS 3u       /* no_converge at this many direction reversals */
