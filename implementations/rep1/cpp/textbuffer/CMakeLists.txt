cmake_minimum_required(VERSION 3.20)
project(textbuffer VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TEXTBUFFER_BUILD_TESTS "Build the unit tests" ON)

add_library(textbuffer
  src/position.cpp
  src/document.cpp
  src/cursor.cpp
  src/movement.cpp
  src/editor.cpp
  src/command.cpp
  src/script.cpp)
add_library(textbuffer::textbuffer ALIAS textbuffer)
target_include_directories(textbuffer PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(textbuffer PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(textbuffer PRIVATE -Wall -Wextra)
endif()

add_executable(textbuffer_cli cli/main.cpp)
set_target_properties(textbuffer_cli PROPERTIES OUTPUT_NAME textbuffer-cli)
target_link_libraries(textbuffer_cli PRIVATE textbuffer)

install(TARGETS textbuffer textbuffer_cli)
install(DIRECTORY include/ DESTINATION include)

if(TEXTBUFFER_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(textbuffer_tests
    tests/document_test.cpp
    tests/cursor_test.cpp
    tests/movement_test.cpp
    tests/editor_test.cpp
    tests/command_test.cpp
    tests/script_test.cpp)
  target_link_libraries(textbuffer_tests PRIVATE textbuffer GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(textbuffer_tests)
endif()
