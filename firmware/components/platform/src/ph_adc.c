/*
 * pH front-end ADC on ESP32-S3 ADC1 continuous mode, see platform/ph_adc.h
 * and DESIGN.md 1.3.
 *
 * Windows are counted in samples, not in time: WINDOW_SAMPLES = 5000 samples
 * at 10 kSPS is exactly 25 periods of 50 Hz and 30 of 60 Hz mains, which the
 * average cancels. adc_continuous_read() is asked for no more than the window
 * still needs, so no sample is ever left over for the next window.
 *
 * ---------------------------------------------------------------------------
 * Acceptance measurement: linearity of the internal ADC (DESIGN.md 1.3)
 *
 * The one assumption of the design that may not hold is the ADC's INL over
 * the working range (0.7..1.3 V at the pin). Measure it once on the real board.
 *
 * Needs: a source adjustable over 0.7..1.3 V in place of the module, with the
 * same 100 nF from GPIO1 to GND, e.g. 3V3 - 22k - 10k pot - 4.7k - GND with the
 * wiper on GPIO1 (0.42..1.32 V); and a multimeter with at least 4.5 digits,
 * i.e. 0.1 mV at 1 V (a 3.5-digit meter resolves 1 mV, the pass limit itself).
 *
 *  1. Make the log visible: `idf.py menuconfig` > Component config > Log >
 *     Default log verbosity = Debug (or call esp_log_level_set("ph_adc",
 *     ESP_LOG_DEBUG) in main.c), then flash and monitor. Every window prints
 *     one line, 2 per second:
 *         D (12345) ph_adc: V_adc=1050.41 mV raw=2563.17
 *     V_adc is the window mean at the pin in mV, raw the mean code (0..4095).
 *     With the bare 1.05 V divider (10k to 3V3, 4.7k to GND) it reads about
 *     1050 mV, steady to a few tenths of a millivolt.
 *  2. Set about 10 voltages between 0.7 and 1.3 V, evenly spread, in random
 *     order. At each: read the meter on the GPIO1 pin, wait 3 windows, then
 *     note the mean and standard deviation of the next 10 V_adc values.
 *  3. Log one row per point as CSV and fit V_adc = a + b * V_meter:
 *         V_meter_mV,V_adc_mean_mV,V_adc_std_mV
 *         import numpy as np; d = np.loadtxt("adc.csv", delimiter=",", skiprows=1)
 *         b, a = np.polyfit(d[:, 0], d[:, 1], 1); res = d[:, 1] - (a + b * d[:, 0])
 *         print(a, b, np.abs(res).max(), d[:, 2].max())
 *     (Expect b near 1 and a within about 10 mV, the datasheet's calibrated
 *     total error; the app's calibration absorbs both. Only the residual,
 *     the deviation from a straight line, is the INL that matters.)
 *
 * Pass: max |residual| <= 1.2 mV at the pin (1 mV at the electrode, about
 * 0.017 pH) and every standard deviation <= 0.12 mV at the pin. (The app
 * calls a reading stable when 10 of them span <= 1.0 mV at the electrode,
 * about 3 sigma, so sigma <= 0.3 mV there; 0.12 mV at the pin, 0.1 mV at the
 * electrode, keeps the ADC from using up that budget.) Fail: replace this file
 * by an ADS1115 driver behind the same ph_adc.h (16 bit, INL +-1 LSB; GPIO8
 * and GPIO9 are kept free for its I2C).
 * ---------------------------------------------------------------------------
 */
#include "platform/ph_adc.h"

#include <stdbool.h>
#include <stdint.h>

#include "core/config.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_continuous.h"
#include "esp_check.h"
#include "esp_log.h"
#include "platform/board.h"

#define ADC_CHAN ((adc_channel_t)BOARD_PH_ADC_CHANNEL)
#define ADC_MAX_CODE 4095

