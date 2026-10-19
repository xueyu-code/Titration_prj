/*
 * Line commands on the console UART for development (DESIGN.md section 15).
 * Built with CONFIG_TITRATOR_DEBUG_SHELL.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

/* Starts reading the console. on_cmd gets every line that is a protocol
 * command ({"cmd":...}), the same bytes a BLE write would carry. */
void debug_shell_start(void (*on_cmd)(const uint8_t *data, size_t len));
