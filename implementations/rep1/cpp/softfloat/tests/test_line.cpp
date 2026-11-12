#include <gtest/gtest.h>

#include "softfloat/line.h"

using namespace softfloat;

TEST(Line, EvaluatesAllOps) {
  EXPECT_EQ(evaluate_line("add 3f800000 3f800000"), 0x40000000u);
  EXPECT_EQ(evaluate_line("sub 3f800000 3f800000"), 0u);
  EXPECT_EQ(evaluate_line("mul 40400000 c0400000"), 0xc1100000u);
  EXPECT_EQ(evaluate_line("div 3f800000 40400000"), 0x3eaaaaabu);
  EXPECT_EQ(evaluate_line("sqrt 40000000"), 0x3fb504f3u);
}

TEST(Line, RejectsMalformed) {
  for (const char* s : {"", "add", "add 3f800000", "add 3f800000 3f800000 3f800000", "sqrt 3f800000 3f800000",
                        "pow 3f800000 3f800000", "add 3F800000 3f800000", "add 3f80000 3f800000",
                        "add 3f800000  3f800000", "add 3f80000g 3f800000", " add 3f800000 3f800000",
                        "sqrt"})
    EXPECT_FALSE(evaluate_line(s).has_value()) << '"' << s << '"';
}

TEST(Line, FormatBits) {
  EXPECT_EQ(format_bits(0), "00000000");
  EXPECT_EQ(format_bits(0xdeadbeef), "deadbeef");
}

TEST(Line, EvaluateAll) {
  EXPECT_EQ(evaluate_all("add 3f800000 3f800000\nsqrt 40000000").value(), "40000000\n3fb504f3\n");
  EXPECT_EQ(evaluate_all("sqrt 40000000\r\n").value(), "3fb504f3\n");
  std::size_t bad = 0;
  EXPECT_FALSE(evaluate_all("sqrt 40000000\nbogus\n", &bad).has_value());
  EXPECT_EQ(bad, 2u);
}
