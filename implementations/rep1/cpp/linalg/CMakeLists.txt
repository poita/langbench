cmake_minimum_required(VERSION 3.20)
project(linalg VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(LINALG_BUILD_TESTS "Build the GoogleTest suite" ON)

# The algorithms specify the rounding of every intermediate, so forbid the
# compiler from fusing a*b+c into FMA (Clang's default on arm64).
add_library(linalg
  src/error.cpp src/matrix.cpp src/matrix_market.cpp src/sign.cpp
  src/lu.cpp src/qr.cpp src/cholesky.cpp src/eigen.cpp src/svd.cpp)
target_include_directories(linalg PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(linalg PUBLIC cxx_std_17)
target_compile_options(linalg PRIVATE -Wall -Wextra -ffp-contract=off)

add_library(linalg_driver STATIC cli/driver.cpp)
target_link_libraries(linalg_driver PUBLIC linalg)
target_include_directories(linalg_driver PUBLIC cli)
target_compile_options(linalg_driver PRIVATE -Wall -Wextra -ffp-contract=off)

add_executable(linalg_cli cli/main.cpp)
target_link_libraries(linalg_cli PRIVATE linalg_driver)

if(LINALG_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  add_executable(linalg_tests
    tests/test_matrix.cpp tests/test_matrix_market.cpp tests/test_lu.cpp
    tests/test_qr.cpp tests/test_cholesky.cpp tests/test_eigen.cpp
    tests/test_svd.cpp tests/test_driver.cpp)
  target_link_libraries(linalg_tests PRIVATE linalg_driver GTest::gtest_main)
  target_compile_options(linalg_tests PRIVATE -ffp-contract=off)
  include(GoogleTest)
  gtest_discover_tests(linalg_tests)
endif()
