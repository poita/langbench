cmake_minimum_required(VERSION 3.20)
project(sqlitefile VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SQLITEFILE_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(sqlitefile
  src/btree.cpp
  src/database.cpp
  src/ddl.cpp
  src/pager.cpp
  src/query.cpp
  src/record.cpp
  src/schema.cpp
  src/value.cpp)
add_library(sqlitefile::sqlitefile ALIAS sqlitefile)
target_include_directories(sqlitefile PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(sqlitefile PUBLIC cxx_std_20)
target_compile_options(sqlitefile PRIVATE -Wall -Wextra)

add_executable(sqlitefile_cli tools/sqlitefile_cli.cpp)
target_link_libraries(sqlitefile_cli PRIVATE sqlitefile::sqlitefile)
target_compile_options(sqlitefile_cli PRIVATE -Wall -Wextra)

install(TARGETS sqlitefile sqlitefile_cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(SQLITEFILE_BUILD_TESTS)
  find_package(GTest)
  if(GTest_FOUND)
    enable_testing()
    add_subdirectory(tests)
  else()
    message(WARNING "GoogleTest not found; unit tests are not built")
  endif()
endif()
