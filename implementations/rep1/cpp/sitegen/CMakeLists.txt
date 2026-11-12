cmake_minimum_required(VERSION 3.20)
project(sitegen VERSION 1.0.0 DESCRIPTION "A static site generator" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SITEGEN_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

# ---- Library --------------------------------------------------------------
add_library(sitegen
  src/text.cpp
  src/toml.cpp
  src/value.cpp
  src/source.cpp
  src/model.cpp
  src/generator.cpp
  src/markdown/text.cpp
  src/markdown/blocks.cpp
  src/markdown/inlines.cpp
  src/markdown/html.cpp
  src/tmpl/parser.cpp
  src/tmpl/interpreter.cpp
  src/tmpl/engine.cpp)
add_library(sitegen::sitegen ALIAS sitegen)
target_include_directories(sitegen
  PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
          $<INSTALL_INTERFACE:include>
  PRIVATE src)
target_compile_features(sitegen PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(sitegen PRIVATE -Wall -Wextra)
endif()

# ---- Command-line tool ----------------------------------------------------
add_executable(sitegen_cli cli/main.cpp)
set_target_properties(sitegen_cli PROPERTIES OUTPUT_NAME sitegen)
target_link_libraries(sitegen_cli PRIVATE sitegen::sitegen)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(sitegen_cli PRIVATE -Wall -Wextra)
endif()

# ---- Install --------------------------------------------------------------
include(GNUInstallDirs)
install(TARGETS sitegen sitegen_cli
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/sitegen DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})

# ---- Tests ----------------------------------------------------------------
if(SITEGEN_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
