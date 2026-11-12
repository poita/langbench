#include <gtest/gtest.h>

#include "db_builder.hpp"
#include "sqlitefile/database.hpp"
#include "sqlitefile/error.hpp"

using namespace sqlitefile;
using testsupport::DbBuilder;
using testsupport::Row;
using testsupport::TreeShape;

namespace {

const char* kPeopleSql =
    "CREATE TABLE people(\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n"
    "    age INTEGER,\n    height REAL,\n    photo BLOB)";

std::string blobOf(const char* s, std::size_t n) { return std::string(s, n); }

// The SPEC.md worked example. The `id` alias is stored as NULL and 0.0 is
// stored as the integer 0, as SQLite does.
Database miniDatabase(std::uint32_t page_size = 4096) {
  DbBuilder b(page_size);
  std::vector<Row> rows = {
      {1, {Value::null(), Value::text("Ada"), Value::integer(36), Value::real(1.65),
           Value::blob(blobOf("\x00\x01\x02", 3))}},
      {2, {Value::null(), Value::text("Grace"), Value::integer(45), Value::real(1.7), Value::null()}},
      {3, {Value::null(), Value::text("Alan"), Value::null(), Value::real(1.8), Value::blob("")}},
      {6, {Value::null(), Value::text(""), Value::integer(0), Value::integer(0),
           Value::blob("\x7f")}},
  };
  b.addTable("people", kPeopleSql, rows, TreeShape{2, 2});
  b.addIndex("people_age", "people", "CREATE INDEX people_age ON people(age)",
             {{Value::null(), Value::integer(3)},
              {Value::integer(0), Value::integer(6)},
              {Value::integer(36), Value::integer(1)},
              {Value::integer(45), Value::integer(2)}});
  return Database::fromBytes(b.build());
}

std::string run(const Database& db, const char* q) { return db.run(q); }

}  // namespace

TEST(Database, WorkedExample) {
  Database db = miniDatabase();
  EXPECT_EQ(run(db, ".tables"), "people\n");
  EXPECT_EQ(run(db, "SELECT * FROM people"),
            "1\tAda\t36\t1.65\t000102\n"
            "2\tGrace\t45\t1.7\tNULL\n"
            "3\tAlan\tNULL\t1.8\t\n"
            "6\t\t0\t0.0\t7F\n");
  EXPECT_EQ(run(db, "SELECT name,height FROM people ORDER BY height DESC LIMIT 2"),
            "Alan\t1.8\nGrace\t1.7\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age IS NULL"), "Alan\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age > 40"), "Grace\n");
  EXPECT_EQ(run(db, "SELECT rowid,name FROM people WHERE photo IS NOT NULL"),
            "1\tAda\n3\tAlan\n6\t\n");
  EXPECT_EQ(run(db, "INDEX people_age 45"), "2\tGrace\t45\t1.7\tNULL\n");
  EXPECT_EQ(run(db, "COUNT people"), "4\n");
  EXPECT_THROW(run(db, "SELECT nope FROM people"), QueryError);
}

TEST(Database, SchemaCommand) {
  Database db = miniDatabase();
  EXPECT_EQ(run(db, ".schema people"),
            std::string(kPeopleSql) + ";\nCREATE INDEX people_age ON people(age);\n");
  EXPECT_EQ(run(db, ".schema PEOPLE"), run(db, ".schema people"));
  EXPECT_EQ(run(db, ".schema people_age"), "");
  EXPECT_EQ(run(db, ".schema nosuch"), "");
}

TEST(Database, ComparisonsAndNulls) {
  Database db = miniDatabase();
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age != 36"), "Grace\n\n");  // '' name, age 0
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age = NULL"), "");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age IS NOT 36 AND age IS NOT NULL"),
            "Grace\n\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age >= 36 AND age <= 45"), "Ada\nGrace\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age = '36'"), "Ada\n");     // affinity
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE age = 36.0"), "Ada\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE name = 5"), "");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE height = 1.65"), "Ada\n");
  EXPECT_EQ(run(db, "SELECT id FROM people WHERE height = 0"), "6\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE photo = x'00'"), "");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE photo = x'000102'"), "Ada\n");
  EXPECT_EQ(run(db, "SELECT name FROM people WHERE rowid >= 3"), "Alan\n\n");
}

