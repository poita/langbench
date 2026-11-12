cmake_minimum_required(VERSION 3.20)
project(scheme VERSION 1.0.0 DESCRIPTION "A small Scheme interpreter" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SCHEME_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

# ---- library ---------------------------------------------------------------
add_library(scheme
  src/bigint.cpp
  src/value.cpp
  src/numeric.cpp
  src/reader.cpp
  src/printer.cpp
  src/analyzer.cpp
  src/primitives.cpp
  src/interpreter.cpp
  src/stack.cpp)
add_library(scheme::scheme ALIAS scheme)
target_include_directories(scheme PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_options(scheme PRIVATE -Wall -Wextra)
find_package(Threads REQUIRED)
target_link_libraries(scheme PRIVATE Threads::Threads)

# ---- command-line tool -----------------------------------------------------
add_executable(scheme-cli cli/main.cpp)
set_target_properties(scheme-cli PROPERTIES OUTPUT_NAME scheme)
target_link_libraries(scheme-cli PRIVATE scheme::scheme)
target_compile_options(scheme-cli PRIVATE -Wall -Wextra)

# ---- install ---------------------------------------------------------------
install(TARGETS scheme scheme-cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

# ---- tests -----------------------------------------------------------------
if(SCHEME_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
