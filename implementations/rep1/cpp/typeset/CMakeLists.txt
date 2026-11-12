cmake_minimum_required(VERSION 3.20)
project(typeset VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TYPESET_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(typeset
  src/util.cpp
  src/font.cpp
  src/hyphenation.cpp
  src/settings.cpp
  src/document.cpp
  src/hlist.cpp
  src/linebreak.cpp
  src/layout.cpp
  src/paginate.cpp
  src/output.cpp
  src/typeset.cpp)
target_include_directories(typeset PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(typeset PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(typeset PRIVATE -Wall -Wextra)
endif()

add_executable(typeset-cli cli/main.cpp)
set_target_properties(typeset-cli PROPERTIES OUTPUT_NAME typeset)
target_link_libraries(typeset-cli PRIVATE typeset)

install(TARGETS typeset typeset-cli
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)
install(DIRECTORY include/typeset DESTINATION include)

if(TYPESET_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_subdirectory(tests)
endif()
