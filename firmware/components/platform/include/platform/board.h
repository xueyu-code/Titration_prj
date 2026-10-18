/*
 * Board wiring: ESP32-S3-DevKitC-1 (v1.0 or v1.1) with ESP32-S3-WROOM-1-N16R8.
 * [待硬件确认] The whole table is a draft until the wiring exists; see
 * DESIGN.md "引脚规划".
 *
 * Avoided: GPIO26-37 (flash and octal PSRAM; 35-37 are on the header but
 * taken), GPIO0/3/45/46 (strapping), GPIO19/20 (USB), GPIO43/44 (UART0
 * console), GPIO38 and GPIO48 (on-board RGB LED, v1.1 and v1.0).
 */
#pragma once

/* Per channel, index CH_ACID (ch 1) and CH_BASE (ch 2). All on header J1. */
#define BOARD_STEP_GPIO {4, 6}  /* TMC2209 STEP, driven by MCPWM */
#define BOARD_DIR_GPIO {5, 7}   /* TMC2209 DIR */
#define BOARD_LIMIT_GPIO {16, 17}

/* DIR level that moves the plunger towards the empty end ("out"), per
 * channel; depends on the motor wiring. [待确认] */
#define BOARD_DIR_OUT_LEVEL {1, 1}

/* Empty-end switch: normally-closed contact to GND, pull-up (internal plus
 * external 10k, 100 nF to GND). Open = high = at the end, and a broken wire
 * also reads as "at the end", which stops dispensing (fail-safe). */
#define BOARD_LIMIT_ACTIVE_LEVEL 1

/* Shared ENN of both TMC2209: low = driver on. External 10k pull-up to 3.3 V
 * keeps the drivers off while the ESP32 is in reset. */
#define BOARD_EN_GPIO 15
#define BOARD_EN_ACTIVE_LEVEL 0

/* pH: PH-4502C Po -> 15k/10k divider (+100 nF) -> ADC1 channel 0. Header J3. */
#define BOARD_PH_ADC_GPIO 1
#define BOARD_PH_ADC_CHANNEL 0      /* ADC_CHANNEL_0 of ADC_UNIT_1 */
#define BOARD_PH_ADC_SAMPLE_HZ 10000 /* continuous mode; 5000 samples per window */
