#include <gtest/gtest.h>

#include "depresolve/range.hpp"

using depresolve::Range;
using depresolve::Version;

namespace {

Version V(const char* s) { return *Version::parse(s); }

bool accepts(const char* range, const char* version) {
  const auto r = Range::parse(range);
  EXPECT_TRUE(r) << range;
  return r && r->contains(V(version));
}

}  // namespace

TEST(Range, Star) {
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
  EXPECT_FALSE(accepts("^0.0.3", "0.0.2"));
}

TEST(Range, TildeKeepsMajorAndMinor) {
  EXPECT_TRUE(accepts("~1.2.3", "1.2.9"));
  EXPECT_FALSE(accepts("~1.2.3", "1.3.0"));
  EXPECT_TRUE(accepts("~0.0.3", "0.0.99"));
  EXPECT_TRUE(accepts("~0.0.3", "0.0.3"));
  EXPECT_FALSE(accepts("~0.0.3", "0.1.0"));
}

TEST(Range, Comparators) {
  EXPECT_TRUE(accepts(">1.0.0", "1.0.1"));
  EXPECT_FALSE(accepts(">1.0.0", "1.0.0"));
  EXPECT_TRUE(accepts(">=1.0.0", "1.0.0"));
  EXPECT_TRUE(accepts("<2.0.0", "1.99.99"));
  EXPECT_FALSE(accepts("<2.0.0", "2.0.0"));
  EXPECT_TRUE(accepts("<=2.0.0", "2.0.0"));
  EXPECT_FALSE(accepts("<=2.0.0", "2.0.1"));
}

TEST(Range, ComparatorConjunction) {
  EXPECT_TRUE(accepts(">=1.2.0 <1.4.0", "1.3.9"));
  EXPECT_FALSE(accepts(">=1.2.0 <1.4.0", "1.4.0"));
  EXPECT_FALSE(accepts(">=1.2.0 <1.4.0", "1.1.9"));
  EXPECT_TRUE(accepts(">1.0.0 >=1.5.0 <=1.5.0", "1.5.0"));
}

TEST(Range, EmptyInEffect) {
  const auto r = Range::parse(">=2.0.0 <1.0.0");
  ASSERT_TRUE(r);
  EXPECT_TRUE(r->empty());
  EXPECT_FALSE(r->contains(V("1.5.0")));
  EXPECT_FALSE(Range::any().empty());
}

TEST(Range, RejectsMalformed) {
  for (const char* s : {"", "^", "~1.2", "^1.2", ">=", ">= 1.0.0", ">=1.0.0  <2.0.0", ">=1.0.0 ", "=1.0.0",
                        "**", "1.0", ">>1.0.0", "<=<1.0.0", "^ 1.0.0", "1.0.0 <2.0.0"}) {
    EXPECT_FALSE(Range::parse(s)) << '"' << s << '"';
  }
}
