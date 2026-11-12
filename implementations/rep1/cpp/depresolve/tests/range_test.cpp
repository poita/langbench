#include <gtest/gtest.h>

#include "depresolve/range.hpp"

using depresolve::Range;
using depresolve::Version;

namespace {
bool accepts(const char* range, const char* version) {
  auto r = Range::parse(range);
  EXPECT_TRUE(r) << range;
  return r && r->contains(*Version::parse(version));
}
}  // namespace

TEST(Range, Any) {
  EXPECT_TRUE(accepts("*", "0.0.0"));
  EXPECT_TRUE(accepts("*", "1000000.1000000.1000000"));
}

TEST(Range, Exact) {
  EXPECT_TRUE(accepts("1.2.3", "1.2.3"));
  EXPECT_FALSE(accepts("1.2.3", "1.2.4"));
  EXPECT_FALSE(accepts("1.2.3", "1.2.2"));
}

TEST(Range, CaretMajor) {
  EXPECT_TRUE(accepts("^1.2.3", "1.2.3"));
  EXPECT_TRUE(accepts("^1.2.3", "1.99.0"));
  EXPECT_FALSE(accepts("^1.2.3", "1.2.2"));
  EXPECT_FALSE(accepts("^1.2.3", "2.0.0"));
}

TEST(Range, CaretZeroMinor) {
  EXPECT_TRUE(accepts("^0.2.3", "0.2.9"));
  EXPECT_FALSE(accepts("^0.2.3", "0.3.0"));
  EXPECT_FALSE(accepts("^0.2.3", "0.2.2"));
}

TEST(Range, CaretZeroZero) {
  EXPECT_TRUE(accepts("^0.0.3", "0.0.3"));
  EXPECT_FALSE(accepts("^0.0.3", "0.0.4"));
  EXPECT_FALSE(accepts("^0.0.0", "0.0.1"));
  EXPECT_TRUE(accepts("^0.0.0", "0.0.0"));
}

TEST(Range, Tilde) {
  EXPECT_TRUE(accepts("~1.2.3", "1.2.9"));
  EXPECT_FALSE(accepts("~1.2.3", "1.3.0"));
  EXPECT_TRUE(accepts("~0.0.3", "0.0.9"));
  EXPECT_TRUE(accepts("~0.0.3", "0.0.3"));
  EXPECT_FALSE(accepts("~0.0.3", "0.1.0"));
}

TEST(Range, Comparators) {
  EXPECT_TRUE(accepts("<2.0.0", "1.9.9"));
  EXPECT_FALSE(accepts("<2.0.0", "2.0.0"));
  EXPECT_TRUE(accepts("<=2.0.0", "2.0.0"));
  EXPECT_FALSE(accepts("<=2.0.0", "2.0.1"));
  EXPECT_FALSE(accepts(">2.0.0", "2.0.0"));
  EXPECT_TRUE(accepts(">2.0.0", "2.0.1"));
  EXPECT_TRUE(accepts(">=2.0.0", "2.0.0"));
  EXPECT_FALSE(accepts(">=2.0.0", "1.9.9"));
}

TEST(Range, ComparatorConjunction) {
  EXPECT_TRUE(accepts(">=1.0.0 <2.0.0", "1.5.0"));
  EXPECT_FALSE(accepts(">=1.0.0 <2.0.0", "2.0.0"));
  EXPECT_TRUE(accepts(">1.0.0 <=1.5.0 >=1.2.0", "1.5.0"));
  EXPECT_FALSE(accepts(">1.0.0 <=1.5.0 >=1.2.0", "1.1.0"));
}

TEST(Range, EmptyRange) {
  auto r = Range::parse(">=2.0.0 <1.0.0");
  ASSERT_TRUE(r);
  EXPECT_TRUE(r->empty());
  EXPECT_FALSE(r->contains(*Version::parse("1.5.0")));
  EXPECT_FALSE(Range::parse("*")->empty());
}

TEST(Range, RejectsMalformed) {
  for (const char* s : {"", "^", "~1.2", ">=", ">= 1.0.0", "=1.0.0", "<1.0.0  >2.0.0", "^ 1.0.0", "x"}) {
    EXPECT_FALSE(Range::parse(s)) << s;
  }
}
