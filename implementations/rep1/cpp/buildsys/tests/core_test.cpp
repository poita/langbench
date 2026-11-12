#include <gtest/gtest.h>

#include "support.hpp"

using namespace kiln;

TEST(Hash, KnownValues) {
  EXPECT_EQ(hash_to_hex(fnv1a64("")), "cbf29ce484222325");
  EXPECT_EQ(hash_to_hex(fnv1a64("hello\n")), "a9bc80cca21f28b3");
  EXPECT_EQ(hash_to_hex(fnv1a64("abc\n")), "fc17b183ee074373");
}

TEST(Hash, HexRoundTrip) {
  std::uint64_t v = 0;
  EXPECT_TRUE(hash_from_hex("a9bc80cca21f28b3", v));
  EXPECT_EQ(v, 0xa9bc80cca21f28b3ULL);
  EXPECT_FALSE(hash_from_hex("A9BC80CCA21F28B3", v));  // uppercase rejected
  EXPECT_FALSE(hash_from_hex("a9bc80cca21f28b", v));   // too short
}

TEST(Path, WorkspacePaths) {
  EXPECT_TRUE(is_workspace_path("src/a.txt"));
  EXPECT_TRUE(is_workspace_path(".kiln-state"));
  EXPECT_TRUE(is_workspace_path("a+b_c-d.e"));
  EXPECT_FALSE(is_workspace_path(""));
  EXPECT_FALSE(is_workspace_path("/a"));
  EXPECT_FALSE(is_workspace_path("a/"));
  EXPECT_FALSE(is_workspace_path("a//b"));
  EXPECT_FALSE(is_workspace_path("a/./b"));
  EXPECT_FALSE(is_workspace_path("a/../b"));
  EXPECT_FALSE(is_workspace_path("a b"));
  EXPECT_FALSE(is_workspace_path("a*"));
  EXPECT_FALSE(is_workspace_path("@all"));
  EXPECT_FALSE(is_workspace_path(std::string(256, 'x')));
  EXPECT_TRUE(is_workspace_path(std::string(255, 'x')));
}

TEST(Path, ReferenceShapes) {
  EXPECT_TRUE(is_reference_shape("@all"));
  EXPECT_TRUE(is_reference_shape("out/a"));
  EXPECT_FALSE(is_reference_shape("@"));
  EXPECT_FALSE(is_reference_shape("@a/b"));
  EXPECT_FALSE(is_reference_shape("@1x"));
}

TEST(Vfs, ReadWriteRemoveAndEligibility) {
  Vfs v;
  v.write("src/a.txt", "x");
  v.write("out/b.txt", "y");
  v.write(".kiln-state", "z");
  EXPECT_TRUE(v.exists("src/a.txt"));
  EXPECT_EQ(*v.read("src/a.txt"), "x");
  EXPECT_EQ(v.read("nope"), nullptr);
  EXPECT_EQ(v.eligible_with_prefix(""), (std::vector<std::string>{"src/a.txt"}));
  EXPECT_EQ(v.generated_paths(), (std::vector<std::string>{".kiln-state", "out/b.txt"}));
  EXPECT_TRUE(v.remove("src/a.txt"));
  EXPECT_FALSE(v.remove("src/a.txt"));
  EXPECT_TRUE(v.eligible_with_prefix("").empty());
}

TEST(Vfs, HashTracksContent) {
  Vfs v;
  v.write("a", "hello\n");
  EXPECT_EQ(hash_to_hex(v.hash("a")), "a9bc80cca21f28b3");
  v.write("a", "abc\n");
  EXPECT_EQ(hash_to_hex(v.hash("a")), "fc17b183ee074373");
}

TEST(Vfs, TouchChangesStampButNotContentHash) {
  Vfs v;
  v.write("a", "x");
  auto h = v.hash("a");
  auto s = v.stamp("a");
  v.touch("a");
  EXPECT_GT(v.stamp("a"), s);
  EXPECT_EQ(v.hash("a"), h);
}

