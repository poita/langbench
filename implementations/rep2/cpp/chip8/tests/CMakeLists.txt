find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(chip8_tests
  rng_test.cpp
  display_test.cpp
  machine_test.cpp
  key_schedule_test.cpp
  program_test.cpp
  runner_test.cpp)
target_link_libraries(chip8_tests PRIVATE chip8::chip8 GTest::gtest GTest::gtest_main)
gtest_discover_tests(chip8_tests)
