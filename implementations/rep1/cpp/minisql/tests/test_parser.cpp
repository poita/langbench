#include <gtest/gtest.h>

#include "minisql/error.hpp"
#include "minisql/parser.hpp"

using namespace minisql;

namespace {
bool fails(const char* sql) {
  try {
    parse_statement(sql);
  } catch (const Error& e) {
    return e.kind() == ErrorKind::Syntax;
  }
  return false;
}
}  // namespace

TEST(Parser, CreateTable) {
  auto st = parse_statement("CREATE TABLE T (a INTEGER, B text);");
  auto& c = std::get<CreateTableStmt>(st);
  EXPECT_EQ(c.table, "t");
  EXPECT_EQ(c.columns, (std::vector<std::string>{"a", "b"}));
}

TEST(Parser, PrecedenceNotBindsLooserThanEquality) {
  auto st = parse_statement("SELECT NOT a = 1");
  auto& e = *std::get<SelectStmt>(st).items[0].expr;
  EXPECT_EQ(e.kind, ExprKind::Unary);
  EXPECT_EQ(e.unary_op, UnaryOp::Not);
  EXPECT_EQ(e.lhs->kind, ExprKind::Binary);
}

TEST(Parser, RelationalBindsTighterThanEquality) {
  auto st = parse_statement("SELECT 1 < 2 = 1");
  auto& e = *std::get<SelectStmt>(st).items[0].expr;
  EXPECT_EQ(e.binary_op, BinaryOp::Eq);
  EXPECT_EQ(e.lhs->binary_op, BinaryOp::Lt);
}

TEST(Parser, AliasesAndJoin) {
  auto st = parse_statement("SELECT p.s x FROM a p INNER JOIN a AS q ON p.x = q.x");
  auto& s = std::get<SelectStmt>(st);
  EXPECT_EQ(s.items[0].alias, "x");
  ASSERT_EQ(s.from.size(), 2u);
  EXPECT_EQ(s.from[0].alias, "p");
  EXPECT_EQ(s.from[1].alias, "q");
  EXPECT_NE(s.join_on, nullptr);
}

TEST(Parser, OrderByRecordsBareTerms) {
  auto st = parse_statement("SELECT a FROM t ORDER BY n DESC, 2, a + 1");
  auto& o = std::get<SelectStmt>(st).order_by;
  EXPECT_EQ(o[0].bare_identifier, "n");
  EXPECT_TRUE(o[0].descending);
  EXPECT_EQ(o[1].ordinal, 2);
  EXPECT_TRUE(o[2].bare_identifier.empty());
  EXPECT_FALSE(o[2].ordinal.has_value());
}

TEST(Parser, CountAsColumnName) {
  EXPECT_NO_THROW(parse_statement("SELECT count FROM t"));
  EXPECT_NO_THROW(parse_statement("SELECT count (*) FROM t"));
}

TEST(Parser, SyntaxErrors) {
  EXPECT_TRUE(fails("DROP TABLE t"));
  EXPECT_TRUE(fails("SELECT 1.5"));
  EXPECT_TRUE(fails("SELECT a FROM t LEFT JOIN u ON 1"));
  EXPECT_TRUE(fails("SELECT a FROM t, u, v"));
  EXPECT_TRUE(fails("SELECT a AS left FROM t"));
  EXPECT_TRUE(fails("CREATE TABLE t (text TEXT)"));
  EXPECT_TRUE(fails("CREATE TABLE t (a REAL)"));
  EXPECT_TRUE(fails("SELECT a FROM t GROUP BY a + 1"));
  EXPECT_TRUE(fails("SELECT a FROM t HAVING a"));
  EXPECT_TRUE(fails("SELECT a FROM t LIMIT -1"));
  EXPECT_TRUE(fails("SELECT a FROM t OFFSET 1"));
  EXPECT_TRUE(fails("SELECT foo(1)"));
  EXPECT_TRUE(fails("SELECT 'x' || 'y'"));
  EXPECT_TRUE(fails("INSERT INTO t (a) VALUES (1)"));
  EXPECT_TRUE(fails("SELECT 1 IN (1)"));
  EXPECT_TRUE(fails("SELECT \"a\""));
}
