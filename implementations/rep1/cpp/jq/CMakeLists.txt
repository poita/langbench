cmake_minimum_required(VERSION 3.20)
project(jqcpp VERSION 1.0.0 LANGUAGES CXX
        DESCRIPTION "A jq-subset query language: library and command-line tool")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(JQCPP_BUILD_CLI "Build the command-line tool" ON)
option(JQCPP_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

# ---- library ---------------------------------------------------------------
add_library(jqcpp
  src/value.cpp
  src/json.cpp
  src/parser.cpp
  src/ops.cpp
  src/interpreter.cpp
  src/filter.cpp)
add_library(jqcpp::jqcpp ALIAS jqcpp)
target_include_directories(jqcpp
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
          $<INSTALL_INTERFACE:include>
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_features(jqcpp PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(jqcpp PRIVATE -Wall -Wextra)
endif()

# ---- command-line tool -----------------------------------------------------
if(JQCPP_BUILD_CLI)
  add_executable(jqcpp-cli cli/main.cpp)
  set_target_properties(jqcpp-cli PROPERTIES OUTPUT_NAME jqcpp)
  target_link_libraries(jqcpp-cli PRIVATE jqcpp)
  install(TARGETS jqcpp-cli RUNTIME DESTINATION bin)
endif()

install(TARGETS jqcpp ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

# ---- tests -----------------------------------------------------------------
if(JQCPP_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(jqcpp-tests
    tests/value_test.cpp
    tests/json_test.cpp
    tests/parser_test.cpp
    tests/eval_test.cpp)
  target_link_libraries(jqcpp-tests PRIVATE jqcpp GTest::gtest_main)
  target_compile_options(jqcpp-tests PRIVATE -Wno-character-conversion)
  include(GoogleTest)
  gtest_discover_tests(jqcpp-tests)
endif()
