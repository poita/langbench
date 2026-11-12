cmake_minimum_required(VERSION 3.20)
project(bigint VERSION 1.0.0 DESCRIPTION "Arbitrary-precision integer arithmetic" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(BIGINT_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(bigint
  src/magnitude.cpp
  src/bigint.cpp
  src/query.cpp)
add_library(bigint::bigint ALIAS bigint)
target_include_directories(bigint PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(bigint PUBLIC cxx_std_17)
target_compile_options(bigint PRIVATE -Wall -Wextra -Wpedantic)

add_executable(bigint_cli cli/main.cpp)
target_link_libraries(bigint_cli PRIVATE bigint::bigint)
target_compile_options(bigint_cli PRIVATE -Wall -Wextra -Wpedantic)

install(TARGETS bigint bigint_cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(BIGINT_BUILD_TESTS)
  find_package(GTest REQUIRED)
  enable_testing()
  add_executable(bigint_tests
    tests/magnitude_test.cpp
    tests/bigint_test.cpp
    tests/query_test.cpp)
  target_link_libraries(bigint_tests PRIVATE bigint::bigint GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(bigint_tests)
endif()
