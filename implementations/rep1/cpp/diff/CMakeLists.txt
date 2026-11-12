cmake_minimum_required(VERSION 3.20)
project(mdiff VERSION 1.0.0 DESCRIPTION "Myers linear-space line diff and patch" LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(MDIFF_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(mdiff
  src/lines.cpp
  src/myers.cpp
  src/script.cpp
  src/diff.cpp
  src/patch.cpp
  src/protocol.cpp)
add_library(mdiff::mdiff ALIAS mdiff)
target_include_directories(mdiff PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(mdiff PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(mdiff PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(mdiff_cli cli/main.cpp)
target_link_libraries(mdiff_cli PRIVATE mdiff::mdiff)
set_target_properties(mdiff_cli PROPERTIES OUTPUT_NAME mdiff)

if(MDIFF_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(mdiff_tests
    tests/test_lines.cpp
    tests/test_myers.cpp
    tests/test_diff_patch.cpp
    tests/test_protocol.cpp)
  target_link_libraries(mdiff_tests PRIVATE mdiff::mdiff GTest::gtest_main)
  add_test(NAME mdiff_tests COMMAND mdiff_tests)
endif()
