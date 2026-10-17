/*
 * Logging for the core modules.
 *
 * On the target this is ESP_LOGx. On the host it prints to stderr when the
 * test build defines CLOG_LEVEL (1 error .. 4 debug); the default is silent.
 * Never log from ISR code (axis.c).
 */
#pragma once

#ifdef ESP_PLATFORM

#include "esp_log.h"

#define CLOGE(tag, fmt, ...) ESP_LOGE(tag, fmt, ##__VA_ARGS__)
#define CLOGW(tag, fmt, ...) ESP_LOGW(tag, fmt, ##__VA_ARGS__)
#define CLOGI(tag, fmt, ...) ESP_LOGI(tag, fmt, ##__VA_ARGS__)
#define CLOGD(tag, fmt, ...) ESP_LOGD(tag, fmt, ##__VA_ARGS__)

#else

#include <stdio.h>

#ifndef CLOG_LEVEL
#define CLOG_LEVEL 0
#endif

#define CLOG_AT_(level, letter, tag, fmt, ...)                                   \
    do {                                                                         \
        if (CLOG_LEVEL >= (level))                                               \
            fprintf(stderr, letter " (%s) " fmt "\n", (tag), ##__VA_ARGS__);     \
    } while (0)

#define CLOGE(tag, fmt, ...) CLOG_AT_(1, "E", tag, fmt, ##__VA_ARGS__)
#define CLOGW(tag, fmt, ...) CLOG_AT_(2, "W", tag, fmt, ##__VA_ARGS__)
#define CLOGI(tag, fmt, ...) CLOG_AT_(3, "I", tag, fmt, ##__VA_ARGS__)
#define CLOGD(tag, fmt, ...) CLOG_AT_(4, "D", tag, fmt, ##__VA_ARGS__)

#endif
