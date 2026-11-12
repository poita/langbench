#include <gtest/gtest.h>

#include "depresolve/parser.hpp"

using namespace depresolve;

TEST(Parser, EmptyRoot) {
  Problem p = parse_problem("root:\n");
  EXPECT_TRUE(p.root.empty());
  EXPECT_TRUE(p.registry.versions().empty());
}

TEST(Parser, RegistryAndRoot) {
  Problem p = parse_problem(
      "a 1.0.0: b ^1.0.0, c >=1.0.0 <2.0.0\n"
      "b 1.2.3:\n"
      "root: a *, zzz 1.0.0\n");
  ASSERT_EQ(p.registry.versions().size(), 2u);
  const auto& a = p.registry.versions()[0];
  EXPECT_EQ(p.registry.name(a.package), "a");
  EXPECT_EQ(a.version, (Version{1, 0, 0}));
  ASSERT_EQ(a.requirements.size(), 2u);
  EXPECT_EQ(p.registry.name(a.requirements[0].package), "b");
  EXPECT_EQ(p.registry.name(a.requirements[1].package), "c");
  EXPECT_TRUE(p.registry.versions()[1].requirements.empty());
  ASSERT_EQ(p.root.size(), 2u);
  EXPECT_EQ(p.registry.name(p.root[1].package), "zzz");
  // A package that is only required still gets an id.
  EXPECT_TRUE(p.registry.find("zzz"));
  EXPECT_FALSE(p.registry.find("nope"));
}

TEST(Parser, NamesWithDigitsAndHyphens) {
  Problem p = parse_problem("my-lib2 0.0.1:\nroot: my-lib2 *\n");
  EXPECT_EQ(p.registry.name(p.root[0].package), "my-lib2");
}

TEST(Parser, MissingFinalNewlineTolerated) {
  EXPECT_NO_THROW(parse_problem("root:"));
}

TEST(Parser, Errors) {
  EXPECT_THROW(parse_problem(""), ParseError);
  EXPECT_THROW(parse_problem("a 1.0.0:\n"), ParseError);            // no root
  EXPECT_THROW(parse_problem("root:\na 1.0.0:\n"), ParseError);     // content after root
  EXPECT_THROW(parse_problem("a 1.0:\nroot:\n"), ParseError);       // bad version
  EXPECT_THROW(parse_problem("a 1.0.0: b\nroot:\n"), ParseError);   // missing range
  EXPECT_THROW(parse_problem("a 1.0.0: b *,c *\nroot:\n"), ParseError);
  EXPECT_THROW(parse_problem("A 1.0.0:\nroot:\n"), ParseError);
  try {
    parse_problem("a 1.0.0:\nb x:\nroot:\n");
    FAIL();
  } catch (const ParseError& e) {
    EXPECT_EQ(e.line(), 2u);
  }
}
