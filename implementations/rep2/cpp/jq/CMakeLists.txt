cmake_minimum_required(VERSION 3.20)
project(jqlib VERSION 1.0.0 DESCRIPTION "A jq-subset query language library and CLI" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(JQ_BUILD_TESTS "Build the unit tests" ON)

add_library(jq
  src/value.cpp
  src/json.cpp
  src/parser.cpp
  src/ops.cpp
  src/interpreter.cpp)
add_library(jq::jq ALIAS jq)
target_include_directories(jq PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_include_directories(jq PRIVATE src)
target_compile_options(jq PRIVATE -Wall -Wextra)

add_executable(jq-cli cli/main.cpp)
set_target_properties(jq-cli PROPERTIES OUTPUT_NAME jq)
target_link_libraries(jq-cli PRIVATE jq::jq)
target_compile_options(jq-cli PRIVATE -Wall -Wextra)

install(TARGETS jq-cli RUNTIME DESTINATION bin)
install(TARGETS jq ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(JQ_BUILD_TESTS)
  find_package(GTest REQUIRED)
  enable_testing()
  add_subdirectory(tests)
endif()
