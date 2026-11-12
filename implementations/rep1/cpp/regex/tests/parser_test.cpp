#include <gtest/gtest.h>

#include "regex/parser.hpp"

using namespace regex;

namespace {
bool rejects(const char* pattern) {
  try {
    parse(pattern);
  } catch (const ParseError&) {
    return true;
  }
  return false;
}
}  // namespace

TEST(Parser, CountsGroupsInOpeningOrder) {
  auto r = parse("(a(b))(c)");
  EXPECT_EQ(r.group_count, 3);
  ASSERT_EQ(r.root->kind, NodeKind::Concat);
  ASSERT_EQ(r.root->children.size(), 2u);
  EXPECT_EQ(r.root->children[0]->group, 1);
  EXPECT_EQ(r.root->children[0]->children[0]->children[1]->group, 2);
  EXPECT_EQ(r.root->children[1]->group, 3);
}

TEST(Parser, EmptyPatternIsEmptyConcat) {
  auto r = parse("");
  EXPECT_EQ(r.root->kind, NodeKind::Concat);
  EXPECT_TRUE(r.root->children.empty());
}

TEST(Parser, EmptyBranchesAreAllowed) {
  EXPECT_NO_THROW(parse("a|"));
  EXPECT_NO_THROW(parse("(|b)"));
  EXPECT_NO_THROW(parse("||"));
  EXPECT_NO_THROW(parse("()"));
  EXPECT_EQ(parse("||").root->children.size(), 3u);
}

TEST(Parser, Quantifiers) {
  struct Case { const char* p; int min, max; };
  for (Case c : {Case{"a*", 0, kUnbounded}, Case{"a+", 1, kUnbounded}, Case{"a?", 0, 1},
                 Case{"a{3}", 3, 3}, Case{"a{2,}", 2, kUnbounded}, Case{"a{2,5}", 2, 5},
                 Case{"a{0}", 0, 0}, Case{"a{0,0}", 0, 0}}) {
    auto r = parse(c.p);
    const Node& rep = *r.root->children[0];
    ASSERT_EQ(rep.kind, NodeKind::Repeat) << c.p;
    EXPECT_EQ(rep.min, c.min) << c.p;
    EXPECT_EQ(rep.max, c.max) << c.p;
  }
}

TEST(Parser, ClassContents) {
  auto set_of = [](const char* p) { return parse(p).root->children[0]->set; };
  CharSet s = set_of("[a-c_]");
  EXPECT_TRUE(s.contains('b'));
  EXPECT_TRUE(s.contains('_'));
  EXPECT_FALSE(s.contains('d'));
  s = set_of("[^a-c]");
  EXPECT_FALSE(s.contains('a'));
  EXPECT_TRUE(s.contains('d'));
  s = set_of("[-a]");
  EXPECT_TRUE(s.contains('-'));
  s = set_of("[a-]");
  EXPECT_TRUE(s.contains('-'));
  EXPECT_TRUE(s.contains('a'));
  s = set_of("[a\\-z]");
  EXPECT_TRUE(s.contains('-'));
  EXPECT_FALSE(s.contains('b'));
  s = set_of("[x^]");
  EXPECT_TRUE(s.contains('^'));
  s = set_of("[\\]\\\\]");
  EXPECT_TRUE(s.contains(']'));
  EXPECT_TRUE(s.contains('\\'));
  s = set_of("[\\d_]");
  EXPECT_TRUE(s.contains('7'));
  EXPECT_TRUE(s.contains('_'));
  s = set_of("[\\D]");
  EXPECT_FALSE(s.contains('7'));
  EXPECT_TRUE(s.contains('x'));
  s = set_of("[--/]");  // range '-'..'/'
  EXPECT_TRUE(s.contains('.'));
  EXPECT_FALSE(s.contains('a'));
}

TEST(Parser, EscapesOutsideClass) {
  auto lit = [](const char* p) { return std::move(parse(p).root->children[0]); };
  EXPECT_EQ(lit("\\.")->kind, NodeKind::Literal);
  EXPECT_EQ(lit("\\.")->ch, '.');
  EXPECT_EQ(lit("\\ ")->ch, ' ');
  EXPECT_EQ(lit("\\@")->ch, '@');
  EXPECT_EQ(lit("\\d")->kind, NodeKind::Set);
  EXPECT_TRUE(lit("\\S")->set.contains('x'));
  EXPECT_FALSE(lit("\\S")->set.contains(' '));
}

TEST(Parser, RejectsInvalidPatterns) {
  for (const char* p : {"(", ")", "a)", "(a", "*", "+a", "?", "a**", "a+*", "a{2}{3}", "a{", "a{x}",
                        "a{3,2}", "a{01}", "a{,3}", "a{1,2", "[", "[]", "[a", "[^]", "[z-a]", "a]",
                        "}", "\\", "\\b", "\\1", "\\n", "^*", "$+", "(*)", "|*", "a{5000}"}) {
    EXPECT_TRUE(rejects(p)) << p;
  }
}

TEST(Parser, ErrorCarriesPosition) {
  try {
    parse("ab(c");
    FAIL();
  } catch (const ParseError& e) {
    EXPECT_EQ(e.position(), 4u);
  }
}
