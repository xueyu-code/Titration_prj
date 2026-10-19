/*
 * Step pulses on MCPWM + PCNT, see platform/stepper.h and DESIGN.md section 4.
 *
 * Per channel: an MCPWM timer (1 MHz, counting up) with a comparator and a
 * generator on the STEP pin: TEZ -> low, compare match at period/2 -> high.
 * So every period holds one pulse whose rising edge is in the middle of it.
 * A PCNT unit counts the rising edges on the same pin; that count is what the
 * axis books. The timer's "empty" (TEZ) interrupt runs once per period.
 *
 * Timing model. The timer period and the compare value are shadowed and take
 * effect together at the next TEZ. Let TEZ k be the start of period k:
 *
 *   - at TEZ k the PCNT holds the pulses of periods 0..k-1. The pulse of
 *     period k is still more than 400 us away (half of the shortest period),
 *     far more than the interrupt latency;
 *   - the ISR passes that count to axis_next(). To stop it forces the
 *     generator low, which cancels the pending pulse of period k, and asks the
 *     timer to stop at the next zero. Otherwise it writes the shadow period
 *     and compare for period k+1. That is one period of lag in the speed
 *     profile (one step of the ramp), which has no effect on the number of
 *     pulses: stop decisions are made on the count, never on the number of
 *     interrupts. An interrupt that comes late still stops: the extra pulse
 *     is in the count that axis_finish() books.
 *   - period 0 is written by stepper_start() before the timer starts.
 *
 * Starting. It is not documented whether the TEZ at the very start of a run
 * fires (and so loads the shadow values and interrupts). The first period must
 * be the start-speed period either way (axis.h: it comes from axis_next(a, 0)),
 * so every stop leaves the start-speed period and its compare value loaded as
 * the active values (see Stopping). Then the first period is right even if the
 * start TEZ does not fire; if it does, it just loads the same values again.
 * Without the start TEZ the first interrupt comes one period later, which does
 * not matter: the decisions only depend on the PCNT count.
 * [pending on-board check: first period of a restart after a halt at full speed]
 *
 * Stopping. Before the stop command the shadow period and compare are set to
 * those of v_start (period_slow, half of it). The timer stops at the next zero
 * (STOP_EMPTY), up to one period after the decision, while the output is held
 * low, and that last TEZ loads them. It also leaves the generator's own level
 * low, so the hold can be released without an edge at the next start. To be
 * independent of that, the start also forces the level low once before
 * releasing the hold.
 * [pending on-board check: no extra edge when the hold is released]
 * A new motion must not start before the timer has really stopped: the start
 * command would cancel the pending stop, and the hold would be released in the
 * middle of the old period, where its compare match could still make an edge.
 * The stop interrupt marks that moment (`idle`) and stepper_start() waits for
 * it, at most two long periods.
 *
 * Halting from the task cuts the output at an arbitrary moment. A pulse that is
 * already high is shortened (its rising edge is counted and the position
 * includes it); a pulse whose edge has not come is cancelled. Because the
 * count is read after the force took effect, the position is exactly what
 * the PCNT saw.
 *
 * The interrupt runs the per-period path from IRAM (pcnt_unit_get_count,
 * mcpwm_timer_set_period, mcpwm_comparator_set_compare_value via sdkconfig,
 * axis.c via linker.lf). Forcing the level and stopping the timer are in
 * flash; they run once per motion and nothing writes flash while one is
 * moving (cal_set is only accepted when idle).
 */
#include "platform/stepper.h"

#include "driver/gpio.h"
#include "driver/mcpwm_prelude.h"
#include "driver/pulse_cnt.h"
#include "esp_attr.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "freertos/FreeRTOS.h"
#include "hal/gpio_ll.h"
#include "platform/board.h"
#include "soc/gpio_struct.h"

#define TAG "stepper"

#define TIMER_HZ 1000000u /* 1 tick = 1 us, the unit of axis_next() */
#define PCNT_LIMIT INT16_MAX

typedef struct {
    uint8_t ch;
    axis_t axis;
    portMUX_TYPE lock; /* axis, running, tag, and the hardware calls that go with them */
    bool running;      /* a motion is open: the interrupt plans periods */
    uint32_t tag;
    volatile bool idle; /* the timer is stopped (set by its stop interrupt) */
    uint32_t period_slow;  /* us, the period at v_start: what every stop leaves loaded */

    mcpwm_timer_handle_t timer;
    mcpwm_cmpr_handle_t cmpr;
    mcpwm_gen_handle_t gen;
    pcnt_unit_handle_t pcnt;
    int dir_gpio;
    int limit_gpio;
    int dir_out_level;
} stepper_ch_t;

static stepper_ch_t s_ch[CH_COUNT];
static stepper_end_cb_t s_on_end;
static void *s_on_end_arg;

