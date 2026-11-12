cmake_minimum_required(VERSION 3.20)
project(rrule VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(RRULE_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(rrule
  src/date.cpp
  src/rule.cpp
  src/parser.cpp
  src/expander.cpp)
add_library(rrule::rrule ALIAS rrule)
target_include_directories(rrule PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(rrule PUBLIC cxx_std_17)
target_compile_options(rrule PRIVATE -Wall -Wextra)

add_executable(rrule-cli cli/main.cpp)
target_link_libraries(rrule-cli PRIVATE rrule::rrule)
set_target_properties(rrule-cli PROPERTIES OUTPUT_NAME rrule)

if(RRULE_BUILD_TESTS)
  find_package(GTest CONFIG QUIET)
  if(NOT GTest_FOUND)
    find_package(GTest QUIET)
  endif()
  if(GTest_FOUND)
    enable_testing()
    include(GoogleTest)
    add_executable(rrule_tests
      tests/test_date.cpp
      tests/test_parser.cpp
      tests/test_expander.cpp)
    target_link_libraries(rrule_tests PRIVATE rrule::rrule GTest::gtest GTest::gtest_main)
    target_compile_options(rrule_tests PRIVATE -Wall -Wextra)
    gtest_discover_tests(rrule_tests)
  else()
    message(STATUS "GoogleTest not found: unit tests are not built")
  endif()
endif()
