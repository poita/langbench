#include <gtest/gtest.h>

#include "datalog/datalog.h"
#include "datalog/lexer.h"

using namespace datalog;

TEST(Lexer, LongestMatchAndNegativeIntegers) {
  auto toks = tokenize("X<-1 <= >= != :- ?- not nothing _");
  std::vector<TokenKind> kinds;
  for (auto& t : toks) kinds.push_back(t.kind);
  std::vector<TokenKind> want = {TokenKind::Variable, TokenKind::Lt,    TokenKind::Integer,
                                 TokenKind::Le,       TokenKind::Ge,    TokenKind::Ne,
                                 TokenKind::Implies,  TokenKind::QueryMark, TokenKind::Not,
                                 TokenKind::Identifier, TokenKind::Anonymous, TokenKind::End};
  EXPECT_EQ(kinds, want);
  EXPECT_EQ(toks[2].integer, -1);
}

TEST(Lexer, CommentsAndWhitespace) {
  auto toks = tokenize("% only a comment\n\t \r\n");
  ASSERT_EQ(toks.size(), 1u);
  EXPECT_EQ(toks[0].kind, TokenKind::End);
}

TEST(Parser, FactsRulesQueries) {
  Program p = parse_program(
      "edge(a, 1). path(X, Y) :- edge(X, Y), not blocked(Y), X != _ , 3 < Y.\n"
      "?- path(a, X).");
  ASSERT_EQ(p.rules.size(), 2u);
  EXPECT_TRUE(p.rules[0].is_fact());
  EXPECT_EQ(p.rules[0].head.args[1].constant_value(), Constant::integer(1));
  ASSERT_EQ(p.rules[1].body.size(), 4u);
  EXPECT_EQ(p.rules[1].body[0].kind, Literal::Kind::Positive);
  EXPECT_EQ(p.rules[1].body[1].kind, Literal::Kind::Negative);
  EXPECT_EQ(p.rules[1].body[2].kind, Literal::Kind::Comparison);
  EXPECT_EQ(p.rules[1].body[2].op, CompareOp::Ne);
  EXPECT_TRUE(p.rules[1].body[2].rhs.is_anonymous());
  EXPECT_EQ(p.rules[1].body[3].lhs.constant_value(), Constant::integer(3));
  ASSERT_EQ(p.queries.size(), 1u);
  EXPECT_EQ(to_string(p.queries[0]), "path(a, X)");
}

TEST(Parser, PredicateAndConstantNamespacesAreSeparate) {
  Program p = parse_program("edge(edge, path).");
  EXPECT_EQ(p.rules[0].head.predicate, "edge");
  EXPECT_EQ(p.rules[0].head.args[0].constant_value(), Constant::symbol("edge"));
}

TEST(Parser, MalformedInputThrows) {
  EXPECT_THROW(parse_program("p(a)"), ParseError);
  EXPECT_THROW(parse_program("p(a) :- ."), ParseError);
  EXPECT_THROW(parse_program("p() ."), ParseError);
  EXPECT_THROW(parse_program("p(a) # ."), ParseError);
}

TEST(Constant, Ordering) {
  EXPECT_TRUE(Constant::integer(100) < Constant::symbol("a"));
  EXPECT_TRUE(Constant::integer(-2) < Constant::integer(5));
  EXPECT_TRUE(Constant::symbol("a_") < Constant::symbol("a_b"));
  EXPECT_TRUE(Constant::symbol("a_b") < Constant::symbol("aa"));
  EXPECT_FALSE(Constant::symbol("b") < Constant::symbol("a"));
  EXPECT_NE(Constant::integer(5), Constant::symbol("5"));
}

TEST(ValueEncoder, PreservesOrder) {
  Program p = parse_program("p(b). p(a). p(a0). p(-3). p(7).");
  ValueEncoder e = ValueEncoder::of(p);
  Value v[] = {*e.encode(Constant::integer(-3)), *e.encode(Constant::integer(7)),
               *e.encode(Constant::symbol("a")), *e.encode(Constant::symbol("a0")),
               *e.encode(Constant::symbol("b"))};
  for (int i = 0; i + 1 < 5; ++i) EXPECT_LT(v[i], v[i + 1]);
  EXPECT_FALSE(e.encode(Constant::symbol("zzz")).has_value());
  EXPECT_EQ(e.decode(v[3]), Constant::symbol("a0"));
  EXPECT_EQ(e.text(v[0]), "-3");
}
