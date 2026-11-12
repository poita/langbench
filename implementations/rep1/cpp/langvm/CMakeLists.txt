cmake_minimum_required(VERSION 3.20)
project(langvm VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(LANGVM_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(langvm
  src/diagnostic.cpp
  src/utf8.cpp
  src/source.cpp
  src/lexer.cpp
  src/parser.cpp
  src/types.cpp
  src/resolver.cpp
  src/traits.cpp
  src/checker.cpp
  src/check_expr.cpp
  src/check_pattern.cpp
  src/exhaustive.cpp
  src/compiler.cpp
  src/value.cpp
  src/vm.cpp
  src/numfmt.cpp
  src/builtins.cpp
  src/builtin_sigs.cpp
  src/api.cpp
)
target_include_directories(langvm PUBLIC include PRIVATE src)
target_compile_features(langvm PUBLIC cxx_std_20)
target_compile_options(langvm PRIVATE -Wall -Wextra -ffp-contract=off)

add_executable(langvm_cli tools/main.cpp)
target_link_libraries(langvm_cli PRIVATE langvm)
set_target_properties(langvm_cli PROPERTIES OUTPUT_NAME langvm)

if(LANGVM_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(langvm_tests
    tests/test_lexer.cpp
    tests/test_diagnostics.cpp
    tests/test_programs.cpp
    tests/test_stdlib.cpp
  )
  target_include_directories(langvm_tests PRIVATE src)
  target_link_libraries(langvm_tests PRIVATE langvm GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(langvm_tests)
endif()
