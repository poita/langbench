add_library(sqlitefile_test_support STATIC support/db_builder.cpp)
target_include_directories(sqlitefile_test_support PUBLIC support)
target_link_libraries(sqlitefile_test_support PUBLIC sqlitefile::sqlitefile)

add_executable(sqlitefile_tests
  value_test.cpp
  record_test.cpp
  btree_test.cpp
  ddl_test.cpp
  query_test.cpp
  database_test.cpp
  cli_test.cpp)
target_link_libraries(sqlitefile_tests PRIVATE
  sqlitefile_test_support GTest::gtest_main)
target_compile_definitions(sqlitefile_tests PRIVATE
  SQLITEFILE_CLI_PATH="$<TARGET_FILE:sqlitefile_cli>")
add_dependencies(sqlitefile_tests sqlitefile_cli)

include(GoogleTest)
gtest_discover_tests(sqlitefile_tests)
# GoogleTest 1.15's headers trigger this warning on newer clang.
target_compile_options(sqlitefile_tests PRIVATE -Wno-character-conversion)