TEST(Database, OrderByTiesBreakByRowidBothDirections) {
  DbBuilder b(512);
  std::vector<Row> rows;
  for (int i = 1; i <= 12; ++i)
    rows.push_back({i, {Value::integer(i % 3 == 0 ? 1 : (i % 3 == 1 ? 2 : 0))}});
  rows.push_back({13, {Value::null()}});
  b.addTable("t", "CREATE TABLE t(k INTEGER)", rows, TreeShape{3, 2});
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "SELECT rowid FROM t ORDER BY k"), "13\n2\n5\n8\n11\n3\n6\n9\n12\n1\n4\n7\n10\n");
  EXPECT_EQ(run(db, "SELECT rowid FROM t ORDER BY k DESC LIMIT 6"), "1\n4\n7\n10\n3\n6\n");
  EXPECT_EQ(run(db, "SELECT rowid FROM t ORDER BY k DESC"),
            "1\n4\n7\n10\n3\n6\n9\n12\n2\n5\n8\n11\n13\n");
  EXPECT_EQ(run(db, "SELECT rowid FROM t LIMIT 3"), "1\n2\n3\n");
  EXPECT_EQ(run(db, "SELECT rowid FROM t LIMIT 0"), "");
  EXPECT_EQ(run(db, "SELECT rowid FROM t WHERE k = 1 LIMIT 2"), "3\n6\n");
}

TEST(Database, MixedTypesOrderBy) {
  DbBuilder b;
  std::vector<Row> rows = {{1, {Value::text("b")}},  {2, {Value::integer(5)}},
                           {3, {Value::blob("a")}},  {4, {Value::real(2.5)}},
                           {5, {Value::null()}},     {6, {Value::text("a")}}};
  b.addTable("t", "CREATE TABLE t(v)", rows);
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "SELECT rowid FROM t ORDER BY v"), "5\n4\n2\n6\n1\n3\n");
}

TEST(Database, ShortRecordsReadAsNull) {
  DbBuilder b;
  std::vector<Row> rows = {{1, {Value::integer(1)}},
                           {2, {Value::integer(2), Value::text("x"), Value::integer(4)}}};
  b.addTable("t", "CREATE TABLE t(a INTEGER, b TEXT, c REAL)", rows);
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "SELECT * FROM t"), "1\tNULL\tNULL\n2\tx\t4.0\n");
  EXPECT_EQ(run(db, "SELECT a FROM t WHERE c IS NULL"), "1\n");
}

TEST(Database, TablesListingFiltersAndSorts) {
  DbBuilder b;
  b.addTable("zeta", "CREATE TABLE zeta(a)", {});
  b.addTable("Alpha", "CREATE TABLE Alpha(a)", {});
  b.addTable("sqlite_sequence", "CREATE TABLE sqlite_sequence(name,seq)", {});
  b.addTable("SQLite_x", "CREATE TABLE SQLite_x(a)", {});
  b.addTable("beta", "CREATE TABLE beta(a)", {});
  b.addSchemaRow("view", "v", "v", 0, "CREATE VIEW v AS SELECT 1");
  b.addSchemaRow("trigger", "trg", "beta", 0, "CREATE TRIGGER trg AFTER INSERT ON beta BEGIN SELECT 1; END");
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, ".tables"), "Alpha\nbeta\nzeta\n");
  EXPECT_EQ(run(db, "COUNT sqlite_sequence"), "0\n");
  EXPECT_EQ(run(db, ".schema beta"),
            "CREATE TABLE beta(a);\nCREATE TRIGGER trg AFTER INSERT ON beta BEGIN SELECT 1; END;\n");
  EXPECT_EQ(run(db, ".schema trg"), "");
  EXPECT_THROW(run(db, "SELECT * FROM v"), QueryError);
  EXPECT_THROW(run(db, "COUNT trg"), QueryError);
  EXPECT_THROW(run(db, "SELECT * FROM sqlite_schema"), QueryError);
}

TEST(Database, RowidPseudoColumnRules) {
  DbBuilder b;
  b.addTable("t", "CREATE TABLE t(a TEXT, b)", {{-5, {Value::text("x"), Value::null()}}});
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "SELECT rowid,a FROM t"), "-5\tx\n");
  EXPECT_EQ(run(db, "SELECT a FROM t WHERE rowid = -5"), "x\n");
  EXPECT_EQ(run(db, "SELECT a FROM t WHERE ROWID < '0'"), "x\n");
  EXPECT_THROW(run(db, "SELECT oid FROM t"), QueryError);
  EXPECT_THROW(run(db, "SELECT _rowid_ FROM t"), QueryError);
}

