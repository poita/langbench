find_package(GTest REQUIRED)

add_executable(gitrepo_tests
  test_commands.cpp
  test_inflate.cpp
  test_objects.cpp
  test_quote.cpp
  test_repository.cpp
  test_sha1.cpp)
target_link_libraries(gitrepo_tests PRIVATE gitrepo::gitrepo GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(gitrepo_tests)
