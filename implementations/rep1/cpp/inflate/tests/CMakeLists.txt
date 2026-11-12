find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(inflate_tests
  test_bit_reader.cpp
  test_hex.cpp
  test_huffman.cpp
  test_inflate.cpp
  test_errors.cpp)
target_link_libraries(inflate_tests PRIVATE inflate::inflate GTest::gtest_main)
gtest_discover_tests(inflate_tests)

if(INFLATE_BUILD_CLI)
  add_executable(inflate_cli_tests test_cli.cpp)
  target_link_libraries(inflate_cli_tests PRIVATE inflate::inflate GTest::gtest_main)
  target_compile_definitions(inflate_cli_tests PRIVATE INFLATE_CLI_PATH="$<TARGET_FILE:inflate_cli>")
  add_dependencies(inflate_cli_tests inflate_cli)
  gtest_discover_tests(inflate_cli_tests)
endif()
