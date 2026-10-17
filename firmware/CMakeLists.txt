# ESP-IDF project of the titrator firmware. See DESIGN.md.
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# Build only what main and the project components require.
idf_build_set_property(MINIMAL_BUILD ON)

project(titrator)
