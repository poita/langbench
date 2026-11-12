find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(jinjalite_tests
  test_value.cpp
  test_format.cpp
  test_json.cpp
  test_lexer.cpp
  test_parser.cpp
  test_ops.cpp
  test_filters.cpp
  test_render.cpp
  test_document.cpp)
target_link_libraries(jinjalite_tests PRIVATE jinjalite GTest::gtest GTest::gtest_main)
gtest_discover_tests(jinjalite_tests)
# GoogleTest's own headers trigger this clang warning under C++20.
target_compile_options(jinjalite_tests PRIVATE -Wno-character-conversion)
