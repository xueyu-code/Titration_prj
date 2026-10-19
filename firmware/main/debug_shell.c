/*
 * Debug shell on the console UART, see debug_shell.h. One command per line:
 *
 *   {"cmd":...}        a protocol command, handled exactly like a BLE write
 *   axes               switch, homing, position and pulse count per channel
 *   tasks              state, priority and least free stack of every task; heap
 *   log <tag> <level>  log level of a tag (* for all), e.g. `log evt debug`
 *                      to see the events sent to the app
 *
 * Every accepted line is echoed with "> ", so a captured log shows what was
 * asked. The task runs on core 0 at the lowest priority, away from the
 * control task and the step interrupts on core 1.
 */
#include "debug_shell.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "core/types.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "platform/stepper.h"

#define SHELL_STACK 4096u
#define SHELL_PRIO 1u
#define SHELL_CORE 0
#define LINE_LEN 128u /* a protocol command has at most PROTO_MAX_MSG = 100 bytes */
#define ARGS_MAX 4
#define TASKS_MAX 24u

static void (*s_on_cmd)(const uint8_t *data, size_t len);

static void cmd_help(int argc, char **argv);

static void cmd_axes(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    static const char *const STATUS[] = {"running", "done", "limit_out", "limit_in", "unhomed", "halted"};
    for (uint8_t ch = 0; ch < CH_COUNT; ch++) {
        stepper_info_t i;
        stepper_get_info(ch, &i);
        printf("ch%u: limit %d, homed %d, pos %ld, %s, pulses %d\n", ch + 1u, i.limit, i.homed,
               (long)i.pos, STATUS[i.status], i.pulses);
    }
}

static void cmd_tasks(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    static TaskStatus_t tasks[TASKS_MAX]; /* about 1 KB, kept off the stack */
    static const char STATE[] = "XRBSD";  /* eRunning .. eDeleted */
    UBaseType_t n = uxTaskGetSystemState(tasks, TASKS_MAX, NULL);
    if (n == 0)
        printf("more than %u tasks\n", (unsigned)TASKS_MAX);
    printf("%-16s %-5s %4s %12s\n", "task", "state", "prio", "stack free B");
    for (UBaseType_t k = 0; k < n; k++)
        printf("%-16s %-5c %4u %12u\n", tasks[k].pcTaskName, STATE[tasks[k].eCurrentState],
               (unsigned)tasks[k].uxCurrentPriority, (unsigned)tasks[k].usStackHighWaterMark);
    printf("internal heap free %u B (min %u B), PSRAM free %u B\n",
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}

static void cmd_log(int argc, char **argv)
{
    static const char *const LEVEL[] = {"none", "error", "warn", "info", "debug", "verbose"}; /* esp_log_level_t */
    for (size_t k = 0; argc == 3 && k < sizeof LEVEL / sizeof LEVEL[0]; k++) {
        if (strcmp(argv[2], LEVEL[k]) == 0) {
            esp_log_level_set(argv[1], (esp_log_level_t)k);
            return;
        }
    }
    printf("usage: log <tag|*> none|error|warn|info|debug\n");
}

static const struct {
    const char *name;
    void (*run)(int argc, char **argv);
    const char *help;
} CMDS[] = {
    {"axes", cmd_axes, "switch, homing, position and pulse count per channel"},
    {"tasks", cmd_tasks, "state, priority and least free stack of every task; heap"},
    {"log", cmd_log, "<tag|*> <level>: log level, e.g. `log evt debug` shows the events"},
    {"help", cmd_help, "this list; a line {\"cmd\":...} is a protocol command"},
};

static void cmd_help(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    for (size_t k = 0; k < sizeof CMDS / sizeof CMDS[0]; k++)
        printf("%-6s %s\n", CMDS[k].name, CMDS[k].help);
}

static void run(char *line, size_t len)
{
    if (line[0] == '{') {
        s_on_cmd((const uint8_t *)line, len);
        return;
    }
    char *argv[ARGS_MAX];
    int argc = 0;
    char *save;
    for (char *t = strtok_r(line, " ", &save); t && argc < ARGS_MAX; t = strtok_r(NULL, " ", &save))
        argv[argc++] = t;
    for (size_t k = 0; argc > 0 && k < sizeof CMDS / sizeof CMDS[0]; k++) {
        if (strcmp(argv[0], CMDS[k].name) == 0) {
            CMDS[k].run(argc, argv);
            return;
        }
    }
    printf("unknown command, see help\n");
}

static void shell_task(void *arg)
{
    (void)arg;
    char line[LINE_LEN];
    for (;;) {
        if (!fgets(line, sizeof line, stdin))
            continue;
        size_t len = strcspn(line, "\n"); /* the VFS turns the CR of Enter into LF */
        if (line[len] == '\0') {
            int c;
            while ((c = getchar()) != '\n' && c != EOF) {
            }
            printf("line longer than %u bytes ignored\n", (unsigned)(LINE_LEN - 2));
            continue;
        }
        line[len] = '\0';
        if (len == 0)
            continue;
        printf("> %s\n", line);
        run(line, len);
    }
}

void debug_shell_start(void (*on_cmd)(const uint8_t *data, size_t len))
{
    s_on_cmd = on_cmd;

    /* Blocking reads need the UART driver; until now the console was write-only. */
    fflush(stdout);
    fsync(fileno(stdout));
    ESP_ERROR_CHECK(uart_driver_install(CONFIG_ESP_CONSOLE_UART_NUM, 256, 0, 0, NULL, 0));
    uart_vfs_dev_use_driver(CONFIG_ESP_CONSOLE_UART_NUM);
    setvbuf(stdin, NULL, _IONBF, 0);

    BaseType_t ok = xTaskCreatePinnedToCore(shell_task, "shell", SHELL_STACK, NULL, SHELL_PRIO, NULL, SHELL_CORE);
    ESP_ERROR_CHECK(ok == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
}
