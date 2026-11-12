include(GoogleTest)

add_executable(depresolve_tests
  version_test.cpp
  range_test.cpp
  registry_test.cpp
  parser_test.cpp
  resolver_test.cpp)
target_link_libraries(depresolve_tests PRIVATE depresolve GTest::gtest GTest::gtest_main)
gtest_discover_tests(depresolve_tests)
