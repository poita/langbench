#include <gtest/gtest.h>

#include "depresolve/parser.hpp"

using namespace depresolve;

TEST(Parser, ParsesRegistryAndRoot) {
  const auto p = parse_problem("a 1.0.0: c ^1.0.0, d >=1.0.0 <2.0.0\nc 1.2.0:\nroot: a *, c 1.2.0\n");
  EXPECT_TRUE(p.registry.finalized());
  EXPECT_EQ(p.registry.package_count(), 3u);  // a, c, d (d has no versions)
  ASSERT_EQ(p.root.size(), 2u);
  EXPECT_EQ(p.root[0].name, "a");
  EXPECT_EQ(p.root[1].name, "c");
  EXPECT_EQ(p.root[1].range, Range::exact(Version{1, 2, 0}));
  const auto& reqs = p.registry.versions(*p.registry.find("a"))[0].requirements;
  ASSERT_EQ(reqs.size(), 2u);
  EXPECT_EQ(reqs[1].range, *Range::parse(">=1.0.0 <2.0.0"));
}

TEST(Parser, EmptyRoot) {
  const auto p = parse_problem("root:\n");
  EXPECT_TRUE(p.root.empty());
  EXPECT_EQ(p.registry.package_count(), 0u);
}

TEST(Parser, PackageNamesStartingWithRoot) {
  const auto p = parse_problem("rootx 1.0.0:\nroot: rootx *\n");
  EXPECT_EQ(p.root.size(), 1u);
  EXPECT_TRUE(p.registry.find("rootx"));
}

TEST(Parser, ParseRequirements) {
  EXPECT_TRUE(parse_requirements("").empty());
  const auto deps = parse_requirements("a *, b-2 ~1.0.0");
  ASSERT_EQ(deps.size(), 2u);
  EXPECT_EQ(deps[1].name, "b-2");
}

TEST(Parser, ReportsLineNumbers) {
  try {
    parse_problem("a 1.0.0:\nb 1.0.x:\nroot:\n");
    FAIL() << "expected ParseError";
  } catch (const ParseError& e) {
    EXPECT_EQ(e.line(), 2u);
  }
}

TEST(Parser, RejectsMalformedInput) {
  for (const char* text : {
           "",                              // no root
           "a 1.0.0:\n",                    // no root
           "root:\nroot:\n",                // content after root
           "root:\na 1.0.0:\n",             // root not last
           "a 1.0.0:\n\nroot:\n",           // blank line
           "a 1.0.0: b\nroot:\n",           // requirement without range
           "a 1.0.0:b *\nroot:\n",          // missing space after colon
           "a 1.0.0: b *,c *\nroot:\n",     // missing space after comma
           "A 1.0.0:\nroot:\n",             // uppercase name
           "1a 1.0.0:\nroot:\n",            // name starting with digit
           "a 1.0:\nroot:\n",               // short version
           "a1.0.0:\nroot:\n",              // missing space
           "root: a ^1\n",                  // bad range
       }) {
    EXPECT_THROW(parse_problem(text), ParseError) << text;
  }
}

TEST(Parser, DuplicateVersionThrows) {
  EXPECT_THROW(parse_problem("a 1.0.0:\na 1.0.0:\nroot:\n"), std::invalid_argument);
}
