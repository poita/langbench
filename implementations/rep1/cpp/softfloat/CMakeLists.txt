cmake_minimum_required(VERSION 3.20)
project(softfloat VERSION 1.0.0 DESCRIPTION "Software IEEE-754 binary32 arithmetic" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SOFTFLOAT_BUILD_CLI "Build the softfloat_cli command-line tool" ON)
option(SOFTFLOAT_BUILD_EXAMPLES "Build the example programs" ON)
option(SOFTFLOAT_BUILD_TESTS "Build the GoogleTest unit tests" ON)

# ---- library ---------------------------------------------------------------
add_library(softfloat
  src/add.cpp
  src/mul.cpp
  src/div.cpp
  src/sqrt.cpp
  src/round_pack.cpp
  src/line.cpp)
add_library(softfloat::softfloat ALIAS softfloat)
target_include_directories(softfloat
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
          $<INSTALL_INTERFACE:include>
  PRIVATE src)
target_compile_features(softfloat PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(softfloat PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- command-line tool -----------------------------------------------------
if(SOFTFLOAT_BUILD_CLI)
  add_executable(softfloat_cli cli/main.cpp)
  target_link_libraries(softfloat_cli PRIVATE softfloat::softfloat)
  install(TARGETS softfloat_cli RUNTIME DESTINATION bin)
endif()

if(SOFTFLOAT_BUILD_EXAMPLES)
  add_executable(softfloat_example examples/basic.cpp)
  target_link_libraries(softfloat_example PRIVATE softfloat::softfloat)
endif()

# ---- tests -----------------------------------------------------------------
if(SOFTFLOAT_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_executable(softfloat_tests
      tests/test_special.cpp
      tests/test_rounding.cpp
      tests/test_reference.cpp
      tests/test_line.cpp)
    target_link_libraries(softfloat_tests PRIVATE softfloat::softfloat GTest::gtest_main)
    # GoogleTest 1.15 headers trigger a harmless clang warning under C++20.
    target_compile_options(softfloat_tests PRIVATE $<$<CXX_COMPILER_ID:Clang,AppleClang>:-Wno-character-conversion>)
    include(GoogleTest)
    gtest_discover_tests(softfloat_tests)
  else()
    message(STATUS "GoogleTest not found; unit tests disabled")
  endif()
endif()

# ---- install ---------------------------------------------------------------
install(TARGETS softfloat ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
