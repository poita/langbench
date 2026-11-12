cmake_minimum_required(VERSION 3.20)
project(mime VERSION 1.0.0 DESCRIPTION "MIME email parser and mailbox dumper" LANGUAGES CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(MIME_BUILD_CLI "Build the command-line tool" ON)
option(MIME_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(mimelib STATIC
  src/text.cpp
  src/charset.cpp
  src/transfer.cpp
  src/rfc2047.cpp
  src/header.cpp
  src/params.cpp
  src/address.cpp
  src/date.cpp
  src/checksum.cpp
  src/message.cpp
  src/mailbox.cpp
  src/report.cpp)
add_library(mime::mimelib ALIAS mimelib)
target_include_directories(mimelib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(mimelib PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(mimelib PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(MIME_BUILD_CLI)
  add_executable(mime_cli cli/main.cpp)
  target_link_libraries(mime_cli PRIVATE mime::mimelib)
  set_target_properties(mime_cli PROPERTIES OUTPUT_NAME mime)
  install(TARGETS mime_cli RUNTIME DESTINATION bin)
endif()

install(TARGETS mimelib ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(MIME_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_executable(mime_tests
      tests/text_test.cpp
      tests/charset_test.cpp
      tests/transfer_test.cpp
      tests/rfc2047_test.cpp
      tests/header_test.cpp
      tests/params_test.cpp
      tests/address_test.cpp
      tests/date_test.cpp
      tests/message_test.cpp
      tests/mailbox_test.cpp
      tests/report_test.cpp)
    target_link_libraries(mime_tests PRIVATE mime::mimelib GTest::gtest GTest::gtest_main)
    include(GoogleTest)
    gtest_discover_tests(mime_tests)
  else()
    message(STATUS "GoogleTest not found: unit tests are not built")
  endif()
endif()
