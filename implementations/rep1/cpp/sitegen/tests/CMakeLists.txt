find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(sitegen_tests
  test_text.cpp
  test_toml.cpp
  test_markdown.cpp
  test_value.cpp
  test_template.cpp
  test_model.cpp
  test_generator.cpp)
target_link_libraries(sitegen_tests PRIVATE sitegen::sitegen GTest::gtest GTest::gtest_main)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(sitegen_tests PRIVATE -Wall -Wextra)
endif()
gtest_discover_tests(sitegen_tests DISCOVERY_MODE PRE_TEST)
