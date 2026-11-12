cmake_minimum_required(VERSION 3.20)
project(spiremark VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(SPIREMARK_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

add_library(spiremark
  src/sexpr.cpp
  src/card.cpp
  src/database.cpp
  src/script.cpp
  src/game_state.cpp
  src/game_effects.cpp
  src/game_chain.cpp
  src/game_turn.cpp
  src/game_report.cpp
  src/session.cpp)
add_library(spiremark::spiremark ALIAS spiremark)
target_include_directories(spiremark PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_options(spiremark PRIVATE -Wall -Wextra)

add_executable(spiremark-cli cli/main.cpp)
target_link_libraries(spiremark-cli PRIVATE spiremark)
set_target_properties(spiremark-cli PROPERTIES OUTPUT_NAME spiremark)

install(TARGETS spiremark-cli RUNTIME DESTINATION bin)
install(TARGETS spiremark ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(SPIREMARK_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_subdirectory(tests)
endif()
