cmake_minimum_required(VERSION 3.20)
project(minisql VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(MINISQL_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(minisql_lib
  src/binder.cpp
  src/database.cpp
  src/eval.cpp
  src/lexer.cpp
  src/like.cpp
  src/mutate.cpp
  src/parser.cpp
  src/select.cpp
  src/value.cpp)
add_library(minisql::minisql ALIAS minisql_lib)
set_target_properties(minisql_lib PROPERTIES OUTPUT_NAME minisql)
target_include_directories(minisql_lib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(minisql_lib PUBLIC cxx_std_17)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(minisql_lib PRIVATE -Wall -Wextra)
endif()

add_executable(minisql cli/main.cpp)
target_link_libraries(minisql PRIVATE minisql_lib)

install(TARGETS minisql_lib minisql
  ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(MINISQL_BUILD_TESTS)
  find_package(GTest QUIET)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found; unit tests disabled")
  endif()
endif()
