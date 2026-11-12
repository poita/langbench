find_package(GTest REQUIRED)
include(GoogleTest)

add_executable(ordered_map_tests
  ordered_map_test.cpp
  command_processor_test.cpp)
target_link_libraries(ordered_map_tests PRIVATE ordered_map GTest::gtest_main)
gtest_discover_tests(ordered_map_tests)
