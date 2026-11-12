#include <gtest/gtest.h>

#include "depresolve/version.hpp"

using depresolve::Version;

TEST(Version, ParsesComponents) {
  auto v = Version::parse("1.20.300");
  ASSERT_TRUE(v);
  EXPECT_EQ(v->major, 1u);
  EXPECT_EQ(v->minor, 20u);
  EXPECT_EQ(v->patch, 300u);
  EXPECT_EQ(v->to_string(), "1.20.300");
}

TEST(Version, RejectsMalformed) {
  for (const char* s : {"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "a.b.c", "1.2.3 ", "-1.2.3", "1..3"}) {
    EXPECT_FALSE(Version::parse(s)) << s;
  }
  EXPECT_FALSE(Version::parse("99999999999.0.0"));
}

TEST(Version, ComparesNumerically) {
  EXPECT_LT(*Version::parse("1.9.0"), *Version::parse("1.10.0"));
  EXPECT_LT(*Version::parse("1.10.0"), *Version::parse("2.0.0"));
  EXPECT_LT(*Version::parse("1.2.3"), *Version::parse("1.2.4"));
  EXPECT_EQ(*Version::parse("0.0.0"), Version{});
}
