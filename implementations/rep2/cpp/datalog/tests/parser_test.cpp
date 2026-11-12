#include <gtest/gtest.h>

#include "datalog/parser.h"

using namespace datalog;

TEST(Parser, EmptyAndCommentsOnly) {
  EXPECT_TRUE(parse_program("").rules.empty());
  Program p = parse_program("  % nothing here\n\t\r\n% more");
  EXPECT_TRUE(p.rules.empty());
  EXPECT_TRUE(p.queries.empty());
}

TEST(Parser, FactWithMixedConstants) {
  Program p = parse_program("node(a, 5, -2, a_1).");
  ASSERT_EQ(p.rules.size(), 1u);
  const Atom& h = p.rules[0].head;
  EXPECT_EQ(h.predicate, "node");
  ASSERT_EQ(h.args.size(), 4u);
  EXPECT_EQ(h.args[0].constant, Constant::symbol("a"));
  EXPECT_EQ(h.args[1].constant, Constant::integer(5));
  EXPECT_EQ(h.args[2].constant, Constant::integer(-2));
  EXPECT_EQ(h.args[3].constant, Constant::symbol("a_1"));
  EXPECT_TRUE(p.rules[0].body.empty());
}

TEST(Parser, RuleWithAllLiteralKinds) {
  Program p = parse_program(
      "r(X) :- q(X, _), not s(X), X<=3, X != a, not_x(X), nothing(X).");
  ASSERT_EQ(p.rules.size(), 1u);
  const auto& b = p.rules[0].body;
  ASSERT_EQ(b.size(), 6u);
  EXPECT_EQ(b[0].kind, Literal::Kind::Positive);
  EXPECT_EQ(b[0].atom.args[1].kind, Term::Kind::Anonymous);
  EXPECT_EQ(b[1].kind, Literal::Kind::Negative);
  EXPECT_EQ(b[2].kind, Literal::Kind::Comparison);
  EXPECT_EQ(b[2].op, CompareOp::Le);
  EXPECT_EQ(b[3].op, CompareOp::Ne);
  EXPECT_EQ(b[4].atom.predicate, "not_x");
  EXPECT_EQ(b[5].atom.predicate, "nothing");
}

TEST(Parser, LongestMatchComparison) {
  Program p = parse_program("p(X) :- q(X), X<-1, X>=-3, X>0.");
  const auto& b = p.rules[0].body;
  EXPECT_EQ(b[1].op, CompareOp::Lt);
  EXPECT_EQ(b[1].rhs.constant, Constant::integer(-1));
  EXPECT_EQ(b[2].op, CompareOp::Ge);
  EXPECT_EQ(b[2].rhs.constant, Constant::integer(-3));
  EXPECT_EQ(b[3].op, CompareOp::Gt);
}

TEST(Parser, QueriesKeepOrderAndClausesShareLines) {
  Program p = parse_program("?- p(X). q(1). ?-q(1,_).\n?- p(a).");
  ASSERT_EQ(p.queries.size(), 3u);
  EXPECT_EQ(p.queries[0].atom.predicate, "p");
  EXPECT_EQ(p.queries[1].atom.args.size(), 2u);
  EXPECT_EQ(p.rules.size(), 1u);
}

TEST(Parser, MalformedInputThrows) {
  EXPECT_THROW(parse_program("p(a"), ParseError);
  EXPECT_THROW(parse_program("p(a)"), ParseError);
  EXPECT_THROW(parse_program("p(a) :- ."), ParseError);
  EXPECT_THROW(parse_program("p(a) $ q."), ParseError);
}
