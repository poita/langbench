#include <gtest/gtest.h>

#include "spreadsheet/parser.h"

using namespace spreadsheet;

namespace {
std::vector<std::string> deps(const char* text) {
  std::vector<std::string> out;
  for (CellRef r : parse_formula(text).dependencies()) out.push_back(to_string(r));
  return out;
}
}  // namespace

TEST(Parser, PrecedenceAndAssociativity) {
  // 1+2*3 => Add(1, Mul(2,3))
  Formula f = parse_formula("1+2*3");
  const Expr& root = f.root();
  ASSERT_EQ(root.kind, Expr::Kind::Binary);
  EXPECT_EQ(root.op, BinaryOp::Add);
  EXPECT_EQ(root.args[1]->op, BinaryOp::Mul);

  // 1-2-3 => Sub(Sub(1,2),3)
  Formula g = parse_formula("1-2-3");
  EXPECT_EQ(g.root().args[0]->kind, Expr::Kind::Binary);
  EXPECT_EQ(g.root().args[1]->kind, Expr::Kind::Number);

  // 1<2+3: comparison is the loosest
  EXPECT_EQ(parse_formula("1<2+3").root().op, BinaryOp::Lt);
  // 1+2&3: & is looser than +
  EXPECT_EQ(parse_formula("1+2&3").root().op, BinaryOp::Concat);
}

TEST(Parser, ComparisonOperators) {
  EXPECT_EQ(parse_formula("1<>2").root().op, BinaryOp::Ne);
  EXPECT_EQ(parse_formula("1<=2").root().op, BinaryOp::Le);
  EXPECT_EQ(parse_formula("1>=2").root().op, BinaryOp::Ge);
  EXPECT_EQ(parse_formula("1>2").root().op, BinaryOp::Gt);
  EXPECT_EQ(parse_formula("1=2").root().op, BinaryOp::Eq);
}

TEST(Parser, UnaryMinusNests) {
  Formula f = parse_formula("--5");
  EXPECT_EQ(f.root().kind, Expr::Kind::Negate);
  EXPECT_EQ(f.root().args[0]->kind, Expr::Kind::Negate);
}

TEST(Parser, IgnoresSpaces) {
  EXPECT_EQ(parse_formula("  A1 +  B2 ").dependencies().size(), 2u);
  EXPECT_EQ(parse_formula("IF( 1 , \"a b\" , 2 )").root().kind, Expr::Kind::If);
}

TEST(Parser, StringLiteralKeepsContent) {
  Formula f = parse_formula("\"a  =b\"");
  EXPECT_EQ(f.root().text, "a  =b");
}

TEST(Parser, RangesAndDependencies) {
  EXPECT_EQ(deps("SUM(B2:A1)"), (std::vector<std::string>{"A1", "B1", "A2", "B2"}));
  EXPECT_EQ(deps("A1+A1+SUM(A1:A2)"), (std::vector<std::string>{"A1", "A2"}));
  EXPECT_EQ(deps("IF(A1,B1,C1)"), (std::vector<std::string>{"A1", "B1", "C1"}));
  EXPECT_EQ(deps("1+2"), std::vector<std::string>{});
}

TEST(Parser, InvalidReferencesPoisonTheFormula) {
  for (const char* t : {"AAA1", "A0", "A10000", "A01", "1+IF(1,2,A0)", "SUM(A1:AAA1)"}) {
    Formula f = parse_formula(t);
    EXPECT_TRUE(f.has_invalid_reference()) << t;
    EXPECT_TRUE(f.dependencies().empty()) << t;
  }
  EXPECT_FALSE(parse_formula("ZZ9999").has_invalid_reference());
}

TEST(Parser, RejectsSyntaxErrors) {
  for (const char* t : {"", "1+", "(1", "1)", "SUM()", "FOO(1)", "IF(1,2)", "\"abc", "1 2", "*3"}) {
    EXPECT_THROW(parse_formula(t), ParseError) << t;
  }
}