#define WINDOW_SAMPLES (BOARD_PH_ADC_SAMPLE_HZ / 1000u * SAMPLE_PERIOD_MS) /* 5000 */
#define FRAME_SAMPLES (BOARD_PH_ADC_SAMPLE_HZ / 10u)                       /* one DMA frame: 100 ms */
#define POOL_FRAMES 4u        /* 400 ms of results the driver keeps for a busy reader */
#define CHUNK_SAMPLES 256u    /* per adc_continuous_read() */

/* Piecewise-linear code -> mV table: a knot every KNOT_STEP codes plus one at
 * the top code (the last segment is shorter). Each knot is the mean of the
 * calibration over the KNOT_HALF codes on either side of it, which averages
 * out the 1 mV rounding of adc_cali_raw_to_voltage(). */
#define KNOT_STEP 64
#define KNOT_HALF 32
#define KNOT_COUNT (ADC_MAX_CODE / KNOT_STEP + 2) /* 0, 64, ..., 4032, 4095 */

static const char *TAG = "ph_adc";

static adc_continuous_handle_t s_adc;
static float s_knot_mv[KNOT_COUNT];
static adc_digi_output_data_t s_chunk[CHUNK_SAMPLES];
static volatile bool s_overflow; /* set in the ISR when the driver dropped a frame */

static int knot_code(int i)
{
    int code = i * KNOT_STEP;

    return code < ADC_MAX_CODE ? code : ADC_MAX_CODE;
}

/* Mean code (0..ADC_MAX_CODE, fractional) -> mV at the pin. */
static float code_to_mv(float code)
{
    int i = (int)(code / KNOT_STEP);
    float c0, c1;

    if (i > KNOT_COUNT - 2)
        i = KNOT_COUNT - 2;
    c0 = (float)knot_code(i);
    c1 = (float)knot_code(i + 1);
    return s_knot_mv[i] + (s_knot_mv[i + 1] - s_knot_mv[i]) * (code - c0) / (c1 - c0);
}

/* The curve-fitting calibration (eFuse data) at the knots. It takes and gives
 * integers, which is why the sub-LSB mean is interpolated between knots. A
 * knot near either end of the code range averages a narrower, still symmetric,
 * span. */
static esp_err_t build_table(void)
{
    const adc_cali_curve_fitting_config_t cfg = {
        .unit_id = ADC_UNIT_1,
        .chan = ADC_CHAN,
        .atten = ADC_ATTEN_DB_6,
        .bitwidth = ADC_BITWIDTH_12,
    };
    adc_cali_handle_t cali;
    esp_err_t err = adc_cali_create_scheme_curve_fitting(&cfg, &cali);

    if (err != ESP_OK) {
        ESP_LOGE(TAG, "ADC calibration unavailable: %s", esp_err_to_name(err));
        return err;
    }
    for (int i = 0; i < KNOT_COUNT && err == ESP_OK; i++) {
        int c = knot_code(i);
        int half = c < ADC_MAX_CODE - c ? c : ADC_MAX_CODE - c;
        int sum = 0;

        if (half > KNOT_HALF)
            half = KNOT_HALF;
        for (int code = c - half; code <= c + half && err == ESP_OK; code++) {
            int mv = 0;

            err = adc_cali_raw_to_voltage(cali, code, &mv);
            sum += mv;
        }
        s_knot_mv[i] = (float)sum / (float)(2 * half + 1);
    }
    adc_cali_delete_scheme_curve_fitting(cali);
    return err;
}

/* In the ISR; only a flag. */
static bool on_pool_ovf(adc_continuous_handle_t handle, const adc_continuous_evt_data_t *edata,
                        void *user_data)
{
    (void)handle;
    (void)edata;
    (void)user_data;
    s_overflow = true;
    return false;
}

