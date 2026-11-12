cmake_minimum_required(VERSION 3.20)
project(kiln VERSION 1.0.0 DESCRIPTION "Kiln, an incremental build system simulator" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(KILN_BUILD_CLI "Build the kiln command-line tool" ON)
option(KILN_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(kiln_lib STATIC
  src/builtins.cpp
  src/build.cpp
  src/commands.cpp
  src/error.cpp
  src/evaluator.cpp
  src/glob.cpp
  src/graph.cpp
  src/hash.cpp
  src/lexer.cpp
  src/parser.cpp
  src/path.cpp
  src/scheduler.cpp
  src/session.cpp
  src/state.cpp
  src/step.cpp
  src/value.cpp
  src/vfs.cpp)
add_library(kiln::kiln ALIAS kiln_lib)
set_target_properties(kiln_lib PROPERTIES OUTPUT_NAME kiln)
target_include_directories(kiln_lib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(kiln_lib PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(kiln_lib PRIVATE -Wall -Wextra)
endif()

if(KILN_BUILD_CLI)
  add_executable(kiln_cli cli/main.cpp)
  set_target_properties(kiln_cli PROPERTIES OUTPUT_NAME kiln)
  target_link_libraries(kiln_cli PRIVATE kiln::kiln)
  install(TARGETS kiln_cli RUNTIME DESTINATION bin)
endif()

install(TARGETS kiln_lib ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(KILN_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found; unit tests are disabled")
  endif()
endif()
