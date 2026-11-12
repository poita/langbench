#include "sqlitefile/database.hpp"

#include <algorithm>

#include "sqlitefile/btree.hpp"
#include "sqlitefile/error.hpp"

namespace sqlitefile {

namespace {

/// A column named in a query, resolved against a table.
struct ColumnRef {
  bool is_rowid = false;  ///< the rowid (also used for an INTEGER PRIMARY KEY alias)
  std::size_t index = 0;  ///< position in the record otherwise
  Affinity affinity = Affinity::Integer;
};

ColumnRef resolveColumn(const TableInfo& table, const std::string& name) {
  if (auto idx = table.def.findColumn(name)) {
    if (table.def.rowid_alias == idx) return {true, 0, Affinity::Integer};
    return {false, *idx, table.def.columns[*idx].affinity};
  }
  if (equalsIgnoreCase(name, "rowid")) return {true, 0, Affinity::Integer};
  throw QueryError("no such column: " + name);
}

/// Turns a decoded record into the table's logical row: pads short records
/// with NULL, substitutes the rowid for the alias column and widens integers
/// in REAL-affinity columns.
void normalizeRecord(const TableDef& def, std::int64_t rowid, std::vector<Value>& rec) {
  rec.resize(def.columns.size());
  if (def.rowid_alias) rec[*def.rowid_alias] = Value::integer(rowid);
  for (std::size_t i = 0; i < rec.size(); ++i) {
    if (def.columns[i].affinity == Affinity::Real && rec[i].type() == Type::Integer)
      rec[i] = Value::real(static_cast<double>(rec[i].asInteger()));
  }
}

const Value& fieldOf(const ColumnRef& ref, std::int64_t rowid, const std::vector<Value>& rec,
                     Value& scratch) {
  if (ref.is_rowid) {
    scratch = Value::integer(rowid);
    return scratch;
  }
  return rec[ref.index];
}

bool matches(const Value& v, CompareOp op, const Value& lit) {
  switch (op) {
    case CompareOp::Is: return compare(v, lit) == 0;
    case CompareOp::IsNot: return compare(v, lit) != 0;
    default: break;
  }
  if (v.isNull() || lit.isNull()) return false;
  int c = compare(v, lit);
  switch (op) {
    case CompareOp::Eq: return c == 0;
    case CompareOp::Ne: return c != 0;
    case CompareOp::Lt: return c < 0;
    case CompareOp::Le: return c <= 0;
    case CompareOp::Gt: return c > 0;
    case CompareOp::Ge: return c >= 0;
    default: return false;
  }
}

void appendRow(std::string& out, const std::vector<Value>& fields) {
  for (std::size_t i = 0; i < fields.size(); ++i) {
    if (i) out.push_back('\t');
    appendFormatted(out, fields[i]);
  }
  out.push_back('\n');
}

const TableInfo& requireTable(const Catalog& cat, const std::string& name) {
  const TableInfo* t = cat.findTable(name);
  if (!t) throw QueryError("no such table: " + name);
  return *t;
}

}  // namespace

Database::Database(Pager pager) : pager_(std::move(pager)), catalog_(Catalog::load(pager_)) {}

Database Database::open(const std::filesystem::path& path) { return Database(Pager::open(path)); }

Database Database::fromBytes(std::vector<std::uint8_t> bytes) {
  return Database(Pager::fromBytes(std::move(bytes)));
}

std::string Database::run(std::string_view line) const { return execute(parseQuery(line)); }

std::string Database::execute(const Query& query) const {
  struct Visitor {
    const Database& db;
    std::string operator()(const TablesQuery&) const { return db.tables(); }
    std::string operator()(const SchemaQuery& q) const { return db.schema(q); }
    std::string operator()(const CountQuery& q) const { return db.count(q); }
    std::string operator()(const SelectQuery& q) const { return db.select(q); }
    std::string operator()(const IndexQuery& q) const { return db.indexLookup(q); }
  };
  return std::visit(Visitor{*this}, query);
}

std::string Database::tables() const {
  std::vector<std::string> names;
  for (const SchemaRow& r : catalog_.rows()) {
    if (r.type != "table") continue;
    if (r.name.size() >= 7 && equalsIgnoreCase(std::string_view(r.name).substr(0, 7), "sqlite_"))
      continue;
    names.push_back(r.name);
  }
  std::sort(names.begin(), names.end());  // std::string compares as unsigned bytes
  std::string out;
  for (const std::string& n : names) out += n + "\n";
  return out;
}

std::string Database::schema(const SchemaQuery& q) const {
  std::string out;
  for (const SchemaRow& r : catalog_.rows()) {
    if (!r.sql || !equalsIgnoreCase(r.tbl_name, q.table)) continue;
    out += *r.sql;
    out += ";\n";
  }
  return out;
}

std::string Database::count(const CountQuery& q) const {
  const TableInfo& table = requireTable(catalog_, q.table);
  BTreeReader reader(pager_);
  return std::to_string(reader.countTableRows(table.root_page)) + "\n";
}

std::string Database::select(const SelectQuery& q) const {
  const TableInfo& table = requireTable(catalog_, q.table);
  const TableDef& def = table.def;

  std::vector<ColumnRef> out_cols;
  if (q.all_columns) {
    for (std::size_t i = 0; i < def.columns.size(); ++i)
      out_cols.push_back(resolveColumn(table, def.columns[i].name));
    // Duplicate column names would resolve to the first; address by position.
    for (std::size_t i = 0; i < out_cols.size(); ++i)
      out_cols[i] = def.rowid_alias == i ? ColumnRef{true, 0, Affinity::Integer}
                                         : ColumnRef{false, i, def.columns[i].affinity};
  } else {
    for (const std::string& name : q.columns) out_cols.push_back(resolveColumn(table, name));
  }

  struct BoundCondition {
    ColumnRef col;
    CompareOp op;
    Value literal;
  };
  std::vector<BoundCondition> conds;
  for (const Condition& c : q.where) {
    ColumnRef ref = resolveColumn(table, c.column);
    conds.push_back({ref, c.op, applyAffinityToLiteral(c.literal, ref.affinity)});
  }
  std::optional<ColumnRef> order_col;
  if (q.order_by) order_col = resolveColumn(table, q.order_by->column);

  // Decode only as many record columns as the query touches.
  std::size_t needed = 0;
  auto need = [&](const ColumnRef& r) {
    if (!r.is_rowid) needed = std::max(needed, r.index + 1);
  };
  for (const ColumnRef& r : out_cols) need(r);
  for (const BoundCondition& c : conds) need(c.col);
  if (order_col) need(*order_col);

  std::string out;
  struct SortedRow {
    Value key;
    std::string line;
  };
  std::vector<SortedRow> sorted;
  std::uint64_t emitted = 0;
  const bool ordered = q.order_by.has_value();
  const std::int64_t limit = q.limit.value_or(-1);
  if (limit == 0) return out;

  BTreeReader reader(pager_);
  reader.scanTable(table.root_page, [&](std::int64_t rowid, const Payload& payload) {
    std::vector<Value> rec = decodeRecord(payload.bytes(), needed);
    normalizeRecord(def, rowid, rec);
    Value scratch;
    for (const BoundCondition& c : conds)
      if (!matches(fieldOf(c.col, rowid, rec, scratch), c.op, c.literal)) return true;

    std::string line;
    for (std::size_t i = 0; i < out_cols.size(); ++i) {
      if (i) line.push_back('\t');
      appendFormatted(line, fieldOf(out_cols[i], rowid, rec, scratch));
    }
    line.push_back('\n');
    if (ordered) {
      sorted.push_back({fieldOf(*order_col, rowid, rec, scratch), std::move(line)});
      return true;
    }
    out += line;
    ++emitted;
    return limit < 0 || static_cast<std::int64_t>(emitted) < limit;
  });

  if (ordered) {
    bool desc = q.order_by->descending;
    // The scan is in rowid order and the sort is stable, so ties keep
    // ascending rowid order in both directions.
    std::stable_sort(sorted.begin(), sorted.end(), [desc](const SortedRow& a, const SortedRow& b) {
      int c = compare(a.key, b.key);
      return desc ? c > 0 : c < 0;
    });
    std::size_t n = sorted.size();
    if (limit >= 0 && static_cast<std::uint64_t>(limit) < n) n = static_cast<std::size_t>(limit);
    for (std::size_t i = 0; i < n; ++i) out += sorted[i].line;
  }
  return out;
}

std::string Database::indexLookup(const IndexQuery& q) const {
  const IndexInfo* index = catalog_.findIndex(q.index);
  if (!index) throw QueryError("no such index: " + q.index);
  if (index->def.columns.size() != 1) throw QueryError("index must have exactly one column");
  const TableInfo& table = requireTable(catalog_, index->table);
  auto col = table.def.findColumn(index->def.columns[0]);
  if (!col) throw QueryError("index column not found in table");

  Value key = applyAffinityToLiteral(q.key, table.def.columns[*col].affinity);
  std::string out;
  if (key.isNull()) return out;

  BTreeReader reader(pager_);
  std::vector<std::int64_t> rowids;
  reader.scanIndexEqual(index->root_page, key, index->def.descending[0],
                        [&](const std::vector<Value>& entry) {
                          if (entry.back().type() != Type::Integer)
                            throw FormatError("index entry without rowid");
                          rowids.push_back(entry.back().asInteger());
                        });
  std::sort(rowids.begin(), rowids.end());
  rowids.erase(std::unique(rowids.begin(), rowids.end()), rowids.end());

  for (std::int64_t rowid : rowids) {
    auto payload = reader.findTableRow(table.root_page, rowid);
    if (!payload) continue;
    std::vector<Value> rec = decodeRecord(payload->bytes());
    normalizeRecord(table.def, rowid, rec);
    appendRow(out, rec);
  }
  return out;
}

}  // namespace sqlitefile