static esp_err_t start_sampling(void)
{
    adc_digi_pattern_config_t pattern = {
        .atten = ADC_ATTEN_DB_6,
        .channel = ADC_CHAN,
        .unit = ADC_UNIT_1,
        .bit_width = ADC_BITWIDTH_12,
    };
    const adc_continuous_config_t cfg = {
        .pattern_num = 1,
        .adc_pattern = &pattern,
        .sample_freq_hz = BOARD_PH_ADC_SAMPLE_HZ,
        .conv_mode = ADC_CONV_SINGLE_UNIT_1,
        .format = ADC_DIGI_OUTPUT_FORMAT_TYPE2,
    };
    const adc_continuous_evt_cbs_t cbs = {.on_pool_ovf = on_pool_ovf};

    ESP_RETURN_ON_ERROR(adc_continuous_config(s_adc, &cfg), TAG, "config");
    ESP_RETURN_ON_ERROR(adc_continuous_register_event_callbacks(s_adc, &cbs, NULL), TAG, "callbacks");
    return adc_continuous_start(s_adc);
}

esp_err_t ph_adc_init(void)
{
    const adc_continuous_handle_cfg_t cfg = {
        .max_store_buf_size = POOL_FRAMES * FRAME_SAMPLES * sizeof(adc_digi_output_data_t),
        .conv_frame_size = FRAME_SAMPLES * sizeof(adc_digi_output_data_t),
    };
    esp_err_t err = build_table();

    if (err != ESP_OK)
        return err;
    ESP_RETURN_ON_ERROR(adc_continuous_new_handle(&cfg, &s_adc), TAG, "new handle");
    err = start_sampling();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "start failed: %s", esp_err_to_name(err));
        adc_continuous_deinit(s_adc);
        s_adc = NULL;
        return err;
    }
    ESP_LOGI(TAG, "ADC1 channel %d, 6 dB, %d Hz, %u samples per window", (int)ADC_CHAN,
             BOARD_PH_ADC_SAMPLE_HZ, (unsigned)WINDOW_SAMPLES);
    return ESP_OK;
}

esp_err_t ph_adc_read(float *v_adc_mv)
{
    uint32_t sum = 0;
    uint32_t n = 0;    /* valid samples in the window */
    uint32_t seen = 0; /* all samples read, to give up on a stream without valid ones */
    float mean;

    if (s_adc == NULL)
        return ESP_ERR_INVALID_STATE;
    while (n < WINDOW_SAMPLES) {
        uint32_t want = WINDOW_SAMPLES - n;
        uint32_t got = 0;
        esp_err_t err;

        if (want > CHUNK_SAMPLES)
            want = CHUNK_SAMPLES;
        err = adc_continuous_read(s_adc, (uint8_t *)s_chunk, want * sizeof s_chunk[0], &got,
                                  SAMPLE_PERIOD_MS);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "read failed after %u samples: %s", (unsigned)n, esp_err_to_name(err));
            return err;
        }
        got /= sizeof s_chunk[0];
        for (uint32_t i = 0; i < got; i++) {
            const adc_digi_output_data_t *d = &s_chunk[i];

            if (d->type2.unit == ADC_UNIT_1 && d->type2.channel == ADC_CHAN) {
                sum += d->type2.data;
                n++;
            }
        }
        seen += got;
        if (seen > 2 * WINDOW_SAMPLES) {
            ESP_LOGW(TAG, "no valid samples: %u of %u are not ADC1 channel %d", (unsigned)(seen - n),
                     (unsigned)seen, (int)ADC_CHAN);
            return ESP_ERR_INVALID_RESPONSE;
        }
    }
    if (seen > n)
        ESP_LOGD(TAG, "%u invalid samples dropped", (unsigned)(seen - n));

    /* Lost frames break the 25 / 30 whole mains periods: drop this window. */
    if (s_overflow) {
        s_overflow = false;
        ESP_LOGW(TAG, "samples lost (driver pool full), window dropped");
        return ESP_ERR_INVALID_STATE;
    }

    mean = (float)sum / (float)n;
    *v_adc_mv = code_to_mv(mean);
    ESP_LOGD(TAG, "V_adc=%.2f mV raw=%.2f", (double)*v_adc_mv, (double)mean);
    return ESP_OK;
}
