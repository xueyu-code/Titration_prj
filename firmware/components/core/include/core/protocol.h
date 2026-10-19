/*
 * Wire format of docs/protocol.md v4: one UTF-8 JSON object per CMD write or
 * EVT notification. Parsing uses cJSON (robust against arbitrary input);
 * encoding uses snprintf (fixed shapes, no heap, exact decimals).
 */
#pragma once

#include <stddef.h>

#include "core/types.h"

/* Longest write or notification in bytes (protocol section 1). */
#define PROTO_MAX_MSG 100

/* ------------------------------------------------------------- commands */

typedef enum {
    CMD_TITRATE,
    CMD_STOP,
    CMD_MOVE,
    CMD_JOG,
    CMD_CAL_SET,
    CMD_SYNC,
} cmd_kind_t;

typedef struct {
    cmd_kind_t kind;
    union {
        float target; /* CMD_TITRATE: pH in [TARGET_PH_MIN, TARGET_PH_MAX] */
        struct {
            uint8_t ch; /* channel index 0/1 (wire 1/2) */
            dir_t dir;
        } motion;     /* CMD_MOVE, CMD_JOG */
        cal_t cal;    /* CMD_CAL_SET: within the CAL_*_MIN/MAX ranges */
    };
} cmd_t;

/*
 * Parses one CMD write of len bytes (not NUL-terminated). Checks syntax, the
 * command name, field types and the protocol's value ranges; unknown fields
 * are ignored.
 *
 * Returns NULL and fills *out on success. Otherwise returns a short static
 * reason ("too long", "json", "unknown cmd", "ch", "dir", "target", "cal"),
 * which the device sends as the `msg` of `error: bad_cmd`.
 */
const char *proto_parse_cmd(const char *data, size_t len, cmd_t *out);

/* --------------------------------------------------------------- events */

typedef enum {
    EVT_PH,
    EVT_STATE,
    EVT_CAL,
    EVT_ERROR,
} evt_kind_t;

typedef struct {
    evt_kind_t kind;
    union {
        struct {
            float ph; /* sent with 2 decimals */
            float mv; /* electrode mV, sent with 1 decimal */
        } ph;
        dev_state_t state;
        cal_t cal; /* sent with 2 decimals */
        struct {
            err_code_t code;
            int8_t ch;       /* channel index, or -1: no `ch`/`dir` fields */
            dir_t dir;       /* only meaningful when ch >= 0 */
            const char *msg; /* optional static text, NULL: no `msg` field */
        } error;
    };
} evt_t;

/*
 * Encodes one event as compact JSON, e.g. {"evt":"ph","v":6.98,"mv":1.2}.
 * Returns the length (no terminating NUL counted; buf is NUL-terminated when
 * it fits), or 0 when it does not fit in cap or PROTO_MAX_MSG, or a number is
 * not finite.
 */
size_t proto_encode_evt(const evt_t *evt, char *buf, size_t cap);
