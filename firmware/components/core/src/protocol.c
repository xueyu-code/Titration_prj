/* Wire format, see core/protocol.h. */
#include "core/protocol.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "core/config.h"

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

/* Names on the wire, indexed by the enums of core/types.h. */
static const char *const DIR_NAME[] = {[DIR_IN] = "in", [DIR_OUT] = "out"};
static const char *const STATE_NAME[] = {
    [DEV_IDLE] = "idle",
    [DEV_TITRATING] = "titrating",
    [DEV_MOVING] = "moving",
};
static const char *const CODE_NAME[] = {
    [ERR_BUSY] = "busy",
    [ERR_LIMIT] = "limit",
    [ERR_UNHOMED] = "unhomed",
    [ERR_NO_CONVERGE] = "no_converge",
    [ERR_SENSOR] = "sensor",
    [ERR_BAD_CMD] = "bad_cmd",
};

/* ------------------------------------------------------------- commands */

/*
 * cJSON recurses once per nesting level (about 64 B of stack each) and a
 * 100 B message can nest 100 levels deep. Commands are flat, so refuse
 * anything nested deeper than any future field could need.
 */
#define MAX_NESTING 4

static bool nested_too_deep(const char *s, size_t n)
{
    unsigned depth = 0;
    bool in_string = false;

    for (size_t i = 0; i < n; i++) {
        if (in_string) {
            if (s[i] == '\\')
                i++;
            else if (s[i] == '"')
                in_string = false;
        } else if (s[i] == '"') {
            in_string = true;
        } else if (s[i] == '{' || s[i] == '[') {
            if (++depth > MAX_NESTING)
                return true;
        } else if ((s[i] == '}' || s[i] == ']') && depth > 0) {
            depth--;
        }
    }
    return false;
}

/* A number field within [lo, hi]. NaN cannot occur in JSON, +-inf ("1e999") fails the range. */
static bool get_number(const cJSON *obj, const char *key, float lo, float hi, float *out)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, key);

    if (!cJSON_IsNumber(it) || !(it->valuedouble >= (double)lo && it->valuedouble <= (double)hi))
        return false;
    *out = (float)it->valuedouble;
    return true;
}

/* Wire channel 1..CH_COUNT (an integer) -> index. */
static bool get_channel(const cJSON *obj, uint8_t *ch)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, "ch");

    if (!cJSON_IsNumber(it) || it->valuedouble != it->valueint || it->valueint < 1 ||
        it->valueint > CH_COUNT)
        return false;
    *ch = (uint8_t)(it->valueint - 1);
    return true;
}

static bool get_dir(const cJSON *obj, dir_t *dir)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(obj, "dir");

    if (!cJSON_IsString(it))
        return false;
    for (size_t i = 0; i < COUNT(DIR_NAME); i++) {
        if (strcmp(it->valuestring, DIR_NAME[i]) == 0) {
            *dir = (dir_t)i;
            return true;
        }
    }
    return false;
}

static const char *parse_motion(const cJSON *obj, cmd_kind_t kind, cmd_t *out)
{
    uint8_t ch;
    dir_t dir;

    if (!get_channel(obj, &ch))
        return "ch";
    if (!get_dir(obj, &dir))
        return "dir";
    *out = (cmd_t){.kind = kind, .motion = {.ch = ch, .dir = dir}};
    return NULL;
}

/* A missing or non-string `cmd` is an unknown cmd. */
static const char *parse_object(const cJSON *obj, cmd_t *out)
{
    const cJSON *name = cJSON_GetObjectItemCaseSensitive(obj, "cmd");
    const char *cmd = cJSON_IsString(name) ? name->valuestring : "";

    if (strcmp(cmd, "stop") == 0) {
        *out = (cmd_t){.kind = CMD_STOP};
        return NULL;
    }
    if (strcmp(cmd, "titrate") == 0) {
        float target;

        if (!get_number(obj, "target", TARGET_PH_MIN, TARGET_PH_MAX, &target))
            return "target";
        *out = (cmd_t){.kind = CMD_TITRATE, .target = target};
        return NULL;
    }
    if (strcmp(cmd, "move") == 0)
        return parse_motion(obj, CMD_MOVE, out);
    if (strcmp(cmd, "jog") == 0)
        return parse_motion(obj, CMD_JOG, out);
    if (strcmp(cmd, "cal_set") == 0) {
        cal_t cal;

        if (!get_number(obj, "slope", CAL_SLOPE_MIN, CAL_SLOPE_MAX, &cal.slope) ||
            !get_number(obj, "offset", CAL_OFFSET_MIN, CAL_OFFSET_MAX, &cal.offset))
            return "cal";
        *out = (cmd_t){.kind = CMD_CAL_SET, .cal = cal};
        return NULL;
    }
    return "unknown cmd";
}

