find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(scheme_tests
  bigint_test.cpp
  reader_test.cpp
  printer_test.cpp
  interpreter_test.cpp)
target_link_libraries(scheme_tests PRIVATE scheme::scheme GTest::gtest_main)
gtest_discover_tests(scheme_tests)
