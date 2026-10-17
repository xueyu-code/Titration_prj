/* Wire format, see core/protocol.h. TODO(WP1): implement. */
#include "core/protocol.h"

#include "cJSON.h"
#include "core/config.h"

const char *proto_parse_cmd(const char *data, size_t len, cmd_t *out)
{
    (void)data;
    (void)len;
    (void)out;
    return "not implemented";
}

size_t proto_encode_evt(const evt_t *evt, char *buf, size_t cap)
{
    (void)evt;
    (void)buf;
    (void)cap;
    return 0;
}
