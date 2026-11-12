include(GoogleTest)

add_executable(minisql_tests
  test_value.cpp
  test_like.cpp
  test_lexer.cpp
  test_parser.cpp
  test_database.cpp)
target_link_libraries(minisql_tests PRIVATE minisql_lib GTest::gtest GTest::gtest_main)
gtest_discover_tests(minisql_tests DISCOVERY_MODE PRE_TEST)
