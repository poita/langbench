#pragma once
/// \file database.hpp
/// The high-level entry point: open a database file and run queries.

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

#include "sqlitefile/pager.hpp"
#include "sqlitefile/query.hpp"
#include "sqlitefile/schema.hpp"

namespace sqlitefile {

/// A read-only view of a SQLite database file.
///
/// The schema is read once when the database is opened; every query then walks
/// the B-trees afresh, caching nothing.
class Database {
 public:
  /// Reads the file and its schema. Throws Error/FormatError on failure.
  static Database open(const std::filesystem::path& path);
  /// Same, from an in-memory image of a database file.
  static Database fromBytes(std::vector<std::uint8_t> bytes);

  const Pager& pager() const { return pager_; }
  const Catalog& catalog() const { return catalog_; }

  /// Parses and executes one query line (SPEC.md Part 4) and returns its
  /// output: zero or more lines, each terminated by '\n'.
  /// Throws QueryError for an invalid query and FormatError if the file is
  /// corrupt in the part the query touches.
  std::string run(std::string_view line) const;

  /// Executes an already parsed query.
  std::string execute(const Query& query) const;

 private:
  explicit Database(Pager pager);

  std::string tables() const;
  std::string schema(const SchemaQuery& q) const;
  std::string count(const CountQuery& q) const;
  std::string select(const SelectQuery& q) const;
  std::string indexLookup(const IndexQuery& q) const;

  Pager pager_;
  Catalog catalog_;
};

}  // namespace sqlitefile
