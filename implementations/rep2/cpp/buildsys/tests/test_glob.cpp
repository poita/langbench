#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
bool m(const char* pattern, const char* path) {
  auto g = GlobPattern::compile(pattern);
  EXPECT_TRUE(g.has_value()) << pattern;
  return g && g->matches(path);
}
}  // namespace

TEST(Glob, SpecTable) {
  EXPECT_TRUE(m("src/*.txt", "src/a.txt"));
  EXPECT_TRUE(m("src/*.txt", "src/.txt"));
  EXPECT_FALSE(m("src/*.txt", "src/sub/a.txt"));
  EXPECT_FALSE(m("src/*.txt", "a.txt"));
  EXPECT_TRUE(m("src/**", "src"));
  EXPECT_TRUE(m("src/**", "src/x/y/z.txt"));
  EXPECT_FALSE(m("src/**", "srcx"));
  EXPECT_TRUE(m("**/*.txt", "a.txt"));
  EXPECT_TRUE(m("**/*.txt", "a/b/c.txt"));
  EXPECT_FALSE(m("**/*.txt", "a.text"));
  EXPECT_TRUE(m("src/**/t_*.txt", "src/a/b/t_2.txt"));
  EXPECT_FALSE(m("src/**/t_*.txt", "src/t.txt"));
  EXPECT_TRUE(m("src/?.txt", "src/a.txt"));
  EXPECT_FALSE(m("src/?.txt", "src/ab.txt"));
  EXPECT_TRUE(m("src/[ab]*.txt", "src/a1.txt"));
  EXPECT_FALSE(m("src/[ab]*.txt", "src/c.txt"));
  EXPECT_TRUE(m("src/[!ab]*.txt", "src/c.txt"));
  EXPECT_TRUE(m("src/[0-9].txt", "src/7.txt"));
  EXPECT_TRUE(m("a**b", "axyzb"));
  EXPECT_TRUE(m("a**b", "ab"));
  EXPECT_FALSE(m("a**b", "a/b"));
}

TEST(Glob, EmptyComponentsInCandidates) {
  EXPECT_TRUE(m("*", ""));
  EXPECT_TRUE(m("**", ""));
  EXPECT_FALSE(m("?", ""));
  EXPECT_FALSE(m("*", "a//b"));
  EXPECT_TRUE(m("a/*", "a/"));
}

TEST(Glob, MalformedPatterns) {
  for (const char* bad : {"", "/a", "a/", "a//b", "[", "[]", "[!]", "[a", "[z-a]"})
    EXPECT_FALSE(GlobPattern::compile(bad).has_value()) << bad;
}

TEST(Glob, ClassEdgeCases) {
  EXPECT_TRUE(m("[-a]", "-"));
  EXPECT_TRUE(m("[a-]", "-"));
  EXPECT_TRUE(m("[a-]", "a"));
  EXPECT_TRUE(m("[*?]", "*"));
  EXPECT_FALSE(m("[*?]", "x"));
}

TEST(Glob, LiteralPrefix) {
  EXPECT_EQ(GlobPattern::compile("src/*.txt")->literalPrefix(), "src/");
  EXPECT_EQ(GlobPattern::compile("src/**")->literalPrefix(), "src");
  EXPECT_EQ(GlobPattern::compile("**/a")->literalPrefix(), "");
  EXPECT_EQ(GlobPattern::compile("a/b.txt")->literalPrefix(), "a/b.txt");
}
