#include <gtest/gtest.h>

#include "rx/parser.hpp"

using rx::NodeKind;

TEST(Parser, CountsGroupsInOrder) {
  auto p = rx::parse("(a(b))(c)|()");
  EXPECT_EQ(p.group_count, 4u);
  EXPECT_EQ(p.root->kind, NodeKind::Alternate);
}

TEST(Parser, EmptyPatternAndBranches) {
  EXPECT_EQ(rx::parse("").root->kind, NodeKind::Empty);
  auto p = rx::parse("a|");
  ASSERT_EQ(p.root->kind, NodeKind::Alternate);
  EXPECT_EQ(p.root->children[1]->kind, NodeKind::Empty);
  EXPECT_EQ(rx::parse("||").root->children.size(), 3u);
}

TEST(Parser, Quantifiers) {
  auto check = [](const char* pat, int lo, int hi) {
    auto p = rx::parse(pat);
    ASSERT_EQ(p.root->kind, NodeKind::Repeat) << pat;
    EXPECT_EQ(p.root->min, lo) << pat;
    EXPECT_EQ(p.root->max, hi) << pat;
  };
  check("a*", 0, rx::Node::kUnbounded);
  check("a+", 1, rx::Node::kUnbounded);
  check("a?", 0, 1);
  check("a{3}", 3, 3);
  check("a{2,}", 2, rx::Node::kUnbounded);
  check("a{2,5}", 2, 5);
  check("(ab){0}", 0, 0);
  check("a{0,0}", 0, 0);
}

TEST(Parser, ClassRangesAndDashes) {
  auto set = [](const char* pat) { return rx::parse(pat).root->set; };
  auto s = set("[a-c]");
  EXPECT_TRUE(s.contains('b'));
  EXPECT_FALSE(s.contains('d'));
  EXPECT_EQ(s.size(), 3u);
  EXPECT_TRUE(set("[-a]").contains('-'));
  EXPECT_TRUE(set("[a-]").contains('-'));
  EXPECT_EQ(set("[a-]").size(), 2u);
  EXPECT_TRUE(set("[a\\-z]").contains('-'));
  EXPECT_EQ(set("[a\\-z]").size(), 3u);
  EXPECT_TRUE(set("[a^]").contains('^'));
  EXPECT_FALSE(set("[^a]").contains('a'));
  EXPECT_TRUE(set("[\\]\\[]").contains(']'));
  EXPECT_TRUE(set("[\\d_]").contains('7'));
  EXPECT_TRUE(set("[\\d_]").contains('_'));
  EXPECT_TRUE(set("[\\D]").contains('x'));
  EXPECT_TRUE(set("[--/]").contains('.'));
}

TEST(Parser, Escapes) {
  EXPECT_EQ(rx::parse("\\d").root->set.size(), 10u);
  EXPECT_EQ(rx::parse("\\S").root->set.size(), 250u);
  auto lit = rx::parse("\\.");
  EXPECT_EQ(lit.root->kind, NodeKind::Literal);
  EXPECT_EQ(lit.root->ch, '.');
  EXPECT_EQ(rx::parse("\\ ").root->ch, ' ');
}

TEST(Parser, Nullable) {
  EXPECT_TRUE(rx::parse("a*").root->nullable);
  EXPECT_TRUE(rx::parse("(a|)").root->nullable);
  EXPECT_TRUE(rx::parse("^$").root->nullable);
  EXPECT_FALSE(rx::parse("a+").root->nullable);
  EXPECT_TRUE(rx::parse("(a*)+").root->nullable);
  EXPECT_FALSE(rx::parse("ab*").root->nullable);
}

TEST(Parser, RejectsInvalid) {
  for (const char* bad : {"(", ")", "a)", "[", "[a", "[]", "*", "a**", "a{", "a{2", "a{,3}", "a{3,2}",
                          "+a", "^*", "$+", "(*)", "|*", "\\", "\\b", "\\1", "a{01}", "}", "]", "[b-a]",
                          "a{1001}", "[\\q]", "a{1,2,3}"}) {
    EXPECT_THROW(rx::parse(bad), rx::ParseError) << bad;
  }
}

TEST(Parser, ErrorCarriesOffset) {
  try {
    rx::parse("ab(c");
    FAIL();
  } catch (const rx::ParseError& e) {
    EXPECT_EQ(e.offset(), 4u);
  }
}
