include(GoogleTest)

add_executable(commonmark_tests
  test_helpers.h
  block_tests.cpp
  inline_tests.cpp
  link_tests.cpp
  render_tests.cpp
  spec_examples_tests.cpp
  api_tests.cpp
  stress_tests.cpp)
target_link_libraries(commonmark_tests PRIVATE commonmark::commonmark GTest::gtest_main)
gtest_discover_tests(commonmark_tests)
