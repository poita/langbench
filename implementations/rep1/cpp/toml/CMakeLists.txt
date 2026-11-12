cmake_minimum_required(VERSION 3.20)
project(toml VERSION 1.0.0 DESCRIPTION "TOML 1.0.0 parser and serializer" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TOML_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

# --- library -----------------------------------------------------------------
add_library(toml
  src/datetime.cpp
  src/number.cpp
  src/parser.cpp
  src/tagged_json.cpp
  src/utf8.cpp
  src/value.cpp
  src/writer.cpp)
add_library(toml::toml ALIAS toml)
target_include_directories(toml PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(toml PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(toml PRIVATE -Wall -Wextra -Wpedantic)
endif()

# --- command-line tool --------------------------------------------------------
add_executable(toml-tool cli/main.cpp)
target_link_libraries(toml-tool PRIVATE toml::toml)

# --- install -----------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS toml toml-tool
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/toml DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

# --- tests -------------------------------------------------------------------
if(TOML_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(toml_tests
    tests/datetime_test.cpp
    tests/number_test.cpp
    tests/parser_test.cpp
    tests/roundtrip_test.cpp
    tests/tagged_json_test.cpp
    tests/utf8_test.cpp
    tests/writer_test.cpp)
  target_link_libraries(toml_tests PRIVATE toml::toml GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(toml_tests)
endif()
