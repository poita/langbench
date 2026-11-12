find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(jsonschema_tests
  decimal_test.cpp
  json_test.cpp
  regex_test.cpp
  schema_test.cpp
  uri_test.cpp
  utf8_test.cpp)
target_link_libraries(jsonschema_tests PRIVATE jsonschema GTest::gtest GTest::gtest_main)
gtest_discover_tests(jsonschema_tests)
