cmake_minimum_required(VERSION 3.20)
project(rx VERSION 1.0.0 DESCRIPTION "Backtracking regular-expression engine" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(RX_BUILD_CLI "Build the regex_cli command-line tool" ON)
option(RX_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(rx
  src/charset.cpp
  src/parser.cpp
  src/compiler.cpp
  src/matcher.cpp
  src/regex.cpp
  src/batch.cpp)
add_library(rx::rx ALIAS rx)
target_include_directories(rx PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(rx PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(rx PRIVATE -Wall -Wextra)
endif()

if(RX_BUILD_CLI)
  add_executable(regex_cli cli/main.cpp)
  target_link_libraries(regex_cli PRIVATE rx)
endif()

if(RX_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    include(GoogleTest)
    add_executable(rx_tests
      tests/charset_test.cpp
      tests/parser_test.cpp
      tests/matcher_test.cpp
      tests/batch_test.cpp
      tests/oracle_test.cpp)
    target_link_libraries(rx_tests PRIVATE rx GTest::gtest GTest::gtest_main)
    gtest_discover_tests(rx_tests)
  else()
    message(WARNING "GoogleTest not found; unit tests will not be built")
  endif()
endif()
