# Pure-C core: no ESP-IDF APIs (cJSON is portable; clog.h maps to esp_log
# under ESP_PLATFORM). The same sources build for the host tests.
idf_component_register(
    SRCS "src/protocol.c"
         "src/ph.c"
         "src/sensor_fault.c"
         "src/axis.c"
         "src/titration.c"
         "src/device.c"
    INCLUDE_DIRS "include"
    PRIV_REQUIRES json log
    LDFRAGMENTS "linker.lf")

# Single precision only: double is software-emulated on the ESP32-S3.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wdouble-promotion)
