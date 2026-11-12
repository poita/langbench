include(GoogleTest)

add_executable(regex_tests
  charset_test.cpp
  parser_test.cpp
  matcher_test.cpp
  reference_test.cpp
  batch_test.cpp)
target_link_libraries(regex_tests PRIVATE regex_batch regex::engine GTest::gtest_main)
gtest_discover_tests(regex_tests)
