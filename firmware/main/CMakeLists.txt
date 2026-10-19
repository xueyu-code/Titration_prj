set(srcs "main.c")
if(CONFIG_TITRATOR_DEBUG_SHELL)
    list(APPEND srcs "debug_shell.c")
endif()

# espcoredump: no calls, but MINIMAL_BUILD leaves it (and its Kconfig) out
# unless something requires it; sdkconfig.defaults turns it on.
idf_component_register(
    SRCS ${srcs}
    PRIV_REQUIRES core platform freertos esp_timer esp_app_format heap log esp_driver_uart vfs
                  espcoredump)
