cmake_minimum_required(VERSION 3.20)
project(protowire VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(PROTOWIRE_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(protowire
  src/batch.cpp
  src/decoder.cpp
  src/encoder.cpp
  src/hex.cpp
  src/schema.cpp
  src/text_format.cpp
  src/utf8.cpp
  src/value.cpp
)
add_library(protowire::protowire ALIAS protowire)
target_include_directories(protowire PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(protowire PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(protowire PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(protowire_cli cli/main.cpp)
set_target_properties(protowire_cli PROPERTIES OUTPUT_NAME protowire)
target_link_libraries(protowire_cli PRIVATE protowire::protowire)

install(TARGETS protowire_cli RUNTIME DESTINATION bin)
install(TARGETS protowire ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(PROTOWIRE_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(protowire_tests
    tests/batch_test.cpp
    tests/decoder_test.cpp
    tests/encoder_test.cpp
    tests/hex_utf8_test.cpp
    tests/schema_test.cpp
    tests/text_format_test.cpp
    tests/wire_test.cpp
  )
  target_link_libraries(protowire_tests PRIVATE protowire::protowire GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(protowire_tests)
endif()
