/*
 * The device behaviour of docs/protocol.md section 3: state machine, command
 * handling, jog watchdog, titration orchestration, sensor fault, events.
 * The firmware counterpart of SimTitrator in app/lib/sim/sim_titrator.dart.
 *
 * Single-threaded: every device_* call comes from the control task (or the
 * host test). Hardware is reached only through device_ports_t, so the whole
 * module runs on the host against fakes.
 *
 * Rules the implementation must keep (details in DESIGN.md "状态机"):
 *  - A write is parsed first (bad -> error bad_cmd + msg), then checked
 *    against the state (idle: all; titrating/moving: stop, move, jog; else
 *    error busy).
 *  - titrate: error sensor while the sensor fault is active; else state
 *    titrating.
 *  - move/jog: the same channel and direction as the running move/jog adds to
 *    it (move: +MOVE_STEPS, jog: refresh the watchdog, a move during a jog
 *    changes nothing); anything else ends the current activity first. A
 *    refused motion (unhomed / limit) emits the error with ch/dir, then state
 *    idle.
 *  - The device stopping by itself (limit, no_converge, sensor during a
 *    titration) emits `error` first, then `state: idle`. A sensor fault
 *    outside a titration only emits the error; a motion goes on.
 *  - `state` is emitted only on change, plus once on subscribe (with `cal`).
 *  - Disconnect stops everything.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "core/axis.h"
#include "core/protocol.h"
#include "core/sensor_fault.h"
#include "core/titration.h"
#include "core/types.h"

/* What the device needs from the outside world. Every call is synchronous
 * and made from the device's own thread. */
typedef struct {
    void *ctx;

    /* Sends one event to the app (drop silently when nobody listens). */
    void (*emit)(void *ctx, const evt_t *evt);

    /* Starts a motion of channel ch: `steps` counted steps or AXIS_CONTINUOUS.
     * Returns AXIS_RUNNING, or the refusal AXIS_UNHOMED / AXIS_LIMIT_IN /
     * AXIS_LIMIT_OUT (nothing moves). `tag` comes back with the end of this
     * motion through device_on_motion_end(). */
    axis_status_t (*motor_start)(void *ctx, uint8_t ch, dir_t dir, int32_t steps, uint32_t tag);

    /* Adds steps (or AXIS_CONTINUOUS) to the running motion of ch in dir.
     * False when it is not running in dir any more. */
    bool (*motor_extend)(void *ctx, uint8_t ch, dir_t dir, int32_t steps);

    /* Stops ch at once. No motion end is reported for it. */
    void (*motor_halt)(void *ctx, uint8_t ch);

    /* Persists the calibration. False on failure; it is applied anyway. */
    bool (*cal_save)(void *ctx, const cal_t *cal);
} device_ports_t;

typedef enum {
    MOTION_NONE,
    MOTION_MOVE,
    MOTION_JOG,
    MOTION_DOSE,
} motion_kind_t;

/* Fields are private to device.c. */
typedef struct {
    device_ports_t ports;
    dev_state_t state;
    cal_t cal;
    sensor_fault_t sensor;
    titr_t titr;
    struct {
        motion_kind_t kind;
        uint8_t ch;
        dir_t dir;
        uint32_t tag;
        uint32_t jog_deadline_ms;
    } motion;          /* at most one motion at a time */
    uint32_t next_tag;
} device_t;

/* Idle, nothing moving, calibration cal (already validated). */
void device_init(device_t *d, const device_ports_t *ports, const cal_t *cal);

/* One CMD write of len bytes (len > PROTO_MAX_MSG means it was too long). */
void device_on_write(device_t *d, const char *data, size_t len, uint32_t now_ms);

/* The app enabled EVT notifications: emit `state` and `cal`. */
void device_on_subscribe(device_t *d);

/* The connection is gone: stop everything, idle. */
void device_on_disconnect(device_t *d);

/* One averaged ADC window (SAMPLE_PERIOD_MS). read_ok false: the ADC failed,
 * no `ph` event; it counts as being at the rail. */
void device_on_sample(device_t *d, bool read_ok, float v_adc_mv, uint32_t now_ms);

/* A motion started with `tag` ended by itself (AXIS_DONE, AXIS_LIMIT_OUT,
 * AXIS_LIMIT_IN). Ends with an outdated tag are ignored. */
void device_on_motion_end(device_t *d, uint8_t ch, axis_status_t st, uint32_t tag, uint32_t now_ms);

/* Periodic call (CTL_TICK_MS): the jog watchdog. */
void device_tick(device_t *d, uint32_t now_ms);

static inline dev_state_t device_state(const device_t *d) { return d->state; }
