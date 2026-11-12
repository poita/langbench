cmake_minimum_required(VERSION 3.20)
project(qrcode VERSION 1.0.0 DESCRIPTION "QR Code Model 2 encoder" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(QRCODE_BUILD_CLI "Build the command-line tool" ON)
option(QRCODE_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(qrcode
  src/bit_buffer.cpp
  src/tables.cpp
  src/segment.cpp
  src/reed_solomon.cpp
  src/codewords.cpp
  src/matrix.cpp
  src/penalty.cpp
  src/qrcode.cpp)
add_library(qrcode::qrcode ALIAS qrcode)
target_include_directories(qrcode PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(qrcode PUBLIC cxx_std_20)
target_compile_options(qrcode PRIVATE -Wall -Wextra)

if(QRCODE_BUILD_CLI)
  add_executable(qrcode-cli cli/main.cpp)
  target_link_libraries(qrcode-cli PRIVATE qrcode::qrcode)
  target_compile_options(qrcode-cli PRIVATE -Wall -Wextra)
endif()

if(QRCODE_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(qrcode-tests
    tests/bit_buffer_test.cpp
    tests/tables_test.cpp
    tests/segment_test.cpp
    tests/reed_solomon_test.cpp
    tests/matrix_test.cpp
    tests/qrcode_test.cpp)
  target_link_libraries(qrcode-tests PRIVATE qrcode::qrcode GTest::gtest GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(qrcode-tests)
endif()

install(TARGETS qrcode ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
if(QRCODE_BUILD_CLI)
  install(TARGETS qrcode-cli RUNTIME DESTINATION bin)
endif()
