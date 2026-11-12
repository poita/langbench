#include <gtest/gtest.h>

#include "sqlitefile/error.hpp"
#include "sqlitefile/query.hpp"

using namespace sqlitefile;

namespace {
SelectQuery select(const char* line) { return std::get<SelectQuery>(parseQuery(line)); }
bool bad(const char* line) {
  try {
    parseQuery(line);
    return false;
  } catch (const QueryError&) {
    return true;
  }
}
}  // namespace

TEST(Query, DotCommands) {
  EXPECT_TRUE(std::holds_alternative<TablesQuery>(parseQuery(".tables")));
  EXPECT_EQ(std::get<SchemaQuery>(parseQuery(".schema people")).table, "people");
  for (const char* l : {".SCHEMA people", ".TABLES", ".tables extra", ".schema", ".schema a b",
                        ".schema 9bad", ".schema people;", ".schema  people", ".dump"})
    EXPECT_TRUE(bad(l)) << l;
}

TEST(Query, CountAndIndex) {
  EXPECT_EQ(std::get<CountQuery>(parseQuery("count People")).table, "People");
  auto q = std::get<IndexQuery>(parseQuery("INDEX idx 'it''s'"));
  EXPECT_EQ(q.index, "idx");
  EXPECT_EQ(q.key, Value::text("it's"));
  EXPECT_EQ(std::get<IndexQuery>(parseQuery("INDEX i x'0aFF'")).key,
            Value::blob(std::string("\x0a\xff", 2)));
  EXPECT_TRUE(bad("COUNT"));
  EXPECT_TRUE(bad("COUNT a b"));
  EXPECT_TRUE(bad("COUNTa"));
  EXPECT_TRUE(bad("INDEX i"));
  EXPECT_TRUE(bad("INDEX i 1 2"));
}

TEST(Query, SelectColumnsAndSeparators) {
  auto q = select("SELECT  name ,\tage  FROM  people");
  EXPECT_FALSE(q.all_columns);
  EXPECT_EQ(q.columns, (std::vector<std::string>{"name", "age"}));
  EXPECT_EQ(q.table, "people");
  EXPECT_TRUE(select("SELECT*FROM t").all_columns);
  EXPECT_EQ(select("select a,b from t where a>=1 order by b desc limit 3").limit, 3);
  EXPECT_TRUE(bad("SELECTa FROM t"));
  EXPECT_TRUE(bad("SELECT a FROMt"));
  EXPECT_TRUE(bad("SELECT FROM t"));
  EXPECT_TRUE(bad("SELECT a, FROM t"));
  EXPECT_TRUE(bad("SELECT a FROM t ORDERBY a"));
  EXPECT_TRUE(bad("SELECT a FROM t LIMIT3"));
}

TEST(Query, WhereOperators) {
  struct { const char* text; CompareOp op; } cases[] = {
      {"=", CompareOp::Eq}, {"!=", CompareOp::Ne}, {"<", CompareOp::Lt}, {"<=", CompareOp::Le},
      {">", CompareOp::Gt}, {">=", CompareOp::Ge}};
  for (auto& c : cases) {
    auto q = select((std::string("SELECT * FROM t WHERE a") + c.text + "1").c_str());
    ASSERT_EQ(q.where.size(), 1u);
    EXPECT_EQ(q.where[0].op, c.op);
  }
  EXPECT_EQ(select("SELECT * FROM t WHERE a is null").where[0].op, CompareOp::Is);
  EXPECT_EQ(select("SELECT * FROM t WHERE a IS\tNOT NULL").where[0].op, CompareOp::IsNot);
  EXPECT_EQ(select("SELECT * FROM t WHERE a = 1 AND b IS NOT 'x'and c<2").where.size(), 3u);
  for (const char* l : {"SELECT * FROM t WHERE a == 1", "SELECT * FROM t WHERE a <> 1",
                        "SELECT * FROM t WHERE a ISNOT 1", "SELECT * FROM t WHERE a",
                        "SELECT * FROM t WHERE a = 1 AND", "SELECT * FROM t WHERE a = 1 b = 2",
                        "SELECT * FROM t WHERE a = 1 WHERE b = 2"})
    EXPECT_TRUE(bad(l)) << l;
}

TEST(Query, Literals) {
  auto lit = [](const char* l) {
    return select((std::string("SELECT * FROM t WHERE a=") + l).c_str()).where[0].literal;
  };
  EXPECT_EQ(lit("42"), Value::integer(42));
  EXPECT_EQ(lit("-7"), Value::integer(-7));
  EXPECT_EQ(lit("+7"), Value::integer(7));
  EXPECT_EQ(lit("9223372036854775807"), Value::integer(INT64_MAX));
  EXPECT_EQ(lit("-9223372036854775808"), Value::integer(INT64_MIN));
  EXPECT_EQ(lit("1."), Value::real(1.0));
  EXPECT_EQ(lit("-2.5e-3"), Value::real(-0.0025));
  EXPECT_EQ(lit("1E2"), Value::real(100.0));
  EXPECT_EQ(lit("'a''b'"), Value::text("a'b"));
  EXPECT_EQ(lit("''"), Value::text(""));
  EXPECT_EQ(lit("X''"), Value::blob(""));
  EXPECT_EQ(lit("nUlL"), Value::null());
  for (const char* l : {".5", "1e", "1e+", "-", "'abc", "X'0'", "X'zz'", "x'00", "1x", "NULLx",
                        "1.5.2", "abc", "0x10"})
    EXPECT_TRUE(bad((std::string("SELECT * FROM t WHERE a=") + l).c_str())) << l;
  // A string literal needs no separator before the next word.
  EXPECT_EQ(select("SELECT * FROM t WHERE a='x'AND b=1").where.size(), 2u);
}

TEST(Query, OrderByAndLimit) {
  auto q = select("SELECT * FROM t ORDER BY a DESC LIMIT 2");
  EXPECT_EQ(q.order_by->column, "a");
  EXPECT_TRUE(q.order_by->descending);
  EXPECT_FALSE(select("SELECT * FROM t ORDER BY a ASC").order_by->descending);
  EXPECT_FALSE(select("SELECT * FROM t ORDER BY a").order_by->descending);
  EXPECT_EQ(select("SELECT * FROM t LIMIT 0").limit, 0);
  for (const char* l : {"SELECT * FROM t ORDER BY a ASC DESC", "SELECT * FROM t LIMIT -1",
                        "SELECT * FROM t LIMIT x", "SELECT * FROM t LIMIT", "SELECT * FROM t ORDER",
                        "SELECT * FROM t LIMIT 1 ORDER BY a", "SELECT * FROM t EXTRA",
                        "SELECT * FROM t LIMIT 1 LIMIT 2", "SELECT * FROM t LIMIT 1.5"})
    EXPECT_TRUE(bad(l)) << l;
}

TEST(Query, UnknownCommands) {
  for (const char* l : {"DROP TABLE t", "", "FOO", "SELECT", "update t"}) EXPECT_TRUE(bad(l)) << l;
}
