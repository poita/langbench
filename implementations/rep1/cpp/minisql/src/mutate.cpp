// CREATE TABLE, INSERT, UPDATE and DELETE.
#include <algorithm>

#include "internal.hpp"

namespace minisql::detail {

namespace {

Table& find_table_or_throw(Catalog& catalog, const std::string& name) {
  auto it = catalog.find(name);
  if (it == catalog.end()) semantic_error("no such table: " + name);
  return it->second;
}

}  // namespace

void execute_create(Catalog& catalog, CreateTableStmt& stmt) {
  if (catalog.count(stmt.table)) semantic_error("table already exists: " + stmt.table);
  for (std::size_t i = 0; i < stmt.columns.size(); ++i) {
    for (std::size_t j = 0; j < i; ++j) {
      if (stmt.columns[i] == stmt.columns[j]) semantic_error("duplicate column: " + stmt.columns[i]);
    }
  }
  Table t;
  t.name = stmt.table;
  t.columns = stmt.columns;
  catalog.emplace(stmt.table, std::move(t));
}

void execute_insert(Catalog& catalog, InsertStmt& stmt) {
  Table& table = find_table_or_throw(catalog, stmt.table);
  const Scope no_tables;
  const BindOptions options;  // no aggregates, no columns in scope
  for (auto& row : stmt.rows) {
    if (row.size() != table.columns.size()) semantic_error("wrong number of values");
    for (auto& e : row) bind_expr(*e, no_tables, options);
  }
  std::vector<Row> new_rows;
  new_rows.reserve(stmt.rows.size());
  const EvalContext ctx;
  for (auto& row : stmt.rows) {
    Row r;
    r.reserve(row.size());
    for (auto& e : row) r.push_back(evaluate(*e, ctx));
    new_rows.push_back(std::move(r));
  }
  for (auto& r : new_rows) table.rows.push_back(std::move(r));
}

void execute_update(Catalog& catalog, UpdateStmt& stmt) {
  Table& table = find_table_or_throw(catalog, stmt.table);
  const Scope scope{{table.name, &table}};
  const BindOptions options;
  std::vector<std::size_t> targets;
  for (auto& [col, expr] : stmt.assignments) {
    auto it = std::find(table.columns.begin(), table.columns.end(), col);
    if (it == table.columns.end()) semantic_error("no such column: " + col);
    targets.push_back(static_cast<std::size_t>(it - table.columns.begin()));
    bind_expr(*expr, scope, options);
  }
  if (stmt.where) bind_expr(*stmt.where, scope, options);

  std::vector<Value> updated(targets.size());
  for (Row& row : table.rows) {
    EvalContext ctx;
    ctx.rows[0] = &row;
    if (stmt.where && !is_true(evaluate(*stmt.where, ctx))) continue;
    // Right-hand sides see the old values of the row.
    for (std::size_t i = 0; i < targets.size(); ++i) {
      updated[i] = evaluate(*stmt.assignments[i].second, ctx);
    }
    for (std::size_t i = 0; i < targets.size(); ++i) row[targets[i]] = std::move(updated[i]);
  }
}

void execute_delete(Catalog& catalog, DeleteStmt& stmt) {
  Table& table = find_table_or_throw(catalog, stmt.table);
  if (!stmt.where) {
    table.rows.clear();
    return;
  }
  const Scope scope{{table.name, &table}};
  bind_expr(*stmt.where, scope, BindOptions{});
  std::vector<Row> kept;
  kept.reserve(table.rows.size());
  for (Row& row : table.rows) {
    EvalContext ctx;
    ctx.rows[0] = &row;
    if (!is_true(evaluate(*stmt.where, ctx))) kept.push_back(std::move(row));
  }
  table.rows = std::move(kept);
}

}  // namespace minisql::detail