TEST(Value, TotalOrder) {
  auto s = [](const char* x) { return Value::string(x); };
  auto i = [](int x) { return Value::integer(x); };
  EXPECT_LT(compare(Value::boolean(true), i(-5)), 0);
  EXPECT_LT(compare(i(100), s("")), 0);
  EXPECT_LT(compare(s("zzz"), Value::list({})), 0);
  EXPECT_LT(compare(s("ab"), s("abc")), 0);
  EXPECT_LT(compare(s("a"), s("\xc3")), 0);  // unsigned byte order
  EXPECT_LT(compare(Value::list({i(1)}), Value::list({i(1), i(0)})), 0);
  EXPECT_TRUE(equal(Value::list({s("a"), Value::list({i(1)})}), Value::list({s("a"), Value::list({i(1)})})));
  EXPECT_FALSE(equal(i(1), Value::boolean(true)));
}

TEST(Glob, SpecTable) {
  struct Case { const char* pat; const char* cand; bool match; };
  const Case cases[] = {
      {"src/*.txt", "src/a.txt", true},      {"src/*.txt", "src/.txt", true},
      {"src/*.txt", "src/sub/a.txt", false}, {"src/*.txt", "a.txt", false},
      {"src/**", "src/a.txt", true},         {"src/**", "src/x/y/z.txt", true},
      {"src/**", "src", true},               {"src/**", "other/a.txt", false},
      {"src/**", "srcx", false},             {"**/*.txt", "a.txt", true},
      {"**/*.txt", "src/a.txt", true},       {"**/*.txt", "a/b/c.txt", true},
      {"**/*.txt", "a.text", false},         {"src/**/t_*.txt", "src/t_1.txt", true},
      {"src/**/t_*.txt", "src/a/b/t_2.txt", true}, {"src/**/t_*.txt", "src/t.txt", false},
      {"src/?.txt", "src/a.txt", true},      {"src/?.txt", "src/ab.txt", false},
      {"src/[ab]*.txt", "src/a1.txt", true}, {"src/[ab]*.txt", "src/c.txt", false},
      {"src/[!ab]*.txt", "src/c.txt", true}, {"src/[!ab]*.txt", "src/a.txt", false},
      {"src/[0-9].txt", "src/7.txt", true},  {"src/[0-9].txt", "src/x.txt", false},
      {"a**b", "axyzb", true},               {"a**b", "ab", true},
      {"a**b", "a/b", false},                {"*", "", true},
      {"**", "", true},                      {"?", "", false},
      {"*", "a//b", false},                  {"a/*/b", "a//b", true},
      {"[-a]", "-", true},                   {"[a-]", "-", true},
      {"[*?]", "?", true},                   {"[a-z]", "-", false},
  };
  for (const auto& c : cases) {
    auto g = GlobPattern::compile(c.pat);
    ASSERT_TRUE(g.has_value()) << c.pat;
    EXPECT_EQ(g->matches(c.cand), c.match) << c.pat << " vs " << c.cand;
  }
}

TEST(Glob, MalformedPatterns) {
  for (const char* bad : {"", "/a", "a/", "a//b", "[", "[]", "[!]", "[b-a]", "a[bc", "x/[z-a]"}) {
    EXPECT_FALSE(GlobPattern::compile(bad).has_value()) << bad;
  }
  EXPECT_TRUE(GlobPattern::compile("[]]").has_value() == false);  // `]` first closes an empty class
  EXPECT_TRUE(GlobPattern::compile("[a-]").has_value());
}

TEST(Glob, LiteralPrefixNarrowsScan) {
  EXPECT_EQ(GlobPattern::compile("src/**")->literal_prefix(), "src");
  EXPECT_EQ(GlobPattern::compile("src/a*.txt")->literal_prefix(), "src/a");
  EXPECT_EQ(GlobPattern::compile("**/x")->literal_prefix(), "");
  EXPECT_EQ(GlobPattern::compile("a/b.txt")->literal_prefix(), "a/b.txt");
}

TEST(Error, Rendering) {
  EXPECT_EQ(Error(ErrorKind::NoDefault).text(), "E_NO_DEFAULT");
  EXPECT_EQ(Error(ErrorKind::DivZero).text(), "E_DIV_ZERO");
  EXPECT_EQ(Error(ErrorKind::Cycle, "a -> b -> a").text(), "E_CYCLE a -> b -> a");
  EXPECT_EQ(kind_name(ErrorKind::NeedCycle), "E_NEED_CYCLE");
}
