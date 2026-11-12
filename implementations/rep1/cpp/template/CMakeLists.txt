cmake_minimum_required(VERSION 3.20)
project(jinjalite VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(JINJALITE_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(jinjalite
  src/document.cpp
  src/engine.cpp
  src/error.cpp
  src/filters.cpp
  src/format.cpp
  src/interpreter.cpp
  src/json.cpp
  src/lexer.cpp
  src/ops.cpp
  src/parser.cpp
  src/scope.cpp
  src/value.cpp)
target_include_directories(jinjalite PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(jinjalite PUBLIC cxx_std_20)
target_compile_options(jinjalite PRIVATE -Wall -Wextra)

add_executable(jinjalite_cli cli/main.cpp)
target_link_libraries(jinjalite_cli PRIVATE jinjalite)
set_target_properties(jinjalite_cli PROPERTIES OUTPUT_NAME jinjalite)

install(TARGETS jinjalite jinjalite_cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(JINJALITE_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
