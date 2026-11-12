add_executable(typeinfer_tests
  lexer_test.cpp
  parser_test.cpp
  types_test.cpp
  printer_test.cpp
  inference_test.cpp
  session_test.cpp)
target_link_libraries(typeinfer_tests PRIVATE typeinfer_lib GTest::gtest GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(typeinfer_tests)
