cmake_minimum_required(VERSION 3.20)
project(regex_engine VERSION 1.0.0 LANGUAGES CXX
        DESCRIPTION "A backtracking regular-expression engine with Perl-style semantics")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(REGEX_BUILD_CLI "Build the command-line tool" ON)
option(REGEX_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

# ---------------------------------------------------------------- library
add_library(regex_engine
  src/charset.cpp
  src/parser.cpp
  src/analysis.cpp
  src/compiler.cpp
  src/matcher.cpp
  src/regex.cpp)
add_library(regex::engine ALIAS regex_engine)
target_include_directories(regex_engine PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(regex_engine PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(regex_engine PRIVATE -Wall -Wextra -Wpedantic)
endif()

# -------------------------------------------------------------------- CLI
if(REGEX_BUILD_CLI)
  add_library(regex_batch STATIC cli/batch.cpp)
  target_include_directories(regex_batch PUBLIC cli)
  target_link_libraries(regex_batch PUBLIC regex::engine)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(regex_batch PRIVATE -Wall -Wextra -Wpedantic)
  endif()

  add_executable(regex_cli cli/main.cpp)
  target_link_libraries(regex_cli PRIVATE regex_batch)
  set_target_properties(regex_cli PROPERTIES
    OUTPUT_NAME regex
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
  install(TARGETS regex_cli RUNTIME DESTINATION bin)
endif()

# ------------------------------------------------------------------ tests
if(REGEX_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found; unit tests are not built")
  endif()
endif()

# ---------------------------------------------------------------- install
install(TARGETS regex_engine ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
