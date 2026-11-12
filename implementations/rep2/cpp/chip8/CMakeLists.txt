cmake_minimum_required(VERSION 3.20)
project(chip8 VERSION 1.0.0 LANGUAGES CXX
        DESCRIPTION "Deterministic CHIP-8 interpreter library and CLI")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(CHIP8_BUILD_TESTS "Build the unit tests" ON)
option(CHIP8_BUILD_CLI "Build the command-line tool" ON)

add_library(chip8
  src/display.cpp
  src/machine.cpp
  src/key_schedule.cpp
  src/program.cpp
  src/runner.cpp)
add_library(chip8::chip8 ALIAS chip8)
target_include_directories(chip8 PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(chip8 PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(chip8 PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(CHIP8_BUILD_CLI)
  add_executable(chip8_cli cli/main.cpp)
  set_target_properties(chip8_cli PROPERTIES OUTPUT_NAME chip8)
  target_link_libraries(chip8_cli PRIVATE chip8::chip8)
  install(TARGETS chip8_cli RUNTIME DESTINATION bin)
endif()

install(TARGETS chip8 ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(CHIP8_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
