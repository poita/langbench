include(GoogleTest)

add_executable(jq_tests
  value_test.cpp
  json_test.cpp
  parser_test.cpp
  filter_test.cpp)
target_link_libraries(jq_tests PRIVATE jq::jq GTest::gtest GTest::gtest_main)
gtest_discover_tests(jq_tests)