/* ------------------------------------------------------------ helpers */

FORCE_INLINE_ATTR bool limit_active(const stepper_ch_t *c)
{
    /* Register read instead of gpio_get_level(), which is in flash unless
     * CONFIG_GPIO_CTRL_FUNC_IN_IRAM is set; this runs before every pulse. */
    return gpio_ll_get_level(&GPIO, c->limit_gpio) == BOARD_LIMIT_ACTIVE_LEVEL;
}

/* Cancel the pending pulse and stop the timer at its next zero. The zero that
 * stops it also loads the shadow period and compare, so these are set to the
 * start-speed values first: the next motion then always begins with them. */
static void hw_stop(stepper_ch_t *c)
{
    mcpwm_generator_set_force_level(c->gen, 0, true);
    mcpwm_timer_set_period(c->timer, c->period_slow);
    mcpwm_comparator_set_compare_value(c->cmpr, c->period_slow / 2);
    mcpwm_timer_start_stop(c->timer, MCPWM_TIMER_STOP_EMPTY);
}

/* The next zero stops the timer; wait for it before touching the hardware again. */
static void wait_stopped(const stepper_ch_t *c)
{
    uint32_t limit_us = 2 * c->period_slow; /* the longest period there is, twice */
    for (uint32_t waited = 0; !c->idle && waited < limit_us; waited += 10)
        esp_rom_delay_us(10);
    if (!c->idle)
        ESP_LOGW(TAG, "ch %u: timer did not stop in %u us", c->ch, (unsigned)limit_us);
}

/* -------------------------------------------------------- interrupts */

/* TEZ: the start of a period, see the timing model at the top. */
static bool IRAM_ATTR on_empty(mcpwm_timer_handle_t timer, const mcpwm_timer_event_data_t *edata, void *user_ctx)
{
    (void)timer;
    (void)edata;
    stepper_ch_t *c = user_ctx;
    int n;

    portENTER_CRITICAL_ISR(&c->lock);
    if (!c->running) {
        /* The zero that stops the timer after a stop (or a halt) comes here once more. */
        portEXIT_CRITICAL_ISR(&c->lock);
        return false;
    }

    pcnt_unit_get_count(c->pcnt, &n);
    uint32_t period = axis_next(&c->axis, n, limit_active(c));
    if (period > 0) {
        mcpwm_timer_set_period(c->timer, period);
        mcpwm_comparator_set_compare_value(c->cmpr, period / 2);
        portEXIT_CRITICAL_ISR(&c->lock);
        return false;
    }

    hw_stop(c);
    pcnt_unit_get_count(c->pcnt, &n); /* final: after the force took effect */
    axis_finish(&c->axis, n);
    c->running = false;
    axis_status_t st = axis_status(&c->axis);
    uint32_t tag = c->tag;
    portEXIT_CRITICAL_ISR(&c->lock);

    return s_on_end(c->ch, st, tag, s_on_end_arg);
}

static bool IRAM_ATTR on_stop(mcpwm_timer_handle_t timer, const mcpwm_timer_event_data_t *edata, void *user_ctx)
{
    (void)timer;
    (void)edata;
    ((stepper_ch_t *)user_ctx)->idle = true;
    return false;
}

/* ------------------------------------------------------------- setup */

