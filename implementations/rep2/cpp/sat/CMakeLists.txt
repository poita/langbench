cmake_minimum_required(VERSION 3.20)
project(sat VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SAT_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(sat_core
  src/heap.cpp
  src/solver.cpp
  src/dimacs.cpp)
add_library(sat::core ALIAS sat_core)
target_include_directories(sat_core PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_options(sat_core PRIVATE -Wall -Wextra)

add_executable(sat cli/main.cpp)
target_link_libraries(sat PRIVATE sat::core)

if(SAT_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_executable(sat_tests
      tests/heap_test.cpp
      tests/dimacs_test.cpp
      tests/solver_test.cpp)
    target_link_libraries(sat_tests PRIVATE sat::core GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(sat_tests)
  else()
    message(STATUS "GoogleTest not found; tests disabled")
  endif()
endif()
