cmake_minimum_required(VERSION 3.20)
project(kiln VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(KILN_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(kiln
  src/ast.cpp
  src/builtins.cpp
  src/commands.cpp
  src/engine.cpp
  src/error.cpp
  src/glob.cpp
  src/graph.cpp
  src/hash.cpp
  src/interp.cpp
  src/lexer.cpp
  src/parser.cpp
  src/path.cpp
  src/session.cpp
  src/state.cpp
  src/value.cpp
  src/vfs.cpp)
target_include_directories(kiln PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_options(kiln PRIVATE -Wall -Wextra)

add_executable(kiln-cli cli/main.cpp)
set_target_properties(kiln-cli PROPERTIES OUTPUT_NAME kiln)
target_link_libraries(kiln-cli PRIVATE kiln)

install(TARGETS kiln-cli RUNTIME DESTINATION bin)
install(TARGETS kiln ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(KILN_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(STATUS "GoogleTest not found; unit tests disabled")
  endif()
endif()
