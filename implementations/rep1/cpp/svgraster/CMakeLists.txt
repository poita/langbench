cmake_minimum_required(VERSION 3.20)
project(svgraster VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SVGRASTER_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(svgraster
  src/xml.cpp
  src/parse.cpp
  src/path.cpp
  src/shapes.cpp
  src/stroke.cpp
  src/raster.cpp
  src/style.cpp
  src/render.cpp)
add_library(svgraster::svgraster ALIAS svgraster)
target_include_directories(svgraster PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(svgraster PUBLIC cxx_std_17)
target_compile_options(svgraster PRIVATE -Wall -Wextra)

add_executable(svgraster_cli cli/main.cpp)
set_target_properties(svgraster_cli PROPERTIES OUTPUT_NAME svgraster)
target_link_libraries(svgraster_cli PRIVATE svgraster)

install(TARGETS svgraster svgraster_cli
  ARCHIVE DESTINATION lib RUNTIME DESTINATION bin)
install(DIRECTORY include/ DESTINATION include)

if(SVGRASTER_BUILD_TESTS)
  enable_testing()
  find_package(GTest)
  if(GTest_FOUND)
    add_subdirectory(tests)
  else()
    message(STATUS "GoogleTest not found: tests disabled")
  endif()
endif()
