cmake_minimum_required(VERSION 3.20)
project(bigint VERSION 1.0.0 DESCRIPTION "Arbitrary-precision integer arithmetic" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(BIGINT_BUILD_TESTS "Build the unit tests" ON)

# --- library -----------------------------------------------------------------
add_library(bigint
  src/magnitude.cpp
  src/bigint.cpp
  src/query.cpp)
add_library(bigint::bigint ALIAS bigint)
target_include_directories(bigint PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(bigint PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(bigint PRIVATE -Wall -Wextra -Wpedantic)
endif()

# --- command-line tool -------------------------------------------------------
add_executable(bigint_cli cli/main.cpp)
set_target_properties(bigint_cli PROPERTIES OUTPUT_NAME bigint)
target_link_libraries(bigint_cli PRIVATE bigint::bigint)

# --- install -----------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS bigint bigint_cli
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

# --- tests -------------------------------------------------------------------
if(BIGINT_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(bigint_tests
    tests/magnitude_test.cpp
    tests/bigint_test.cpp
    tests/query_test.cpp)
  target_link_libraries(bigint_tests PRIVATE bigint::bigint GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(bigint_tests)
endif()
