add_executable(spiremark_tests
  sexpr_test.cpp
  database_test.cpp
  script_test.cpp
  rng_test.cpp
  game_test.cpp)
target_link_libraries(spiremark_tests PRIVATE spiremark GTest::gtest_main)
include(GoogleTest)
gtest_discover_tests(spiremark_tests)
