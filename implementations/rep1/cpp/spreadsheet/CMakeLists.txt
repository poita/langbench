cmake_minimum_required(VERSION 3.20)
project(spreadsheet VERSION 1.0.0 DESCRIPTION "Spreadsheet engine with incremental recalculation" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SPREADSHEET_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(spreadsheet
  src/cell_ref.cpp
  src/value.cpp
  src/formula.cpp
  src/parser.cpp
  src/evaluator.cpp
  src/sheet.cpp
  src/script.cpp)
add_library(spreadsheet::spreadsheet ALIAS spreadsheet)
target_include_directories(spreadsheet PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(spreadsheet PUBLIC cxx_std_17)
target_compile_options(spreadsheet PRIVATE -Wall -Wextra)

add_executable(ssheet cli/main.cpp)
target_link_libraries(ssheet PRIVATE spreadsheet)

install(TARGETS spreadsheet ssheet
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(SPREADSHEET_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_executable(spreadsheet_tests
      tests/cell_ref_test.cpp
      tests/value_test.cpp
      tests/parser_test.cpp
      tests/evaluator_test.cpp
      tests/sheet_test.cpp
      tests/script_test.cpp)
    target_link_libraries(spreadsheet_tests PRIVATE spreadsheet GTest::gtest GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(spreadsheet_tests)
  else()
    message(WARNING "GoogleTest not found; unit tests are disabled")
  endif()
endif()
