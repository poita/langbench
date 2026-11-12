#pragma once
/// \file schema.hpp
/// The catalog: `sqlite_schema` rows plus parsed tables and indexes.

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "sqlitefile/ddl.hpp"
#include "sqlitefile/pager.hpp"

namespace sqlitefile {

/// One row of the `sqlite_schema` table.
struct SchemaRow {
  std::string type;
  std::string name;
  std::string tbl_name;
  std::int64_t rootpage = 0;
  std::optional<std::string> sql;
};

/// A table row of the schema whose CREATE TABLE statement was understood.
struct TableInfo {
  std::string name;
  std::uint32_t root_page = 0;
  TableDef def;
};

/// An index row of the schema created by an explicit CREATE INDEX.
struct IndexInfo {
  std::string name;
  std::string table;
  std::uint32_t root_page = 0;
  IndexDef def;
};

/// Everything learned from reading `sqlite_schema` once.
class Catalog {
 public:
  /// Reads page 1 of the database. Throws FormatError if it is unreadable.
  static Catalog load(const Pager& pager);

  /// All schema rows in ascending rowid (schema) order.
  const std::vector<SchemaRow>& rows() const { return rows_; }

  /// Looks up a table (schema type `table`) by name, ASCII case-insensitively.
  const TableInfo* findTable(std::string_view name) const;
  /// Looks up an index created by CREATE INDEX by name.
  const IndexInfo* findIndex(std::string_view name) const;

 private:
  std::vector<SchemaRow> rows_;
  std::vector<TableInfo> tables_;
  std::vector<IndexInfo> indexes_;
};

}  // namespace sqlitefile
