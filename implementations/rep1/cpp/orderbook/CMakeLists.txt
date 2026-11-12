cmake_minimum_required(VERSION 3.20)
project(orderbook VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(ORDERBOOK_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)
option(ORDERBOOK_BUILD_EXAMPLES "Build the library usage example" ON)

# ---- library -------------------------------------------------------------
add_library(orderbook
  src/event.cpp
  src/order_book.cpp
  src/command.cpp
  src/text_writer.cpp
  src/session.cpp)
add_library(orderbook::orderbook ALIAS orderbook)
target_include_directories(orderbook PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(orderbook PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(orderbook PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---- command-line tool -----------------------------------------------------
add_executable(orderbook-cli cli/main.cpp)
set_target_properties(orderbook-cli PROPERTIES OUTPUT_NAME orderbook)
target_link_libraries(orderbook-cli PRIVATE orderbook::orderbook)

# ---- example ----------------------------------------------------------------
if(ORDERBOOK_BUILD_EXAMPLES)
  add_executable(orderbook-example examples/library_usage.cpp)
  target_link_libraries(orderbook-example PRIVATE orderbook::orderbook)
endif()

# ---- tests --------------------------------------------------------------------
if(ORDERBOOK_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(orderbook-tests
    tests/command_test.cpp
    tests/order_book_test.cpp
    tests/session_test.cpp
    tests/random_test.cpp)
  target_link_libraries(orderbook-tests PRIVATE orderbook::orderbook GTest::gtest_main)
  if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(orderbook-tests PRIVATE -Wno-character-conversion)  # noisy in GoogleTest headers under C++20
  endif()
  include(GoogleTest)
  gtest_discover_tests(orderbook-tests)
endif()

# ---- install ------------------------------------------------------------------
install(TARGETS orderbook orderbook-cli ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)
