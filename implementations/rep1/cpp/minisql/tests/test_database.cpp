#include <gtest/gtest.h>

#include "minisql/database.hpp"

using minisql::Database;

namespace {
std::string run(const std::string& script) {
  Database db;
  return db.run_script(script);
}
}  // namespace

TEST(Database, SpecExample1) {
  const char* script =
      "CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);\n"
      "INSERT INTO emp VALUES (1,'ann','eng',120),(2,'bob','ops',90),(3,'cy','eng',NULL),(4,'dee',NULL,100);\n"
      "SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;\n"
      "SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;\n"
      "SELECT * FROM nosuch;\n"
      "UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';\n"
      "SELECT id, salary FROM emp;\n";
  EXPECT_EQ(run(script),
            "ann\t120\ndee\t100\n-- 2 rows\n"
            "NULL\t1\t100\t100.00\neng\t2\t120\t120.00\nops\t1\t90\t90.00\n-- 3 rows\n"
            "error\n"
            "1\t125\n2\t90\n3\tNULL\n4\t100\n-- 4 rows\n");
}

TEST(Database, JoinsKeepNestedLoopOrder) {
  const char* script =
      "CREATE TABLE a (x INTEGER, s TEXT); CREATE TABLE b (y INTEGER, t TEXT);"
      "INSERT INTO a VALUES (3,'c'),(1,'a'),(2,'b'),(1,'aa');"
      "INSERT INTO b VALUES (1,'p'),(2,'q'),(1,'r'),(3,'s');"
      "SELECT s, t FROM a, b WHERE x = y AND t != 'p';"
      "SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;"
      "SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;";
  EXPECT_EQ(run(script),
            "c\ts\na\tr\nb\tq\naa\tr\n-- 4 rows\n"
            "a\taa\n-- 1 rows\n"
            "1\t4\n2\t1\n-- 2 rows\n");
}

TEST(Database, ExpressionsWithoutFrom) {
  EXPECT_EQ(run("SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';"),
            "3\t-3\t1\tNULL\t1\t1\tNULL\t1\n-- 1 rows\n");
}

TEST(Database, FailedStatementHasNoEffect) {
  Database db;
  EXPECT_EQ(db.run_script("CREATE TABLE t (a INTEGER);"
                          "INSERT INTO t VALUES (1), (2, 3);"
                          "SELECT COUNT(*) FROM t;"),
            "error\n0\n-- 1 rows\n");
}

TEST(Database, UpdateSwapsUsingOldValues) {
  EXPECT_EQ(run("CREATE TABLE t (a INTEGER, b INTEGER); INSERT INTO t VALUES (1, 2);"
                "UPDATE t SET a = b, b = a; SELECT a, b FROM t;"),
            "2\t1\n-- 1 rows\n");
}

TEST(Database, AggregateRulesAndErrors) {
  EXPECT_EQ(run("CREATE TABLE t (a INTEGER, b INTEGER);"
                "SELECT a, COUNT(*) FROM t;"
                "SELECT COUNT(*) FROM t WHERE COUNT(*) > 0;"
                "SELECT SUM(COUNT(*)) FROM t;"
                "SELECT a FROM t HAVING a = 1;"
                "SELECT COUNT(*), SUM(a) FROM t;"),
            "error\nerror\nerror\nerror\n0\tNULL\n-- 1 rows\n");
}

TEST(Database, AvgRoundsHalfAwayFromZero) {
  EXPECT_EQ(run("CREATE TABLE t (a INTEGER);"
                "INSERT INTO t VALUES (1),(1),(1),(1),(1),(1),(1),(2);"
                "SELECT AVG(a) FROM t;"
                "DELETE FROM t; INSERT INTO t VALUES (-1),(-1),(-1),(-1),(-1),(-1),(-1),(-2);"
                "SELECT AVG(a) FROM t;"),
            "1.13\n-- 1 rows\n-1.13\n-- 1 rows\n");
}

TEST(Database, OrderByAliasOrdinalAndErrors) {
  EXPECT_EQ(run("CREATE TABLE t (x INTEGER, y INTEGER); INSERT INTO t VALUES (2,1),(1,2);"
                "SELECT *, x AS k FROM t ORDER BY k;"
                "SELECT x, y FROM t ORDER BY 2 DESC;"
                "SELECT x FROM t ORDER BY 2;"
                "SELECT x FROM t ORDER BY 0;"),
            "1\t2\t1\n2\t1\t2\n-- 2 rows\n1\t2\n2\t1\n-- 2 rows\nerror\nerror\n");
}

TEST(Database, ColumnResolutionErrors) {
  EXPECT_EQ(run("CREATE TABLE a (x INTEGER); CREATE TABLE b (x INTEGER);"
                "SELECT x FROM a, b;"
                "SELECT a.x FROM a q;"
                "SELECT q.x FROM a q, b;"
                "SELECT 1 FROM a, a;"
                "SELECT 1 FROM a p, a q;"),
            "error\nerror\n-- 0 rows\nerror\n-- 0 rows\n");
}

TEST(Database, UnterminatedStringEndsScript) {
  EXPECT_EQ(run("SELECT 1; SELECT 'abc; SELECT 2;"), "1\n-- 1 rows\nerror\n");
}

TEST(Database, ApiExecuteReturnsRows) {
  Database db;
  db.execute("CREATE TABLE t (a INTEGER)");
  db.execute("INSERT INTO t VALUES (3), (1)");
  auto r = db.execute("SELECT a FROM t ORDER BY a");
  ASSERT_TRUE(r.is_query);
  ASSERT_EQ(r.rows.size(), 2u);
  EXPECT_EQ(r.rows[0][0].as_integer(), 1);
  EXPECT_NE(db.find_table("T"), nullptr);
  EXPECT_THROW(db.execute("SELECT nope FROM t"), minisql::Error);
}
