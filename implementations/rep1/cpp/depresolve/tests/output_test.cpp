#include <gtest/gtest.h>

#include "depresolve/output.hpp"

using namespace depresolve;

TEST(Output, Unsatisfiable) { EXPECT_EQ(format_resolution(std::nullopt), "unsatisfiable\n"); }

TEST(Output, EmptyResolutionIsEmpty) { EXPECT_EQ(format_resolution(Resolution{}), ""); }

TEST(Output, Lines) {
  Resolution r{{{"a", {1, 2, 3}}, {"b", {10, 0, 0}}}};
  EXPECT_EQ(format_resolution(r), "a 1.2.3\nb 10.0.0\n");
}
