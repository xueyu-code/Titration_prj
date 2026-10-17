# Host unit tests of the firmware core (components/core): plain gcc, no
# ESP-IDF toolchain. cJSON and Unity are compiled from the ESP-IDF source tree.
#
#   cmake -S firmware/test/host -B firmware/test/host/build -G Ninja
#   cmake --build firmware/test/host/build
#   ctest --test-dir firmware/test/host/build --output-on-failure
cmake_minimum_required(VERSION 3.16)
project(titrator_host_tests C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON) # gnu17, as ESP-IDF builds the target
set(CMAKE_EXPORT_COMPILE_COMMANDS ON) # for clangd, see firmware/.clangd

if(DEFINED ENV{IDF_PATH})
    set(_idf_default "$ENV{IDF_PATH}")
else()
    set(_idf_default "$ENV{HOME}/esp/esp-idf-v5.5.5")
endif()
set(IDF_PATH "${_idf_default}" CACHE PATH "ESP-IDF source tree (for cJSON and Unity)")
set(CJSON_DIR "${IDF_PATH}/components/json/cJSON")
set(UNITY_DIR "${IDF_PATH}/components/unity/unity/src")
foreach(_src "${CJSON_DIR}/cJSON.c" "${UNITY_DIR}/unity.c")
    if(NOT EXISTS "${_src}")
        message(FATAL_ERROR "${_src} not found; pass -DIDF_PATH=<esp-idf>")
    endif()
endforeach()

option(SANITIZE "AddressSanitizer + UndefinedBehaviorSanitizer" ON)
set(CLOG_LEVEL 0 CACHE STRING "Core log output on the host: 0 silent .. 4 debug")

if(SANITIZE)
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()

set(FW_DIR "${CMAKE_CURRENT_LIST_DIR}/../..")
set(WARNINGS -Wall -Wextra -Werror)

# Third-party sources, as shipped with ESP-IDF.
add_library(cjson STATIC "${CJSON_DIR}/cJSON.c")
target_include_directories(cjson SYSTEM PUBLIC "${CJSON_DIR}")

add_library(unity STATIC "${UNITY_DIR}/unity.c")
target_include_directories(unity SYSTEM PUBLIC "${UNITY_DIR}")
target_compile_definitions(unity PUBLIC UNITY_INCLUDE_DOUBLE)

# The code under test: the same files the ESP-IDF component compiles.
add_library(core STATIC
    "${FW_DIR}/components/core/src/protocol.c"
    "${FW_DIR}/components/core/src/ph.c"
    "${FW_DIR}/components/core/src/sensor_fault.c"
    "${FW_DIR}/components/core/src/axis.c"
    "${FW_DIR}/components/core/src/titration.c"
    "${FW_DIR}/components/core/src/device.c")
target_include_directories(core PUBLIC "${FW_DIR}/components/core/include")
target_link_libraries(core PUBLIC cjson m)
target_compile_options(core PRIVATE ${WARNINGS} -Wdouble-promotion)
target_compile_definitions(core PRIVATE CLOG_LEVEL=${CLOG_LEVEL})

# Simulated world for the closed-loop test: beaker, electrode, front end,
# syringes with limit switches, and the app's completion rule.
add_library(sim STATIC sim/beaker.c sim/rig.c)
target_include_directories(sim PUBLIC "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(sim PUBLIC core m)
target_compile_options(sim PRIVATE ${WARNINGS})

enable_testing()

function(host_test name)
    add_executable(${name} ${name}.c)
    target_link_libraries(${name} PRIVATE core sim unity)
    target_compile_options(${name} PRIVATE ${WARNINGS})
    add_test(NAME ${name} COMMAND ${name})
    # An ignored case is unfinished work, not a pass.
    set_tests_properties(${name} PROPERTIES FAIL_REGULAR_EXPRESSION ":IGNORE")
endfunction()

host_test(test_protocol)     # WP1
host_test(test_ph)           # WP1
host_test(test_sensor_fault) # WP1
host_test(test_axis)         # WP2
host_test(test_titration)    # WP3
host_test(test_device)       # WP3
host_test(test_beaker)       # WP4
host_test(test_closed_loop)  # WP4, passes once WP1-WP3 are in
