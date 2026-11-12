cmake_minimum_required(VERSION 3.20)
project(datalog VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(DATALOG_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)
option(DATALOG_BUILD_CLI "Build the command-line tool" ON)

add_library(datalog
  src/ast.cpp
  src/lexer.cpp
  src/parser.cpp
  src/predicates.cpp
  src/analysis.cpp
  src/value.cpp
  src/relation.cpp
  src/plan.cpp
  src/evaluator.cpp
  src/engine.cpp
  src/runner.cpp)
add_library(datalog::datalog ALIAS datalog)
target_include_directories(datalog PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(datalog PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(datalog PRIVATE -Wall -Wextra)
endif()

if(DATALOG_BUILD_CLI)
  add_executable(datalog_cli cli/main.cpp)
  target_link_libraries(datalog_cli PRIVATE datalog::datalog)
  set_target_properties(datalog_cli PROPERTIES OUTPUT_NAME datalog)
  install(TARGETS datalog_cli RUNTIME DESTINATION bin)
endif()

install(TARGETS datalog ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(DATALOG_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(datalog_tests
    tests/parser_test.cpp
    tests/analysis_test.cpp
    tests/relation_test.cpp
    tests/engine_test.cpp)
  target_link_libraries(datalog_tests PRIVATE datalog::datalog GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(datalog_tests)
endif()
