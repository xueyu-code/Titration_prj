# ESP-IDF project of the titrator firmware. See DESIGN.md.
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# Build only what main and the project components require.
idf_build_set_property(MINIMAL_BUILD ON)

project(titrator)

# The core dump code filters its logs at compile time, so with DEBUG compiled
# in (sdkconfig.defaults) it would print a few lines per task while the device
# is down, about 1.5 s at 115200 baud. INFO keeps its summary lines.
idf_component_get_property(coredump_lib espcoredump COMPONENT_LIB)
target_compile_definitions(${coredump_lib} PRIVATE LOG_LOCAL_LEVEL=ESP_LOG_INFO)
