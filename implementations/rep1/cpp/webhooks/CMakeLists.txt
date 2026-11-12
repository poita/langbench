cmake_minimum_required(VERSION 3.20)
project(webhooks VERSION 1.0.0 DESCRIPTION "Standard Webhooks signing, verification and delivery simulation"
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(WEBHOOKS_BUILD_CLI "Build the webhooks command-line tool" ON)
option(WEBHOOKS_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(webhooks
  src/arguments.cpp
  src/base64.cpp
  src/hex.cpp
  src/hmac.cpp
  src/protocol.cpp
  src/secret.cpp
  src/sha256.cpp
  src/signature.cpp
  src/simulator.cpp)
add_library(webhooks::webhooks ALIAS webhooks)
target_include_directories(webhooks PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(webhooks PUBLIC cxx_std_20)
target_compile_options(webhooks PRIVATE -Wall -Wextra -Wpedantic)

if(WEBHOOKS_BUILD_CLI)
  add_executable(webhooks-cli cli/main.cpp)
  set_target_properties(webhooks-cli PROPERTIES OUTPUT_NAME webhooks)
  target_link_libraries(webhooks-cli PRIVATE webhooks::webhooks)
  install(TARGETS webhooks-cli RUNTIME DESTINATION bin)
endif()

install(TARGETS webhooks ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(WEBHOOKS_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found: unit tests are not built")
  endif()
endif()

add_executable(webhooks-example EXCLUDE_FROM_ALL examples/example.cpp)
target_link_libraries(webhooks-example PRIVATE webhooks::webhooks)
