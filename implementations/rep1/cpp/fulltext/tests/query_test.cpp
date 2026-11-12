#include <gtest/gtest.h>

#include <functional>

#include "fulltext/query.hpp"

using namespace fulltext;

namespace {

/// Renders a tree as an S-expression: atoms as `t1_t2`, `(AND ...)`, ...
std::string show(const QueryNode* n) {
  if (!n) return "<empty>";
  std::string s;
  switch (n->kind) {
    case QueryNode::Kind::Atom:
      for (std::size_t i = 0; i < n->atom.size(); ++i) s += (i ? "_" : "") + n->atom[i];
      return s;
    case QueryNode::Kind::Not:
      return "(NOT " + show(n->children[0].get()) + ")";
    default:
      s = n->kind == QueryNode::Kind::And ? "(AND" : "(OR";
      for (const auto& c : n->children) s += " " + show(c.get());
      return s + ")";
  }
}

std::string parse(std::string_view q) { return show(parse_query(q).root.get()); }

}  // namespace

TEST(QueryParser, EmptyTrees) {
  EXPECT_EQ(parse("()"), "<empty>");
  EXPECT_EQ(parse("the"), "<empty>");
  EXPECT_EQ(parse("NOT"), "<empty>");
  EXPECT_EQ(parse(""), "<empty>");
  EXPECT_EQ(parse("\"\""), "<empty>");
}

TEST(QueryParser, RecoveryRules) {
  for (const char* q : {"cat AND", "OR cat", "cat ()", "cat NOT ()", "cat NOT (", "(cat", "\"cat",
                        "cat ) dog", "cat ) ) dog"}) {
    EXPECT_EQ(parse(q), "cat") << q;
  }
  EXPECT_EQ(parse("cat OR AND dog"), "(OR cat dog)");
  EXPECT_EQ(parse("cat AND OR dog"), "(OR cat dog)");
  EXPECT_EQ(parse("cat AND AND dog"), "(AND cat dog)");
  EXPECT_EQ(parse("dog NOT ( cat"), "(AND dog (NOT cat))");
}

TEST(QueryParser, PrecedenceAndJuxtaposition) {
  EXPECT_EQ(parse("cat dog"), "(AND cat dog)");
  EXPECT_EQ(parse("cat OR dog fish"), "(OR cat (AND dog fish))");
  EXPECT_EQ(parse("NOT cat dog"), "(AND (NOT cat) dog)");
  EXPECT_EQ(parse("NOT NOT cat"), "(NOT (NOT cat))");
  EXPECT_EQ(parse("(cat OR dog) fish"), "(AND (OR cat dog) fish)");
}

TEST(QueryParser, AtomsAreAnalysed) {
  EXPECT_EQ(parse("\"Running Dogs\""), "run_dog");
  EXPECT_EQ(parse("well-known"), "well_known");
  EXPECT_EQ(parse("\"to be or not to be\""), "to_be_or_not_to_be");
  EXPECT_EQ(parse("\"the\""), "<empty>");
  EXPECT_EQ(parse("and or not"), "<empty>");  // lower-case operators are stop words
  EXPECT_EQ(parse("cat and dog"), "(AND cat dog)");
}

TEST(QueryParser, PositiveAtoms) {
  const Query q = parse_query("cat NOT dog (NOT NOT fish) NOT (cat OR NOT bird) cat");
  const std::vector<Atom> expected = {{"cat"}, {"fish"}, {"bird"}};
  EXPECT_EQ(q.positive_atoms, expected);
  EXPECT_TRUE(parse_query("NOT cat").positive_atoms.empty());
  EXPECT_TRUE(parse_query("").positive_atoms.empty());
}

TEST(QueryParser, NbspSeparatesWords) {
  EXPECT_EQ(parse("cat\xC2\xA0" "dog"), "(AND cat dog)");
}
