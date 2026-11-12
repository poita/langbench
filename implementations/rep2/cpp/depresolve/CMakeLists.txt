cmake_minimum_required(VERSION 3.20)
project(depresolve VERSION 1.0.0 LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(DEPRESOLVE_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)
option(DEPRESOLVE_BUILD_EXAMPLES "Build the examples" ON)

add_library(depresolve
  src/version.cpp
  src/range.cpp
  src/registry.cpp
  src/parser.cpp
  src/resolver.cpp)
add_library(depresolve::depresolve ALIAS depresolve)
target_include_directories(depresolve PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(depresolve PUBLIC cxx_std_20)
target_compile_options(depresolve PRIVATE -Wall -Wextra -Wpedantic)

add_executable(depresolve_cli cli/main.cpp)
set_target_properties(depresolve_cli PROPERTIES OUTPUT_NAME depresolve)
target_link_libraries(depresolve_cli PRIVATE depresolve)
target_compile_options(depresolve_cli PRIVATE -Wall -Wextra -Wpedantic)

if(DEPRESOLVE_BUILD_EXAMPLES)
  add_executable(library_usage examples/library_usage.cpp)
  target_link_libraries(library_usage PRIVATE depresolve)
endif()

include(GNUInstallDirs)
install(TARGETS depresolve depresolve_cli
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

if(DEPRESOLVE_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found: tests are not built")
  endif()
endif()
