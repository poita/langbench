#include <gtest/gtest.h>

#include "depresolve/version.hpp"

using depresolve::Version;

TEST(Version, ParsesValid) {
  const auto v = Version::parse("1.20.300");
  ASSERT_TRUE(v);
  EXPECT_EQ(v->major, 1u);
  EXPECT_EQ(v->minor, 20u);
  EXPECT_EQ(v->patch, 300u);
  EXPECT_EQ(Version::parse("0.0.0")->to_string(), "0.0.0");
  EXPECT_TRUE(Version::parse("1000000.1000000.1000000"));
}

TEST(Version, RejectsInvalid) {
  for (const char* s : {"", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "a.b.c", "1.2.3 ",
                        " 1.2.3", "1..3", "-1.2.3", "1.2.3-beta", "99999999999.0.0", "4294967295.0.0"}) {
    EXPECT_FALSE(Version::parse(s)) << s;
  }
}

TEST(Version, ComparesNumerically) {
  EXPECT_LT(*Version::parse("1.9.0"), *Version::parse("1.10.0"));
  EXPECT_LT(*Version::parse("1.99.99"), *Version::parse("2.0.0"));
  EXPECT_EQ(*Version::parse("3.2.1"), *Version::parse("3.2.1"));
  EXPECT_LT(*Version::parse("2.0.0"), Version::max());
}

TEST(Version, Successor) {
  EXPECT_EQ(Version::parse("1.2.3")->successor(), *Version::parse("1.2.4"));
}
