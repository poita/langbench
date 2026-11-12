cmake_minimum_required(VERSION 3.20)
project(jsoncanon VERSION 1.0.0 LANGUAGES CXX
        DESCRIPTION "Strict JSON parser and canonical serializer")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(PROJECT_IS_TOP_LEVEL)
  set(_default_tests ON)
else()
  set(_default_tests OFF)
endif()
option(JSONCANON_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ${_default_tests})
option(JSONCANON_BUILD_CLI "Build the jsoncanon command-line tool" ON)

# ---- library ---------------------------------------------------------------
add_library(jsoncanon
  src/utf8.cpp
  src/value.cpp
  src/parser.cpp
  src/serializer.cpp
  src/canonicalize.cpp)
add_library(jsoncanon::jsoncanon ALIAS jsoncanon)
target_include_directories(jsoncanon PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(jsoncanon PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(jsoncanon PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- CLI -------------------------------------------------------------------
if(JSONCANON_BUILD_CLI)
  add_executable(jsoncanon-cli cli/main.cpp)
  set_target_properties(jsoncanon-cli PROPERTIES OUTPUT_NAME jsoncanon)
  target_link_libraries(jsoncanon-cli PRIVATE jsoncanon)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(jsoncanon-cli PRIVATE -Wall -Wextra -Wpedantic)
  endif()
endif()

# ---- tests -----------------------------------------------------------------
if(JSONCANON_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_executable(jsoncanon_tests
      tests/utf8_test.cpp
      tests/parser_test.cpp
      tests/serializer_test.cpp
      tests/canonicalize_test.cpp)
    target_link_libraries(jsoncanon_tests PRIVATE jsoncanon GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(jsoncanon_tests)
  else()
    message(WARNING "GoogleTest not found: unit tests will not be built")
  endif()
endif()

# ---- install ---------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS jsoncanon ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
if(JSONCANON_BUILD_CLI)
  install(TARGETS jsoncanon-cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()
