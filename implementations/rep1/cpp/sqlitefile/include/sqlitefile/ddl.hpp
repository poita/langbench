#pragma once
/// \file ddl.hpp
/// Parsing of `CREATE TABLE` and `CREATE INDEX` statements (SPEC.md Part 2).

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "sqlitefile/value.hpp"

namespace sqlitefile {

/// One column of a table.
struct Column {
  std::string name;
  std::string declared_type;  ///< may be empty
  Affinity affinity = Affinity::Blob;
};

/// What a `CREATE TABLE` statement says about a table's columns.
struct TableDef {
  std::vector<Column> columns;
  /// Index of the column that aliases the rowid (INTEGER PRIMARY KEY), if any.
  std::optional<std::size_t> rowid_alias;

  /// ASCII case-insensitive column lookup.
  std::optional<std::size_t> findColumn(std::string_view name) const;
};

/// What a `CREATE INDEX` statement says about an index.
struct IndexDef {
  std::vector<std::string> columns;
  std::vector<bool> descending;  ///< parallel to `columns`
};

/// Parses a CREATE TABLE statement. Throws FormatError if it is not one.
TableDef parseCreateTable(std::string_view sql);

/// Parses a CREATE INDEX statement. Throws FormatError if it is not one.
IndexDef parseCreateIndex(std::string_view sql);

/// ASCII case-insensitive equality.
bool equalsIgnoreCase(std::string_view a, std::string_view b);

}  // namespace sqlitefile
