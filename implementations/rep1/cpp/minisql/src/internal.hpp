// Internal interfaces shared by the binder, evaluator and executors.
#pragma once

#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "minisql/ast.hpp"
#include "minisql/database.hpp"
#include "minisql/error.hpp"

namespace minisql::detail {

using Catalog = std::unordered_map<std::string, Table>;

[[noreturn]] inline void semantic_error(const std::string& msg) {
  throw Error(ErrorKind::Semantic, msg);
}

// ---- binder ---------------------------------------------------------------

/// A table visible to a query under its effective name.
struct Source {
  std::string name;
  const Table* table;
};
using Scope = std::vector<Source>;

using ColumnSlot = std::pair<int, int>;  // (source index, column index)

struct BindOptions {
  bool allow_aggregates = false;
  /// Aggregate query: columns outside an aggregate must be grouping columns.
  bool grouped = false;
  const std::vector<ColumnSlot>* group_columns = nullptr;
  /// Receives every aggregate node, in binding order (indexes `agg_index`).
  std::vector<const Expr*>* aggregates = nullptr;
};

ColumnSlot resolve_column(const Scope& scope, const std::string& qualifier,
                          const std::string& name);
void bind_expr(Expr& e, const Scope& scope, const BindOptions& options);
bool contains_aggregate(const Expr& e);

// ---- evaluator ------------------------------------------------------------

struct EvalContext {
  const Row* rows[2] = {nullptr, nullptr};
  const Value* aggregates = nullptr;
};

Value evaluate(const Expr& e, const EvalContext& ctx);
/// True iff the value is "true" in boolean context (NULL and 0 are not).
bool is_true(const Value& v);

// ---- statement executors --------------------------------------------------

ExecResult execute_select(const Catalog& catalog, SelectStmt& stmt);
void execute_create(Catalog& catalog, CreateTableStmt& stmt);
void execute_insert(Catalog& catalog, InsertStmt& stmt);
void execute_update(Catalog& catalog, UpdateStmt& stmt);
void execute_delete(Catalog& catalog, DeleteStmt& stmt);

}  // namespace minisql::detail
