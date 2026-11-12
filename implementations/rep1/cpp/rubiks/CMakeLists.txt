cmake_minimum_required(VERSION 3.20)
project(rubiks VERSION 1.0.0 DESCRIPTION "Thistlethwaite Rubik's cube solver" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(RUBIKS_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)
option(RUBIKS_BUILD_EXAMPLES "Build the library usage example" ON)

# ---- library ---------------------------------------------------------------
add_library(rubiks_lib
  src/move.cpp
  src/facelet.cpp
  src/cubie.cpp
  src/coordinates.cpp
  src/phase_tables.cpp
  src/solver.cpp)
add_library(rubiks::rubiks ALIAS rubiks_lib)
set_target_properties(rubiks_lib PROPERTIES OUTPUT_NAME rubiks)
target_include_directories(rubiks_lib
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
          $<INSTALL_INTERFACE:include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_features(rubiks_lib PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(rubiks_lib PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- command-line tool -----------------------------------------------------
add_executable(rubiks_cli cli/main.cpp)
set_target_properties(rubiks_cli PROPERTIES OUTPUT_NAME rubiks)
target_link_libraries(rubiks_cli PRIVATE rubiks::rubiks)

# ---- example ---------------------------------------------------------------
if(RUBIKS_BUILD_EXAMPLES)
  add_executable(rubiks_example examples/solve_one.cpp)
  target_link_libraries(rubiks_example PRIVATE rubiks::rubiks)
endif()

# ---- tests -----------------------------------------------------------------
if(RUBIKS_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_executable(rubiks_tests
      tests/move_test.cpp
      tests/facelet_test.cpp
      tests/cubie_test.cpp
      tests/solver_test.cpp)
    target_link_libraries(rubiks_tests PRIVATE rubiks::rubiks GTest::gtest GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(rubiks_tests DISCOVERY_MODE PRE_TEST)
  else()
    message(WARNING "GoogleTest not found; unit tests are not built")
  endif()
endif()

# ---- install ---------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS rubiks_lib rubiks_cli
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
