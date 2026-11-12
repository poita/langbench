cmake_minimum_required(VERSION 3.20)
project(jsonschema VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(JSONSCHEMA_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(jsonschema
  src/compiler.cpp
  src/decimal.cpp
  src/evaluator.cpp
  src/json.cpp
  src/regex.cpp
  src/schema.cpp
  src/uri.cpp
  src/utf8.cpp)
add_library(jsonschema::jsonschema ALIAS jsonschema)
target_include_directories(jsonschema
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  PRIVATE src)
target_compile_features(jsonschema PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(jsonschema PRIVATE -Wall -Wextra)
endif()

find_package(Threads REQUIRED)
add_executable(jsonschema-cli cli/main.cpp)
target_link_libraries(jsonschema-cli PRIVATE jsonschema Threads::Threads)

if(JSONSCHEMA_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(STATUS "GoogleTest not found: unit tests are not built")
  endif()
endif()