static esp_err_t channel_init(stepper_ch_t *c, uint8_t ch, const axis_cfg_t *cfg, int step_gpio)
{
    c->ch = ch;
    c->lock = (portMUX_TYPE)portMUX_INITIALIZER_UNLOCKED;
    c->idle = true;
    axis_init(&c->axis, cfg);
    /* axis_init() clamped the speeds; the slowest period must fit the 16-bit timer. */
    c->period_slow = TIMER_HZ / c->axis.cfg.v_start;
    ESP_RETURN_ON_FALSE(c->period_slow < UINT16_MAX, ESP_ERR_INVALID_ARG, TAG, "v_start too low for a 16 bit timer");

    /* DIR: output. LIMIT: input with pull-up (an open or broken switch reads high). */
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << c->dir_gpio,
        .mode = GPIO_MODE_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "dir gpio");
    io = (gpio_config_t){
        .pin_bit_mask = 1ULL << c->limit_gpio,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "limit gpio");
    /* STEP: low first, and readable (the PCNT counts the pin the generator drives). */
    gpio_set_level(step_gpio, 0);
    io = (gpio_config_t){
        .pin_bit_mask = 1ULL << step_gpio,
        .mode = GPIO_MODE_INPUT_OUTPUT,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "step gpio");

    /* Timer, operator, comparator, generator. Period and compare update at TEZ;
     * the generator actions are set once, before the first start. */
    mcpwm_timer_config_t tcfg = {
        .group_id = 0,
        .clk_src = MCPWM_TIMER_CLK_SRC_DEFAULT,
        .resolution_hz = TIMER_HZ,
        .count_mode = MCPWM_TIMER_COUNT_MODE_UP,
        .period_ticks = c->period_slow,
        .flags.update_period_on_empty = true,
    };
    ESP_RETURN_ON_ERROR(mcpwm_new_timer(&tcfg, &c->timer), TAG, "timer");
    mcpwm_oper_handle_t oper;
    mcpwm_operator_config_t ocfg = {.group_id = 0};
    ESP_RETURN_ON_ERROR(mcpwm_new_operator(&ocfg, &oper), TAG, "operator");
    ESP_RETURN_ON_ERROR(mcpwm_operator_connect_timer(oper, c->timer), TAG, "connect");
    mcpwm_comparator_config_t ccfg = {.flags.update_cmp_on_tez = true};
    ESP_RETURN_ON_ERROR(mcpwm_new_comparator(oper, &ccfg, &c->cmpr), TAG, "comparator");
    ESP_RETURN_ON_ERROR(mcpwm_comparator_set_compare_value(c->cmpr, c->period_slow / 2), TAG, "compare");
    mcpwm_generator_config_t gcfg = {.gen_gpio_num = step_gpio};
    ESP_RETURN_ON_ERROR(mcpwm_new_generator(oper, &gcfg, &c->gen), TAG, "generator");
    ESP_RETURN_ON_ERROR(mcpwm_generator_set_action_on_timer_event(
                            c->gen, MCPWM_GEN_TIMER_EVENT_ACTION(MCPWM_TIMER_DIRECTION_UP, MCPWM_TIMER_EVENT_EMPTY, MCPWM_GEN_ACTION_LOW)),
                        TAG, "action tez");
    ESP_RETURN_ON_ERROR(mcpwm_generator_set_action_on_compare_event(
                            c->gen, MCPWM_GEN_COMPARE_EVENT_ACTION(MCPWM_TIMER_DIRECTION_UP, c->cmpr, MCPWM_GEN_ACTION_HIGH)),
                        TAG, "action compare");
    ESP_RETURN_ON_ERROR(mcpwm_generator_set_force_level(c->gen, 0, true), TAG, "hold low");

    mcpwm_timer_event_callbacks_t cbs = {.on_empty = on_empty, .on_stop = on_stop};
    ESP_RETURN_ON_ERROR(mcpwm_timer_register_event_callbacks(c->timer, &cbs, c), TAG, "callbacks");
    ESP_RETURN_ON_ERROR(mcpwm_timer_enable(c->timer), TAG, "enable timer"); /* stopped until stepper_start() */

    /* PCNT: +1 on every rising edge of STEP. accum_count with the limits as
     * watch points extends the 16-bit counter (a long jog can pass 32767). */
    pcnt_unit_config_t ucfg = {
        .low_limit = -PCNT_LIMIT,
        .high_limit = PCNT_LIMIT,
        .flags.accum_count = true,
    };
    ESP_RETURN_ON_ERROR(pcnt_new_unit(&ucfg, &c->pcnt), TAG, "pcnt unit");
    pcnt_chan_config_t pcfg = {.edge_gpio_num = step_gpio, .level_gpio_num = -1};
    pcnt_channel_handle_t chan;
    ESP_RETURN_ON_ERROR(pcnt_new_channel(c->pcnt, &pcfg, &chan), TAG, "pcnt channel");
    ESP_RETURN_ON_ERROR(pcnt_channel_set_edge_action(chan, PCNT_CHANNEL_EDGE_ACTION_INCREASE, PCNT_CHANNEL_EDGE_ACTION_HOLD),
                        TAG, "pcnt edge");
    ESP_RETURN_ON_ERROR(pcnt_unit_add_watch_point(c->pcnt, PCNT_LIMIT), TAG, "pcnt watch high");
    ESP_RETURN_ON_ERROR(pcnt_unit_add_watch_point(c->pcnt, -PCNT_LIMIT), TAG, "pcnt watch low");
    ESP_RETURN_ON_ERROR(pcnt_unit_enable(c->pcnt), TAG, "pcnt enable");
    ESP_RETURN_ON_ERROR(pcnt_unit_clear_count(c->pcnt), TAG, "pcnt clear");
    ESP_RETURN_ON_ERROR(pcnt_unit_start(c->pcnt), TAG, "pcnt start");
    return ESP_OK;
}

