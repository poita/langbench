#include "sqlitefile/schema.hpp"

#include "sqlitefile/btree.hpp"
#include "sqlitefile/error.hpp"

namespace sqlitefile {

namespace {
std::string textOf(const Value& v) {
  return v.type() == Type::Text ? v.bytes() : std::string();
}
}  // namespace

Catalog Catalog::load(const Pager& pager) {
  Catalog cat;
  BTreeReader reader(pager);
  reader.scanTable(1, [&](std::int64_t, const Payload& payload) {
    std::vector<Value> r = decodeRecord(payload.bytes(), 5);
    r.resize(5);
    SchemaRow row;
    row.type = textOf(r[0]);
    row.name = textOf(r[1]);
    row.tbl_name = textOf(r[2]);
    row.rootpage = r[3].type() == Type::Integer ? r[3].asInteger() : 0;
    if (r[4].type() == Type::Text) row.sql = r[4].bytes();
    cat.rows_.push_back(std::move(row));
    return true;
  });

  for (const SchemaRow& row : cat.rows_) {
    if (row.rootpage <= 0 || !row.sql) {
      continue;
    }
    try {
      if (row.type == "table") {
        cat.tables_.push_back(
            {row.name, static_cast<std::uint32_t>(row.rootpage), parseCreateTable(*row.sql)});
      } else if (row.type == "index") {
        cat.indexes_.push_back({row.name, row.tbl_name,
                                static_cast<std::uint32_t>(row.rootpage),
                                parseCreateIndex(*row.sql)});
      }
    } catch (const FormatError&) {
      // A statement we cannot understand makes that object unusable but
      // must not break queries against other objects.
    }
  }
  return cat;
}

const TableInfo* Catalog::findTable(std::string_view name) const {
  for (const TableInfo& t : tables_)
    if (equalsIgnoreCase(t.name, name)) return &t;
  return nullptr;
}

const IndexInfo* Catalog::findIndex(std::string_view name) const {
  for (const IndexInfo& i : indexes_)
    if (equalsIgnoreCase(i.name, name)) return &i;
  return nullptr;
}

}  // namespace sqlitefile
