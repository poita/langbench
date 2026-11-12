cmake_minimum_required(VERSION 3.20)
project(inflate VERSION 1.0.0 DESCRIPTION "A from-scratch DEFLATE (RFC 1951) decoder" LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(INFLATE_BUILD_CLI "Build the command-line tool" ON)
option(INFLATE_BUILD_TESTS "Build the unit tests" ON)

add_library(inflate
  src/error.cpp
  src/hex.cpp
  src/huffman.cpp
  src/inflate.cpp)
add_library(inflate::inflate ALIAS inflate)
target_include_directories(inflate PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(inflate PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(inflate PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(INFLATE_BUILD_CLI)
  add_executable(inflate_cli cli/main.cpp)
  set_target_properties(inflate_cli PROPERTIES OUTPUT_NAME inflate)
  target_link_libraries(inflate_cli PRIVATE inflate::inflate)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(inflate_cli PRIVATE -Wall -Wextra -Wpedantic)
  endif()
endif()

include(GNUInstallDirs)
install(TARGETS inflate ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
if(INFLATE_BUILD_CLI)
  install(TARGETS inflate_cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

if(INFLATE_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