esp_err_t stepper_init(const axis_cfg_t *cfg, stepper_end_cb_t on_end, void *arg)
{
    ESP_RETURN_ON_FALSE(cfg && on_end, ESP_ERR_INVALID_ARG, TAG, "null argument");
    s_on_end = on_end;
    s_on_end_arg = arg;

    /* Drivers off until everything drives STEP low; ENN also has an external pull-up. */
    gpio_set_level(BOARD_EN_GPIO, !BOARD_EN_ACTIVE_LEVEL);
    gpio_config_t en = {.pin_bit_mask = 1ULL << BOARD_EN_GPIO, .mode = GPIO_MODE_OUTPUT};
    ESP_RETURN_ON_ERROR(gpio_config(&en), TAG, "en gpio");

    const int step[CH_COUNT] = BOARD_STEP_GPIO;
    const int dir[CH_COUNT] = BOARD_DIR_GPIO;
    const int limit[CH_COUNT] = BOARD_LIMIT_GPIO;
    const int dir_out[CH_COUNT] = BOARD_DIR_OUT_LEVEL;
    for (uint8_t ch = 0; ch < CH_COUNT; ch++) {
        s_ch[ch].dir_gpio = dir[ch];
        s_ch[ch].limit_gpio = limit[ch];
        s_ch[ch].dir_out_level = dir_out[ch];
        ESP_RETURN_ON_ERROR(channel_init(&s_ch[ch], ch, cfg, step[ch]), TAG, "channel %u", ch);
        gpio_set_level(dir[ch], dir_out[ch] ? 0 : 1); /* idle: "in" */
    }

    /* Enabled for good: the TMC2209 lowers the current itself at standstill. */
    gpio_set_level(BOARD_EN_GPIO, BOARD_EN_ACTIVE_LEVEL);
    return ESP_OK;
}

/* ------------------------------------------------------ task-side API */

axis_status_t stepper_start(uint8_t ch, dir_t dir, int32_t steps, uint32_t tag)
{
    stepper_ch_t *c = &s_ch[ch];

    stepper_halt(ch);
    wait_stopped(c);

    bool limit = limit_active(c);
    portENTER_CRITICAL(&c->lock);
    axis_status_t st = axis_start(&c->axis, dir, steps, limit);
    if (st == AXIS_RUNNING) {
        uint32_t period = axis_next(&c->axis, 0, limit);
        if (period == 0) {
            /* Not expected (axis_start just accepted it); never start the timer with 0. */
            axis_finish(&c->axis, 0);
            st = axis_status(&c->axis);
        } else {
            gpio_set_level(c->dir_gpio, (dir == DIR_OUT) == (c->dir_out_level != 0));
            pcnt_unit_clear_count(c->pcnt);
            c->tag = tag;
            c->running = true;
            c->idle = false;
            /* Period 0 goes into the shadow registers; TEZ loads them. */
            mcpwm_timer_set_period(c->timer, period);
            mcpwm_comparator_set_compare_value(c->cmpr, period / 2);
            /* The generator's own level is low (see the top); say it once more, then let go. */
            mcpwm_generator_set_force_level(c->gen, 0, false);
            mcpwm_generator_set_force_level(c->gen, -1, true);
            mcpwm_timer_start_stop(c->timer, MCPWM_TIMER_START_NO_STOP);
        }
    }
    portEXIT_CRITICAL(&c->lock);
    return st;
}

bool stepper_extend(uint8_t ch, dir_t dir, int32_t steps)
{
    stepper_ch_t *c = &s_ch[ch];
    portENTER_CRITICAL(&c->lock);
    bool ok = axis_extend(&c->axis, dir, steps);
    portEXIT_CRITICAL(&c->lock);
    return ok;
}

void stepper_halt(uint8_t ch)
{
    stepper_ch_t *c = &s_ch[ch];
    int n;

    portENTER_CRITICAL(&c->lock);
    if (c->running) {
        hw_stop(c);
        pcnt_unit_get_count(c->pcnt, &n); /* after the force: nothing more can come */
        axis_finish(&c->axis, n);
        c->running = false;
    }
    portEXIT_CRITICAL(&c->lock);
}

void stepper_get_info(uint8_t ch, stepper_info_t *out)
{
    stepper_ch_t *c = &s_ch[ch];
    int n = 0;

    portENTER_CRITICAL(&c->lock);
    pcnt_unit_get_count(c->pcnt, &n);
    out->running = c->running;
    out->status = axis_status(&c->axis);
    out->homed = axis_homed(&c->axis);
    out->pos = axis_pos(&c->axis);
    portEXIT_CRITICAL(&c->lock);
    out->pulses = n;
    out->limit = limit_active(c);
}

/* ------------------------------------------------------------- panic */

void __real_esp_panic_handler(void *info);

/* See stepper.h. Register write only: the cache may be off here. */
void IRAM_ATTR __wrap_esp_panic_handler(void *info)
{
    gpio_ll_set_level(&GPIO, BOARD_EN_GPIO, !BOARD_EN_ACTIVE_LEVEL);
    __real_esp_panic_handler(info);
}
