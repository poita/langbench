cmake_minimum_required(VERSION 3.20)
project(typeinfer VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TYPEINFER_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(typeinfer_lib STATIC
  src/lexer.cpp
  src/parser.cpp
  src/types.cpp
  src/printer.cpp
  src/inference.cpp
  src/session.cpp)
add_library(typeinfer::lib ALIAS typeinfer_lib)
target_include_directories(typeinfer_lib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(typeinfer_lib PUBLIC cxx_std_20)
target_compile_options(typeinfer_lib PRIVATE -Wall -Wextra)

add_executable(typeinfer cli/main.cpp)
target_link_libraries(typeinfer PRIVATE typeinfer_lib)

if(TYPEINFER_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found: unit tests are not built")
  endif()
endif()
