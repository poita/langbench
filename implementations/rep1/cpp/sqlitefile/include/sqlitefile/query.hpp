#pragma once
/// \file query.hpp
/// The query language: one command per line (SPEC.md Part 4).

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "sqlitefile/value.hpp"

namespace sqlitefile {

/// `.tables`
struct TablesQuery {};

/// `.schema <table>`
struct SchemaQuery {
  std::string table;
};

/// `COUNT <table>`
struct CountQuery {
  std::string table;
};

enum class CompareOp { Eq, Ne, Lt, Le, Gt, Ge, Is, IsNot };

/// `<column> <op> <literal>`
struct Condition {
  std::string column;
  CompareOp op = CompareOp::Eq;
  Value literal;
};

struct OrderBy {
  std::string column;
  bool descending = false;
};

/// `SELECT ... FROM ... [WHERE ...] [ORDER BY ...] [LIMIT n]`
struct SelectQuery {
  bool all_columns = false;          ///< `*`
  std::vector<std::string> columns;  ///< when not `*`
  std::string table;
  std::vector<Condition> where;      ///< joined by AND
  std::optional<OrderBy> order_by;
  std::optional<std::int64_t> limit;
};

/// `INDEX <index-name> <literal>`
struct IndexQuery {
  std::string index;
  Value key;
};

using Query =
    std::variant<TablesQuery, SchemaQuery, CountQuery, SelectQuery, IndexQuery>;

/// Parses one query line. Throws QueryError if the line is not a valid query.
/// Names are not resolved here.
Query parseQuery(std::string_view line);

}  // namespace sqlitefile
