add_executable(typeset-tests
  util_test.cpp
  font_test.cpp
  hyphenation_test.cpp
  settings_test.cpp
  document_test.cpp
  linebreak_test.cpp
  pipeline_test.cpp)
target_link_libraries(typeset-tests PRIVATE typeset GTest::gtest GTest::gtest_main)
target_compile_definitions(typeset-tests PRIVATE TYPESET_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../data")
include(GoogleTest)
gtest_discover_tests(typeset-tests)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  target_compile_options(typeset-tests PRIVATE -Wno-character-conversion)
endif()
