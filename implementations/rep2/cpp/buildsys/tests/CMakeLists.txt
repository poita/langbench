add_executable(kiln_tests
  test_hash_path.cpp
  test_glob.cpp
  test_value.cpp
  test_lexer.cpp
  test_parser.cpp
  test_builtins.cpp
  test_interp.cpp
  test_commands.cpp
  test_state.cpp
  test_graph.cpp
  test_session.cpp
  test_vfs.cpp)
target_link_libraries(kiln_tests PRIVATE kiln GTest::gtest_main)
target_include_directories(kiln_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

include(GoogleTest)
gtest_discover_tests(kiln_tests)
