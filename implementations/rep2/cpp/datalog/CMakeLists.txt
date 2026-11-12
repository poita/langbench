cmake_minimum_required(VERSION 3.20)
project(datalog VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(DATALOG_BUILD_TESTS "Build the unit tests" ON)

add_library(datalog_lib
  src/ast.cpp
  src/parser.cpp
  src/analysis.cpp
  src/relation.cpp
  src/engine.cpp)
add_library(datalog::lib ALIAS datalog_lib)
target_include_directories(datalog_lib PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_options(datalog_lib PRIVATE -Wall -Wextra)

add_executable(datalog src/main.cpp)
target_link_libraries(datalog PRIVATE datalog_lib)

install(TARGETS datalog datalog_lib
  RUNTIME DESTINATION bin
  ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(DATALOG_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(STATUS "GoogleTest not found: tests disabled")
  endif()
endif()
