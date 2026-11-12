cmake_minimum_required(VERSION 3.20)
project(chessperft VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(CHESSPERFT_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(chessperft
  src/types.cpp
  src/move.cpp
  src/attacks.cpp
  src/position.cpp
  src/fen.cpp
  src/movegen.cpp
  src/perft.cpp
  src/query.cpp)
add_library(chessperft::chessperft ALIAS chessperft)
target_include_directories(chessperft PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(chessperft PUBLIC cxx_std_20)
target_compile_options(chessperft PRIVATE -Wall -Wextra -Wpedantic)

add_executable(chess-perft cli/main.cpp)
target_link_libraries(chess-perft PRIVATE chessperft::chessperft)

include(GNUInstallDirs)
install(TARGETS chessperft chess-perft
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(CHESSPERFT_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_subdirectory(tests)
endif()
