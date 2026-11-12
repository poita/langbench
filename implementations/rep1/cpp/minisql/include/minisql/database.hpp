/// @file database.hpp
/// @brief The in-memory database: the library's main entry point.
#pragma once

#include <iosfwd>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "minisql/ast.hpp"
#include "minisql/error.hpp"
#include "minisql/value.hpp"

namespace minisql {

/// A table: column names (lower-case) and rows in insertion order.
struct Table {
  std::string name;
  std::vector<std::string> columns;
  std::vector<Row> rows;
};

/// Outcome of executing one statement.
struct ExecResult {
  bool is_query = false;  ///< true for SELECT
  std::vector<Row> rows;  ///< result rows of a SELECT, in result order
};

/// An in-memory relational database executing a small SQL dialect.
///
/// Every statement is parsed, bound against the current schema and only then
/// executed, so a failing statement leaves the database unchanged.
class Database {
 public:
  /// Parses and executes exactly one statement (a trailing `;` is allowed).
  /// @throws Error on any syntax or semantic error.
  ExecResult execute(std::string_view sql);

  /// Executes a parsed statement. Binding annotates the tree in place.
  /// @throws Error on any semantic error.
  ExecResult execute(Statement& statement);

  /// Executes a script of `;`-terminated statements. The result of each
  /// SELECT is written to `out` (one tab-separated line per row followed by
  /// `-- N rows`); each failing statement writes the line `error` instead.
  void run_script(std::string_view script, std::ostream& out);

  /// Same as above, returning the output as a string.
  std::string run_script(std::string_view script);

  /// Looks a table up by (case-insensitive) name; nullptr if absent.
  const Table* find_table(std::string_view name) const;

 private:
  std::unordered_map<std::string, Table> tables_;
};

}  // namespace minisql
