add_executable(svgraster_tests
  xml_test.cpp
  parse_test.cpp
  path_test.cpp
  stroke_test.cpp
  raster_test.cpp
  render_test.cpp)
target_link_libraries(svgraster_tests PRIVATE svgraster GTest::gtest GTest::gtest_main)
include(GoogleTest)
gtest_discover_tests(svgraster_tests)
