#include <gtest/gtest.h>

#include "sqlitefile/ddl.hpp"
#include "sqlitefile/error.hpp"

using namespace sqlitefile;

namespace {
std::optional<std::size_t> alias(const char* sql) { return parseCreateTable(sql).rowid_alias; }
}  // namespace

TEST(CreateTable, ColumnsTypesAndAffinities) {
  auto t = parseCreateTable(
      "CREATE TABLE people(\n id INTEGER PRIMARY KEY,\n name TEXT NOT NULL,\n"
      " price NUMERIC(10,2) DEFAULT 'a,b',\n raw, nv NVARCHAR(160) COLLATE NOCASE)");
  ASSERT_EQ(t.columns.size(), 5u);
  EXPECT_EQ(t.columns[0].name, "id");
  EXPECT_EQ(t.columns[1].declared_type, "TEXT");
  EXPECT_EQ(t.columns[2].declared_type, "NUMERIC(10,2)");
  EXPECT_EQ(t.columns[2].affinity, Affinity::Numeric);
  EXPECT_EQ(t.columns[3].declared_type, "");
  EXPECT_EQ(t.columns[3].affinity, Affinity::Blob);
  EXPECT_EQ(t.columns[4].affinity, Affinity::Text);
  EXPECT_EQ(t.rowid_alias, 0u);
}

TEST(CreateTable, QuotingAndComments) {
  auto t = parseCreateTable(
      "CREATE TABLE IF NOT EXISTS main.\"t\" ( -- first\n [A Id] INTEGER, `b``c` TEXT, "
      "/* x, y */ \"q\"\"r\" REAL)");
  ASSERT_EQ(t.columns.size(), 3u);
  EXPECT_EQ(t.columns[0].name, "A Id");
  EXPECT_EQ(t.columns[1].name, "b`c");
  EXPECT_EQ(t.columns[2].name, "q\"r");
}

TEST(CreateTable, SkipsTableConstraints) {
  auto t = parseCreateTable(
      "CREATE TABLE t(a INT, b INT, UNIQUE(a,b), CHECK(a>0 AND b>0), "
      "CONSTRAINT fk FOREIGN KEY(a) REFERENCES u(x))");
  EXPECT_EQ(t.columns.size(), 2u);
}

TEST(RowidAlias, ColumnConstraintForms) {
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER PRIMARY KEY, y)"), 0u);
  EXPECT_EQ(alias("CREATE TABLE t(y, x integer primary key autoincrement)"), 1u);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER PRIMARY KEY ASC)"), 0u);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER PRIMARY KEY DESC)"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x INT PRIMARY KEY)"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER(4) PRIMARY KEY)"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x UNSIGNED INTEGER PRIMARY KEY)"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER NOT NULL PRIMARY KEY)"), 0u);
}

TEST(RowidAlias, TableConstraintForms) {
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER, PRIMARY KEY(x))"), 0u);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER, PRIMARY KEY(x DESC))"), 0u);
  EXPECT_EQ(alias("CREATE TABLE t(a, [x] INTEGER NOT NULL, CONSTRAINT [PK] PRIMARY KEY ([x]))"), 1u);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER, y INTEGER, PRIMARY KEY(x, y))"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x INT, PRIMARY KEY(x))"), std::nullopt);
  EXPECT_EQ(alias("CREATE TABLE t(x INTEGER, y, PRIMARY KEY(y))"), std::nullopt);
}

TEST(CreateTable, RejectsOtherStatements) {
  EXPECT_THROW(parseCreateTable("CREATE INDEX i ON t(a)"), FormatError);
  EXPECT_THROW(parseCreateTable("CREATE TABLE t"), FormatError);
  EXPECT_THROW(parseCreateTable("CREATE TABLE t(a, b"), FormatError);
}

TEST(CreateIndex, ColumnsAndDirection) {
  auto i = parseCreateIndex("CREATE UNIQUE INDEX IF NOT EXISTS \"i\" ON t(a COLLATE BINARY, b DESC)");
  ASSERT_EQ(i.columns.size(), 2u);
  EXPECT_EQ(i.columns[0], "a");
  EXPECT_EQ(i.columns[1], "b");
  EXPECT_FALSE(i.descending[0]);
  EXPECT_TRUE(i.descending[1]);
}

TEST(CreateIndex, RejectsOtherStatements) {
  EXPECT_THROW(parseCreateIndex("CREATE TABLE t(a)"), FormatError);
}

TEST(EqualsIgnoreCase, Basics) {
  EXPECT_TRUE(equalsIgnoreCase("AbC", "aBc"));
  EXPECT_FALSE(equalsIgnoreCase("abc", "abd"));
  EXPECT_FALSE(equalsIgnoreCase("abc", "ab"));
}
