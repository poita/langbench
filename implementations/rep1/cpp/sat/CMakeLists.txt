cmake_minimum_required(VERSION 3.20)
project(sat VERSION 1.0.0 DESCRIPTION "A CDCL SAT solver for DIMACS CNF" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SAT_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)
option(SAT_BUILD_CLI "Build the command-line tool" ON)

# ---- library ---------------------------------------------------------------
add_library(satlib
  src/solver.cpp
  src/dimacs.cpp
  src/luby.cpp)
add_library(sat::satlib ALIAS satlib)
target_include_directories(satlib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(satlib PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(satlib PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- command-line tool -----------------------------------------------------
if(SAT_BUILD_CLI)
  add_executable(sat_cli cli/main.cpp)
  target_link_libraries(sat_cli PRIVATE satlib)
  set_target_properties(sat_cli PROPERTIES OUTPUT_NAME sat)
  install(TARGETS sat_cli RUNTIME DESTINATION bin)
endif()

install(TARGETS satlib ARCHIVE DESTINATION lib)
install(DIRECTORY include/sat DESTINATION include)

# ---- tests -----------------------------------------------------------------
if(SAT_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(sat_tests
    tests/test_heap.cpp
    tests/test_luby.cpp
    tests/test_types.cpp
    tests/test_dimacs.cpp
    tests/test_solver.cpp)
  target_link_libraries(sat_tests PRIVATE satlib GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(sat_tests)
endif()
