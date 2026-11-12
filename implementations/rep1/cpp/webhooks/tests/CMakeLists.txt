add_executable(webhooks-tests
  arguments_test.cpp
  base64_test.cpp
  hmac_test.cpp
  protocol_test.cpp
  secret_test.cpp
  sha256_test.cpp
  signature_test.cpp
  simulator_test.cpp)
target_link_libraries(webhooks-tests PRIVATE webhooks::webhooks GTest::gtest GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(webhooks-tests)
target_compile_options(webhooks-tests PRIVATE -Wno-character-conversion)
