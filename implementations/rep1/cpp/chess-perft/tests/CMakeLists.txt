add_executable(chessperft_tests
  test_types_attacks.cpp
  test_fen.cpp
  test_position.cpp
  test_movegen.cpp
  test_perft.cpp
  test_query.cpp)
target_link_libraries(chessperft_tests PRIVATE chessperft::chessperft GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(chessperft_tests)
target_compile_options(chessperft_tests PRIVATE -Wno-character-conversion)
