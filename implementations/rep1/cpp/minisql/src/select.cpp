// SELECT: binding, join planning, grouping, ordering.
#include <algorithm>
#include <cstdint>
#include <numeric>
#include <unordered_map>

#include "internal.hpp"

namespace minisql::detail {

namespace {

/// One row of the FROM clause product (second pointer unused for one table).
struct Candidate {
  const Row* rows[2] = {nullptr, nullptr};
};

EvalContext context_for(const Candidate& c, const Value* aggregates = nullptr) {
  EvalContext ctx;
  ctx.rows[0] = c.rows[0];
  ctx.rows[1] = c.rows[1];
  ctx.aggregates = aggregates;
  return ctx;
}

// ---- keys for hashing -------------------------------------------------------

void append_key(std::string& key, const Value& v) {
  auto put64 = [&](std::uint64_t x) {
    for (int i = 0; i < 8; ++i) key += static_cast<char>((x >> (8 * i)) & 0xFF);
  };
  switch (v.kind()) {
    case Value::Kind::Null: key += 'N'; break;
    case Value::Kind::Integer: key += 'I'; put64(static_cast<std::uint64_t>(v.as_integer())); break;
    case Value::Kind::Real: key += 'R'; put64(static_cast<std::uint64_t>(v.as_hundredths())); break;
    case Value::Kind::Text:
      key += 'T';
      put64(v.as_text().size());
      key += v.as_text();
      break;
  }
}

// ---- conjunct analysis --------------------------------------------------------

void split_conjuncts(const Expr* e, std::vector<const Expr*>& out) {
  if (e == nullptr) return;
  if (e->kind == ExprKind::Binary && e->binary_op == BinaryOp::And) {
    split_conjuncts(e->lhs.get(), out);
    split_conjuncts(e->rhs.get(), out);
  } else {
    out.push_back(e);
  }
}

/// Bit i set iff the expression reads a column of FROM table i.
unsigned table_mask(const Expr& e) {
  unsigned m = 0;
  if (e.kind == ExprKind::Column) m |= 1u << e.table;
  if (e.lhs) m |= table_mask(*e.lhs);
  if (e.rhs) m |= table_mask(*e.rhs);
  return m;
}

bool all_true(const std::vector<const Expr*>& conjuncts, const EvalContext& ctx) {
  for (const Expr* c : conjuncts) {
    if (!is_true(evaluate(*c, ctx))) return false;
  }
  return true;
}

// ---- FROM / WHERE / ON: candidate rows ---------------------------------------

struct Equality {
  const Expr* side[2];  // side[t] only reads FROM table t
};

std::vector<Candidate> produce_candidates(const Scope& scope,
                                          const std::vector<const Expr*>& conjuncts) {
  static const Row kEmptyRow;
  std::vector<Candidate> out;

  // Classify conjuncts: single-table filters are pushed below the join.
  std::vector<const Expr*> filters[2], residual;
  std::vector<Equality> equalities;
  for (const Expr* c : conjuncts) {
    const unsigned mask = table_mask(*c);
    if (scope.size() < 2 || mask <= 1) {
      filters[0].push_back(c);
    } else if (mask == 2) {
      filters[1].push_back(c);
    } else if (c->kind == ExprKind::Binary && c->binary_op == BinaryOp::Eq) {
      const unsigned ml = table_mask(*c->lhs), mr = table_mask(*c->rhs);
      if (ml == 1 && mr == 2) equalities.push_back({{c->lhs.get(), c->rhs.get()}});
      else if (ml == 2 && mr == 1) equalities.push_back({{c->rhs.get(), c->lhs.get()}});
      else residual.push_back(c);
    } else {
      residual.push_back(c);
    }
  }

  // Filtered row pointers per source.
  std::vector<const Row*> filtered[2];
  const std::size_t nsources = std::max<std::size_t>(scope.size(), 1);
  for (std::size_t t = 0; t < nsources; ++t) {
    auto consider = [&](const Row* row) {
      EvalContext ctx;
      ctx.rows[t] = row;
      if (all_true(filters[t], ctx)) filtered[t].push_back(row);
    };
    if (scope.empty()) {
      consider(&kEmptyRow);
    } else {
      for (const Row& row : scope[t].table->rows) consider(&row);
    }
  }

  if (scope.size() < 2) {
    out.reserve(filtered[0].size());
    for (const Row* r : filtered[0]) out.push_back({{r, nullptr}});
    return out;
  }

  auto emit_if_residual = [&](const Row* a, const Row* b) {
    Candidate c{{a, b}};
    if (residual.empty() || all_true(residual, context_for(c))) out.push_back(c);
  };

  if (equalities.empty()) {
    for (const Row* a : filtered[0]) {
      for (const Row* b : filtered[1]) emit_if_residual(a, b);
    }
    return out;
  }

  // Hash join on all cross-table equalities as one composite key. NULL keys
  // never match. Bucket order is the inner table's order, so pairs come out
  // in nested-loop order.
  auto make_key = [&](std::size_t t, const Row* row, std::string& key) {
    key.clear();
    EvalContext ctx;
    ctx.rows[t] = row;
    for (const Equality& eq : equalities) {
      const Value v = evaluate(*eq.side[t], ctx);
      if (v.is_null()) return false;
      append_key(key, v);
    }
    return true;
  };
  std::unordered_map<std::string, std::vector<const Row*>> buckets;
  buckets.reserve(filtered[1].size());
  std::string key;
  for (const Row* b : filtered[1]) {
    if (make_key(1, b, key)) buckets[key].push_back(b);
  }
  for (const Row* a : filtered[0]) {
    if (!make_key(0, a, key)) continue;
    auto it = buckets.find(key);
    if (it == buckets.end()) continue;
    for (const Row* b : it->second) emit_if_residual(a, b);
  }
  return out;
}

// ---- aggregation ----------------------------------------------------------------

Value compute_aggregate(const Expr& agg, const std::vector<Candidate>& rows,
                        const std::vector<std::size_t>& members) {
  if (agg.func == AggFunc::Count && agg.star) {
    return Value::integer(static_cast<std::int64_t>(members.size()));
  }
  std::int64_t count = 0;
  std::uint64_t sum = 0;
  Value best;  // MIN / MAX
  for (std::size_t idx : members) {
    const Value v = evaluate(*agg.lhs, context_for(rows[idx]));
    if (v.is_null()) continue;
    ++count;
    switch (agg.func) {
      case AggFunc::Sum:
      case AggFunc::Avg:
        if (v.is_integer()) sum += static_cast<std::uint64_t>(v.as_integer());
        break;
      case AggFunc::Min:
        if (count == 1 || compare(v, best) < 0) best = v;
        break;
      case AggFunc::Max:
        if (count == 1 || compare(v, best) > 0) best = v;
        break;
      case AggFunc::Count:
        break;
    }
  }
  switch (agg.func) {
    case AggFunc::Count:
      return Value::integer(count);
    case AggFunc::Sum:
      return count == 0 ? Value::null() : Value::integer(static_cast<std::int64_t>(sum));
    case AggFunc::Min:
    case AggFunc::Max:
      return count == 0 ? Value::null() : best;
    case AggFunc::Avg: {
      if (count == 0) return Value::null();
      const auto s = static_cast<std::int64_t>(sum);
      const std::int64_t mag = s < 0 ? -s : s;
      std::int64_t h = (200 * mag + count) / (2 * count);
      if (s < 0) h = -h;
      return Value::real_from_hundredths(h);
    }
  }
  return Value::null();
}

struct Group {
  std::vector<std::size_t> members;  // candidate indices, in step-3 order
  Row key;                           // grouping values
};

// ---- ORDER BY ---------------------------------------------------------------------

struct SortTerm {
  bool by_output = false;
  std::size_t output_index = 0;
  const Expr* expr = nullptr;
  bool descending = false;
};

}  // namespace

ExecResult execute_select(const Catalog& catalog, SelectStmt& st) {
  // ---- FROM ----
  Scope scope;
  for (const TableRef& ref : st.from) {
    auto it = catalog.find(ref.name);
    if (it == catalog.end()) semantic_error("no such table: " + ref.name);
    for (const Source& s : scope) {
      if (s.name == ref.effective_name()) semantic_error("duplicate table name: " + s.name);
    }
    scope.push_back({ref.effective_name(), &it->second});
  }

  // ---- select list (expanding '*') ----
  struct OutItem {
    const Expr* expr;
    const std::string* alias;
  };
  std::vector<ExprPtr> generated;  // owns expressions made for '*'
  std::vector<OutItem> items;
  static const std::string kNoAlias;
  for (SelectItem& item : st.items) {
    if (!item.star) {
      items.push_back({item.expr.get(), &item.alias});
      continue;
    }
    if (scope.empty()) semantic_error("'*' without FROM");
    for (std::size_t s = 0; s < scope.size(); ++s) {
      for (std::size_t c = 0; c < scope[s].table->columns.size(); ++c) {
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::Column;
        e->name = scope[s].table->columns[c];
        e->table = static_cast<int>(s);
        e->column = static_cast<int>(c);
        items.push_back({e.get(), &kNoAlias});
        generated.push_back(std::move(e));
      }
    }
  }

  // ---- ORDER BY term classification ----
  std::vector<SortTerm> terms;
  for (OrderTerm& ot : st.order_by) {
    SortTerm term;
    term.descending = ot.descending;
    bool resolved = false;
    if (!ot.bare_identifier.empty()) {
      for (std::size_t i = 0; i < items.size(); ++i) {
        if (*items[i].alias == ot.bare_identifier) {
          term.by_output = true;
          term.output_index = i;
          resolved = true;
          break;
        }
      }
    } else if (ot.ordinal) {
      if (*ot.ordinal < 1 || *ot.ordinal > static_cast<std::int64_t>(items.size())) {
        semantic_error("ORDER BY ordinal out of range");
      }
      term.by_output = true;
      term.output_index = static_cast<std::size_t>(*ot.ordinal - 1);
      resolved = true;
    }
    if (!resolved) term.expr = ot.expr.get();
    terms.push_back(term);
  }

  // ---- is it an aggregate query? ----
  bool aggregate_query = !st.group_by.empty();
  for (const OutItem& it : items) aggregate_query |= contains_aggregate(*it.expr);
  if (st.having) aggregate_query |= contains_aggregate(*st.having);
  for (const SortTerm& t : terms) {
    if (t.expr) aggregate_query |= contains_aggregate(*t.expr);
  }

  // ---- bind ----
  std::vector<const Expr*> conjuncts;
  {
    BindOptions plain;  // WHERE / ON: no aggregates
    if (st.join_on) bind_expr(*st.join_on, scope, plain);
    if (st.where) bind_expr(*st.where, scope, plain);
    split_conjuncts(st.join_on.get(), conjuncts);
    split_conjuncts(st.where.get(), conjuncts);
  }

  std::vector<ColumnSlot> group_columns;
  for (ExprPtr& g : st.group_by) {
    bind_expr(*g, scope, BindOptions{});
    group_columns.push_back({g->table, g->column});
  }

  std::vector<const Expr*> aggregates;
  BindOptions bound;
  bound.allow_aggregates = aggregate_query;
  bound.grouped = aggregate_query;
  bound.group_columns = &group_columns;
  bound.aggregates = &aggregates;
  for (SelectItem& item : st.items) {
    if (!item.star) bind_expr(*item.expr, scope, bound);
  }
  if (st.having) bind_expr(*st.having, scope, bound);
  for (SortTerm& t : terms) {
    if (t.expr) bind_expr(*const_cast<Expr*>(t.expr), scope, bound);
  }
  // Generated '*' columns are plain column references; in an aggregate query
  // they must be grouping columns too.
  if (aggregate_query) {
    for (const ExprPtr& g : generated) {
      if (std::find(group_columns.begin(), group_columns.end(),
                    ColumnSlot{g->table, g->column}) == group_columns.end()) {
        semantic_error("column is not grouped: " + g->name);
      }
    }
  }

  // ---- FROM / WHERE ----
  std::vector<Candidate> candidates = produce_candidates(scope, conjuncts);

  // ---- aggregation, HAVING, select list ----
  std::vector<Row> out_rows;
  std::vector<Row> out_keys;  // ORDER BY keys per output row
  auto emit = [&](const EvalContext& ctx) {
    Row row;
    row.reserve(items.size());
    for (const OutItem& it : items) row.push_back(evaluate(*it.expr, ctx));
    if (!terms.empty()) {
      Row keys;
      keys.reserve(terms.size());
      for (const SortTerm& t : terms) {
        keys.push_back(t.by_output ? row[t.output_index] : evaluate(*t.expr, ctx));
      }
      out_keys.push_back(std::move(keys));
    }
    out_rows.push_back(std::move(row));
  };

  if (!aggregate_query) {
    out_rows.reserve(candidates.size());
    for (const Candidate& c : candidates) emit(context_for(c));
  } else {
    std::vector<Group> groups;
    if (group_columns.empty()) {
      groups.emplace_back();
      groups[0].members.resize(candidates.size());
      std::iota(groups[0].members.begin(), groups[0].members.end(), std::size_t{0});
    } else {
      std::unordered_map<std::string, std::size_t> index;
      std::string key;
      for (std::size_t i = 0; i < candidates.size(); ++i) {
        key.clear();
        Row values;
        values.reserve(group_columns.size());
        for (const ColumnSlot& g : group_columns) {
          const Value& v = (*candidates[i].rows[g.first])[static_cast<std::size_t>(g.second)];
          append_key(key, v);
          values.push_back(v);
        }
        auto [it, inserted] = index.try_emplace(key, groups.size());
        if (inserted) {
          groups.emplace_back();
          groups.back().key = std::move(values);
        }
        groups[it->second].members.push_back(i);
      }
      std::sort(groups.begin(), groups.end(), [](const Group& a, const Group& b) {
        for (std::size_t i = 0; i < a.key.size(); ++i) {
          const int c = compare(a.key[i], b.key[i]);
          if (c != 0) return c < 0;
        }
        return false;
      });
    }
    std::vector<Value> agg_values(aggregates.size());
    for (const Group& g : groups) {
      for (std::size_t i = 0; i < aggregates.size(); ++i) {
        agg_values[i] = compute_aggregate(*aggregates[i], candidates, g.members);
      }
      // Representative row for grouping columns (never read without GROUP BY).
      const Candidate rep = g.members.empty() ? Candidate{} : candidates[g.members.front()];
      const EvalContext ctx = context_for(rep, agg_values.data());
      if (st.having && !is_true(evaluate(*st.having, ctx))) continue;
      emit(ctx);
    }
  }

  // ---- ORDER BY: one stable sort of all rows ----
  std::vector<std::size_t> order(out_rows.size());
  std::iota(order.begin(), order.end(), std::size_t{0});
  if (!terms.empty()) {
    std::stable_sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
      for (std::size_t i = 0; i < terms.size(); ++i) {
        int c = compare(out_keys[a][i], out_keys[b][i]);
        if (c == 0) continue;
        return terms[i].descending ? c > 0 : c < 0;
      }
      return false;
    });
  }

  // ---- LIMIT / OFFSET ----
  ExecResult result;
  std::size_t skip = st.offset ? static_cast<std::size_t>(*st.offset) : 0;
  std::size_t take = st.limit ? static_cast<std::size_t>(*st.limit) : order.size();
  for (std::size_t i = skip; i < order.size() && take > 0; ++i, --take) {
    result.rows.push_back(std::move(out_rows[order[i]]));
  }
  return result;
}

}  // namespace minisql::detail
