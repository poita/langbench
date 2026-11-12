cmake_minimum_required(VERSION 3.20)
project(commonmark VERSION 1.0.0 DESCRIPTION "A CommonMark subset to HTML converter" LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(COMMONMARK_BUILD_CLI "Build the commonmark-cli command-line tool" ON)
option(COMMONMARK_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

# ---- library ----------------------------------------------------------------
add_library(commonmark
  src/node.cpp
  src/text_util.cpp
  src/block_parser.cpp
  src/inline_parser.cpp
  src/html_renderer.cpp
  src/parser.cpp)
add_library(commonmark::commonmark ALIAS commonmark)
target_compile_features(commonmark PUBLIC cxx_std_17)
set_target_properties(commonmark PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(commonmark
  PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
         $<INSTALL_INTERFACE:include>)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(commonmark PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- command-line tool ---------------------------------------------------------
if(COMMONMARK_BUILD_CLI)
  add_executable(commonmark-cli cli/main.cpp)
  target_link_libraries(commonmark-cli PRIVATE commonmark::commonmark)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(commonmark-cli PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  install(TARGETS commonmark-cli RUNTIME DESTINATION bin)
endif()

# ---- tests -----------------------------------------------------------------------
if(COMMONMARK_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found; the unit tests will not be built")
  endif()
endif()

# ---- install -----------------------------------------------------------------------
install(TARGETS commonmark ARCHIVE DESTINATION lib)
install(DIRECTORY include/commonmark DESTINATION include)
