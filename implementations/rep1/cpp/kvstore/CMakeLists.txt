cmake_minimum_required(VERSION 3.20)
project(tessera VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TESSERA_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(tessera
  src/btree.cpp
  src/crc32.cpp
  src/database.cpp
  src/error.cpp
  src/executor.cpp
  src/header.cpp
  src/index_key.cpp
  src/lexer.cpp
  src/node.cpp
  src/overflow.cpp
  src/pager.cpp
  src/parser.cpp
  src/query.cpp
  src/render.cpp
  src/value.cpp
  src/wal.cpp)
target_include_directories(tessera PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(tessera PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(tessera PRIVATE -Wall -Wextra)
endif()

add_executable(tessera-cli tools/main.cpp)
target_link_libraries(tessera-cli PRIVATE tessera)

if(TESSERA_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  include(GoogleTest)
  add_executable(tessera-tests
    tests/btree_test.cpp
    tests/crc32_test.cpp
    tests/database_test.cpp
    tests/executor_test.cpp
    tests/parser_test.cpp
    tests/value_test.cpp
    tests/wal_test.cpp)
  target_link_libraries(tessera-tests PRIVATE tessera GTest::gtest_main)
  gtest_discover_tests(tessera-tests)
endif()

install(TARGETS tessera tessera-cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)