/* JSON whitespace only; in particular no NUL. */
static bool only_blanks(const char *p, const char *end)
{
    for (; p < end; p++) {
        if (*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r')
            return false;
    }
    return true;
}

const char *proto_parse_cmd(const char *data, size_t len, cmd_t *out)
{
    const char *end;
    const char *err = "json";
    cJSON *root;

    if (len > PROTO_MAX_MSG)
        return "too long";
    if (nested_too_deep(data, len))
        return err;

    /* Not NUL-terminated: parse exactly len bytes and allow only blanks after the value. */
    root = cJSON_ParseWithLengthOpts(data, len, &end, false);
    if (root == NULL)
        return err;
    if (cJSON_IsObject(root) && only_blanks(end, data + len))
        err = parse_object(root, out);
    cJSON_Delete(root);
    return err;
}

/* --------------------------------------------------------------- events */

/* The name table entry for idx, or NULL when idx is outside the table. */
static const char *name_of(const char *const *table, size_t count, unsigned idx)
{
    return idx < count ? table[idx] : NULL;
}

/* A message goes between quotes as it is, so it must not need escaping. */
static bool json_plain(const char *s)
{
    for (; *s; s++) {
        if (*s == '"' || *s == '\\' || (unsigned char)*s < ' ')
            return false;
    }
    return true;
}

#define ERROR_FMT "{\"evt\":\"error\",\"code\":\"%s\"%s%s%s%s}"

/*
 * The `msg` is optional detail. When it would need escaping, or would push the
 * event past PROTO_MAX_MSG, it is left out and the error itself is still sent.
 */
static int format_error(const evt_t *e, char *buf, size_t cap)
{
    const char *code = name_of(CODE_NAME, COUNT(CODE_NAME), (unsigned)e->error.code);
    const char *msg = e->error.msg;
    char where[32] = "";
    int n;

    if (code == NULL)
        return -1;
    if (e->error.ch >= 0) {
        const char *dir = name_of(DIR_NAME, COUNT(DIR_NAME), (unsigned)e->error.dir);

        if (e->error.ch >= CH_COUNT || dir == NULL)
            return -1;
        snprintf(where, sizeof where, ",\"ch\":%d,\"dir\":\"%s\"", e->error.ch + 1, dir);
    }
    if (msg != NULL && json_plain(msg)) {
        n = snprintf(buf, cap, ERROR_FMT, code, where, ",\"msg\":\"", msg, "\"");
        if (n <= PROTO_MAX_MSG)
            return n;
    }
    return snprintf(buf, cap, ERROR_FMT, code, where, "", "", "");
}

/* Returns the length snprintf wants, or -1 for an event that has no valid encoding. */
static int format_evt(const evt_t *e, char *buf, size_t cap)
{
    switch (e->kind) {
    case EVT_PH:
        if (!isfinite(e->ph.ph) || !isfinite(e->ph.mv))
            return -1;
        return snprintf(buf, cap, "{\"evt\":\"ph\",\"v\":%.2f,\"mv\":%.1f}", (double)e->ph.ph,
                        (double)e->ph.mv);
    case EVT_STATE: {
        const char *s = name_of(STATE_NAME, COUNT(STATE_NAME), (unsigned)e->state);

        return s ? snprintf(buf, cap, "{\"evt\":\"state\",\"s\":\"%s\"}", s) : -1;
    }
    case EVT_CAL:
        if (!isfinite(e->cal.slope) || !isfinite(e->cal.offset))
            return -1;
        return snprintf(buf, cap, "{\"evt\":\"cal\",\"slope\":%.2f,\"offset\":%.2f}",
                        (double)e->cal.slope, (double)e->cal.offset);
    case EVT_ERROR:
        return format_error(e, buf, cap);
    }
    return -1;
}

size_t proto_encode_evt(const evt_t *evt, char *buf, size_t cap)
{
    int n = format_evt(evt, buf, cap);

    if (n <= 0 || (size_t)n >= cap || n > PROTO_MAX_MSG) {
        if (cap > 0)
            buf[0] = '\0';
        return 0;
    }
    return (size_t)n;
}
