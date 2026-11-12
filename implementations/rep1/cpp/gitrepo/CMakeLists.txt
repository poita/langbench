cmake_minimum_required(VERSION 3.20)
project(gitrepo VERSION 1.0.0 DESCRIPTION "Read a git repository straight off disk" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(GITREPO_BUILD_TESTS "Build the unit tests (needs GoogleTest)" ON)

add_library(gitrepo
  src/commands.cpp
  src/inflate.cpp
  src/object_id.cpp
  src/object_store.cpp
  src/objects.cpp
  src/quote.cpp
  src/refs.cpp
  src/repository.cpp
  src/revision.cpp
  src/sha1.cpp)
add_library(gitrepo::gitrepo ALIAS gitrepo)
target_include_directories(gitrepo PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(gitrepo PUBLIC cxx_std_20)
target_compile_options(gitrepo PRIVATE -Wall -Wextra)

add_executable(gitrepo-cli cli/main.cpp)
target_link_libraries(gitrepo-cli PRIVATE gitrepo::gitrepo)
set_target_properties(gitrepo-cli PROPERTIES OUTPUT_NAME gitrepo)

install(TARGETS gitrepo-cli RUNTIME DESTINATION bin)
install(TARGETS gitrepo ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

if(GITREPO_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
