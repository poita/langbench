#pragma once
// Test helper: assembles small SQLite database images in memory so the unit
// tests do not depend on external files. It writes the on-disk format
// independently of the library's reader (apart from reusing the documented
// overflow-threshold function).

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "sqlitefile/value.hpp"

namespace testsupport {

using Bytes = std::vector<std::uint8_t>;

void appendVarint(Bytes& out, std::int64_t v);
Bytes encodeRecord(const std::vector<sqlitefile::Value>& values);

struct Row {
  std::int64_t rowid;
  std::vector<sqlitefile::Value> values;
};

struct TreeShape {
  std::size_t leaf_cells = 4;      // cells per leaf page
  std::size_t interior_cells = 3;  // children per interior page (>= 2)
};

class DbBuilder {
 public:
  explicit DbBuilder(std::uint32_t page_size = 4096) : page_size_(page_size) {}

  /// Builds a table B-tree for the rows (ascending rowid); returns its root page.
  std::uint32_t addTableTree(const std::vector<Row>& rows, TreeShape shape = {});

  /// Builds an index B-tree for entries already sorted in key order (each
  /// entry is the indexed values followed by the rowid); returns its root page.
  std::uint32_t addIndexTree(const std::vector<std::vector<sqlitefile::Value>>& entries,
                             TreeShape shape = {});

  /// Appends a row to sqlite_schema (page 1).
  void addSchemaRow(const std::string& type, const std::string& name, const std::string& tbl_name,
                    std::int64_t rootpage, const std::optional<std::string>& sql);

  /// Convenience: table tree + its schema row.
  std::uint32_t addTable(const std::string& name, const std::string& sql,
                         const std::vector<Row>& rows, TreeShape shape = {});
  /// Convenience: index tree + its schema row.
  std::uint32_t addIndex(const std::string& name, const std::string& table, const std::string& sql,
                         const std::vector<std::vector<sqlitefile::Value>>& entries,
                         TreeShape shape = {});

  Bytes build();

 private:
  std::uint32_t allocate();
  Bytes& pageBytes(std::uint32_t n) { return pages_[n - 2]; }
  Bytes makeCell(bool table_leaf, const Bytes* prefix, const Bytes& payload);
  std::uint32_t writePage(std::uint8_t type, const std::vector<Bytes>& cells,
                          std::uint32_t right_child);
  Bytes layoutPage(std::uint8_t type, const std::vector<Bytes>& cells, std::uint32_t right_child,
                   std::size_t base);

  std::uint32_t page_size_;
  std::vector<Bytes> pages_;  // pages 2..N
  struct SchemaRow {
    std::string type, name, tbl;
    std::int64_t root;
    std::optional<std::string> sql;
  };
  std::vector<SchemaRow> schema_;
};

}  // namespace testsupport
