cmake_minimum_required(VERSION 3.20)
project(ordered_map VERSION 1.0.0 DESCRIPTION "Balanced (AVL) ordered map with order statistics" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(ORDERED_MAP_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(ordered_map
  src/ordered_map.cpp
  src/command_processor.cpp)
add_library(ordered_map::ordered_map ALIAS ordered_map)
target_include_directories(ordered_map PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(ordered_map PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(ordered_map PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(ordered_map_cli cli/main.cpp)
set_target_properties(ordered_map_cli PROPERTIES OUTPUT_NAME ordered-map)
target_link_libraries(ordered_map_cli PRIVATE ordered_map)

include(GNUInstallDirs)
install(TARGETS ordered_map_cli RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(TARGETS ordered_map ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(ORDERED_MAP_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