TEST(Database, IndexLookupErrorsAndAffinity) {
  DbBuilder b(512);
  std::vector<Row> rows;
  std::vector<std::vector<Value>> entries;
  for (int i = 1; i <= 30; ++i) rows.push_back({i, {Value::text(std::to_string(i / 3)), Value::integer(i)}});
  // Text keys in byte order of the strings "0".."10".
  std::vector<std::pair<std::string, int>> keyed;
  for (int i = 1; i <= 30; ++i) keyed.push_back({std::to_string(i / 3), i});
  std::sort(keyed.begin(), keyed.end());
  for (auto& [k, id] : keyed) entries.push_back({Value::text(k), Value::integer(id)});
  b.addTable("t", "CREATE TABLE t(code TEXT, n INT, UNIQUE(n))", rows, TreeShape{4, 2});
  b.addIndex("t_code", "t", "CREATE INDEX t_code ON t(code)", entries, TreeShape{3, 2});
  b.addIndex("t_both", "t", "CREATE INDEX t_both ON t(code, n)", {}, TreeShape{3, 2});
  b.addSchemaRow("index", "sqlite_autoindex_t_1", "t", 3, std::nullopt);
  Database db = Database::fromBytes(b.build());
  // An INTEGER literal is converted to TEXT for the TEXT column.
  EXPECT_EQ(run(db, "INDEX t_code 3"), "3\t9\n3\t10\n3\t11\n");
  EXPECT_EQ(run(db, "INDEX t_code '3'"), run(db, "INDEX t_code 3"));
  EXPECT_EQ(run(db, "INDEX t_code 3.0"), "");  // "3.0" is a different text
  EXPECT_EQ(run(db, "INDEX t_code NULL"), "");
  EXPECT_EQ(run(db, "INDEX t_code 'zzz'"), "");
  EXPECT_EQ(run(db, "INDEX T_CODE '0'"), "0\t1\n0\t2\n");
  EXPECT_THROW(run(db, "INDEX t_both 1"), QueryError);                 // two columns
  EXPECT_THROW(run(db, "INDEX sqlite_autoindex_t_1 1"), QueryError);   // auto index
  EXPECT_THROW(run(db, "INDEX t 1"), QueryError);                      // a table
  EXPECT_THROW(run(db, "INDEX nosuch 1"), QueryError);
}

TEST(Database, IndexOnNumericColumnComparesByValue) {
  DbBuilder b(512);
  std::vector<Row> rows = {{1, {Value::integer(5)}}, {2, {Value::real(5.5)}}, {3, {Value::integer(5)}}};
  b.addTable("t", "CREATE TABLE t(x NUMERIC)", rows);
  b.addIndex("ix", "t", "CREATE INDEX ix ON t(x)",
             {{Value::integer(5), Value::integer(1)},
              {Value::integer(5), Value::integer(3)},
              {Value::real(5.5), Value::integer(2)}});
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "INDEX ix '5'"), "5\n5\n");
  EXPECT_EQ(run(db, "INDEX ix 5.0"), "5\n5\n");
  EXPECT_EQ(run(db, "INDEX ix 5.5"), "5.5\n");
}

TEST(Database, LargeTreeAndOverflowRows) {
  DbBuilder b(512);
  std::vector<Row> rows;
  for (int i = 1; i <= 300; ++i)
    rows.push_back({i, {Value::integer(i), Value::text(std::string(i % 7 == 0 ? 900 : 5, 'a' + i % 26))}});
  b.addTable("t", "CREATE TABLE t(id INTEGER PRIMARY KEY, s TEXT)", rows, TreeShape{3, 3});
  Database db = Database::fromBytes(b.build());
  EXPECT_EQ(run(db, "COUNT t"), "300\n");
  std::string out = run(db, "SELECT s FROM t WHERE id = 7");
  EXPECT_EQ(out, std::string(900, 'a' + 7) + "\n");
  EXPECT_EQ(run(db, "SELECT id FROM t ORDER BY id DESC LIMIT 2"), "300\n299\n");
}

TEST(Database, CorruptFileIsReportedNotCrashed) {
  DbBuilder b(512);
  b.addTable("t", "CREATE TABLE t(a)", {{1, {Value::integer(1)}}});
  auto bytes = b.build();
  // Point the table's single leaf at garbage: zero the whole leaf page type.
  bytes[512] = 0x55;
  Database db = Database::fromBytes(bytes);
  EXPECT_THROW(run(db, "SELECT * FROM t"), Error);
  EXPECT_THROW(run(db, "COUNT t"), Error);
}

TEST(Database, OpenMissingFileThrows) {
  EXPECT_THROW(Database::open("/nonexistent/definitely.sqlite"), Error);
}
