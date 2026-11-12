#include <algorithm>

#include "internal.hpp"

namespace minisql::detail {

ColumnSlot resolve_column(const Scope& scope, const std::string& qualifier,
                          const std::string& name) {
  auto find_in = [&](const Table& t) -> int {
    for (std::size_t i = 0; i < t.columns.size(); ++i) {
      if (t.columns[i] == name) return static_cast<int>(i);
    }
    return -1;
  };
  if (!qualifier.empty()) {
    for (std::size_t s = 0; s < scope.size(); ++s) {
      if (scope[s].name != qualifier) continue;
      const int c = find_in(*scope[s].table);
      if (c < 0) semantic_error("no such column: " + qualifier + "." + name);
      return {static_cast<int>(s), c};
    }
    semantic_error("no such table: " + qualifier);
  }
  ColumnSlot found{-1, -1};
  for (std::size_t s = 0; s < scope.size(); ++s) {
    const int c = find_in(*scope[s].table);
    if (c < 0) continue;
    if (found.first >= 0) semantic_error("ambiguous column: " + name);
    found = {static_cast<int>(s), c};
  }
  if (found.first < 0) semantic_error("no such column: " + name);
  return found;
}

namespace {

void bind_rec(Expr& e, const Scope& scope, const BindOptions& o, bool in_aggregate) {
  switch (e.kind) {
    case ExprKind::Literal:
      return;
    case ExprKind::Column: {
      const ColumnSlot slot = resolve_column(scope, e.qualifier, e.name);
      e.table = slot.first;
      e.column = slot.second;
      if (o.grouped && !in_aggregate) {
        const bool ok = o.group_columns != nullptr &&
                        std::find(o.group_columns->begin(), o.group_columns->end(), slot) !=
                            o.group_columns->end();
        if (!ok) semantic_error("column is not grouped: " + e.name);
      }
      return;
    }
    case ExprKind::Unary:
    case ExprKind::IsNull:
      bind_rec(*e.lhs, scope, o, in_aggregate);
      return;
    case ExprKind::Binary:
    case ExprKind::Like:
      bind_rec(*e.lhs, scope, o, in_aggregate);
      bind_rec(*e.rhs, scope, o, in_aggregate);
      return;
    case ExprKind::Aggregate:
      if (!o.allow_aggregates || in_aggregate || o.aggregates == nullptr) {
        semantic_error("misuse of aggregate function");
      }
      if (e.lhs) bind_rec(*e.lhs, scope, o, true);
      e.agg_index = static_cast<int>(o.aggregates->size());
      o.aggregates->push_back(&e);
      return;
  }
}

}  // namespace

void bind_expr(Expr& e, const Scope& scope, const BindOptions& options) {
  bind_rec(e, scope, options, false);
}

bool contains_aggregate(const Expr& e) {
  if (e.kind == ExprKind::Aggregate) return true;
  return (e.lhs && contains_aggregate(*e.lhs)) || (e.rhs && contains_aggregate(*e.rhs));
}

}  // namespace minisql::detail
