add_executable(datalog_tests
  ast_test.cpp
  parser_test.cpp
  analysis_test.cpp
  relation_test.cpp
  engine_test.cpp)
target_link_libraries(datalog_tests PRIVATE datalog_lib GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(datalog_tests)
