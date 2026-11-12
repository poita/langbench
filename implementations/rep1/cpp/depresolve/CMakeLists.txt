cmake_minimum_required(VERSION 3.20)
project(depresolve VERSION 1.0.0 DESCRIPTION "Deterministic package dependency resolver" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(DEPRESOLVE_BUILD_CLI "Build the depresolve command-line tool" ON)
option(DEPRESOLVE_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(depresolve_lib
  src/version.cpp
  src/range.cpp
  src/registry.cpp
  src/parser.cpp
  src/resolver.cpp
  src/output.cpp)
add_library(depresolve::lib ALIAS depresolve_lib)
target_include_directories(depresolve_lib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(depresolve_lib PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(depresolve_lib PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(DEPRESOLVE_BUILD_CLI)
  add_executable(depresolve cli/main.cpp)
  target_link_libraries(depresolve PRIVATE depresolve_lib)
  install(TARGETS depresolve RUNTIME DESTINATION bin)
endif()

install(TARGETS depresolve_lib ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(DEPRESOLVE_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_executable(depresolve_tests
      tests/version_test.cpp
      tests/range_test.cpp
      tests/parser_test.cpp
      tests/resolver_test.cpp
      tests/output_test.cpp)
    target_link_libraries(depresolve_tests PRIVATE depresolve_lib GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(depresolve_tests)
  else()
    message(WARNING "GoogleTest not found; unit tests are not built")
  endif()
endif()
