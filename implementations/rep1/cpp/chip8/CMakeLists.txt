cmake_minimum_required(VERSION 3.20)
project(chip8 VERSION 1.0.0 DESCRIPTION "Deterministic CHIP-8 interpreter library and CLI" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(CHIP8_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)
option(CHIP8_BUILD_CLI "Build the chip8 command-line tool" ON)

add_library(chip8
  src/display.cpp
  src/font.cpp
  src/job.cpp
  src/keypad.cpp
  src/machine.cpp
  src/report.cpp)
add_library(chip8::chip8 ALIAS chip8)
target_include_directories(chip8 PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(chip8 PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(chip8 PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(CHIP8_BUILD_CLI)
  add_executable(chip8_cli tools/main.cpp)
  set_target_properties(chip8_cli PROPERTIES OUTPUT_NAME chip8)
  target_link_libraries(chip8_cli PRIVATE chip8::chip8)
endif()

if(CHIP8_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(chip8_tests
    tests/test_display.cpp
    tests/test_job.cpp
    tests/test_keypad.cpp
    tests/test_machine.cpp
    tests/test_report.cpp
    tests/test_rng.cpp
    tests/test_spec_examples.cpp)
  target_link_libraries(chip8_tests PRIVATE chip8::chip8 GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(chip8_tests)
endif()
