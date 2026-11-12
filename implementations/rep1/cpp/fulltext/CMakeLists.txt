cmake_minimum_required(VERSION 3.20)
project(fulltext VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(FULLTEXT_BUILD_TESTS "Build the unit tests (requires GoogleTest)" ON)

# ---- library ---------------------------------------------------------------
add_library(fulltext
  src/utf8.cpp
  src/stemmer.cpp
  src/analyzer.cpp
  src/index.cpp
  src/query.cpp
  src/matcher.cpp
  src/bm25.cpp
  src/snippet.cpp
  src/searcher.cpp
  src/corpus.cpp
  src/batch.cpp
)
add_library(fulltext::fulltext ALIAS fulltext)
target_include_directories(fulltext PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(fulltext PUBLIC cxx_std_20)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(fulltext PRIVATE -Wall -Wextra)
endif()

# ---- command-line tool -----------------------------------------------------
add_executable(fulltext_cli cli/main.cpp)
set_target_properties(fulltext_cli PROPERTIES OUTPUT_NAME fulltext)
target_link_libraries(fulltext_cli PRIVATE fulltext::fulltext)

# ---- tests -----------------------------------------------------------------
if(FULLTEXT_BUILD_TESTS)
  enable_testing()
  find_package(GTest REQUIRED)
  include(GoogleTest)

  add_executable(fulltext_tests
    tests/utf8_test.cpp
    tests/stemmer_test.cpp
    tests/analyzer_test.cpp
    tests/index_test.cpp
    tests/query_test.cpp
    tests/matcher_test.cpp
    tests/snippet_test.cpp
    tests/searcher_test.cpp
    tests/batch_test.cpp
  )
  target_link_libraries(fulltext_tests PRIVATE fulltext::fulltext GTest::gtest_main)

  # Optional: Porter's reference vocabulary, if it is available next to the
  # problem statement. The test is skipped when the files are missing.
  set(FULLTEXT_PORTER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../problems/fulltext/corpus/porter"
      CACHE PATH "Directory holding Porter's voc.txt and output.txt")
  target_compile_definitions(fulltext_tests PRIVATE
    FULLTEXT_PORTER_DIR="${FULLTEXT_PORTER_DIR}")

  gtest_discover_tests(fulltext_tests DISCOVERY_MODE PRE_TEST)
endif()
