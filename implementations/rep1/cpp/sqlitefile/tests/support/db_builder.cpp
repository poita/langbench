#include "db_builder.hpp"

#include <cstring>
#include <stdexcept>

#include "sqlitefile/btree.hpp"

namespace testsupport {

using sqlitefile::Type;
using sqlitefile::Value;

void appendVarint(Bytes& out, std::int64_t sv) {
  std::uint64_t v = static_cast<std::uint64_t>(sv);
  if (v >> 56) {
    // 9 bytes: eight 7-bit groups then a full byte.
    std::uint8_t tmp[9];
    tmp[8] = static_cast<std::uint8_t>(v & 0xff);
    v >>= 8;
    for (int i = 7; i >= 0; --i) {
      tmp[i] = static_cast<std::uint8_t>((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.insert(out.end(), tmp, tmp + 9);
    return;
  }
  std::uint8_t tmp[9];
  int n = 0;
  do {
    tmp[n++] = static_cast<std::uint8_t>(v & 0x7f);
    v >>= 7;
  } while (v);
  for (int i = n - 1; i >= 0; --i) out.push_back(tmp[i] | (i ? 0x80 : 0));
}

namespace {

void putBE(Bytes& out, std::uint64_t v, int n) {
  for (int i = n - 1; i >= 0; --i) out.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
}

}  // namespace

Bytes encodeRecord(const std::vector<Value>& values) {
  Bytes types, body;
  for (const Value& v : values) {
    switch (v.type()) {
      case Type::Null: appendVarint(types, 0); break;
      case Type::Integer: {
        std::int64_t x = v.asInteger();
        if (x == 0) appendVarint(types, 8);
        else if (x == 1) appendVarint(types, 9);
        else if (x >= -128 && x <= 127) { appendVarint(types, 1); putBE(body, x, 1); }
        else if (x >= -32768 && x <= 32767) { appendVarint(types, 2); putBE(body, x, 2); }
        else if (x >= -(1 << 23) && x < (1 << 23)) { appendVarint(types, 3); putBE(body, x, 3); }
        else if (x >= INT32_MIN && x <= INT32_MAX) { appendVarint(types, 4); putBE(body, x, 4); }
        else if (x >= -(std::int64_t{1} << 47) && x < (std::int64_t{1} << 47)) {
          appendVarint(types, 5); putBE(body, x, 6);
        } else { appendVarint(types, 6); putBE(body, x, 8); }
        break;
      }
      case Type::Real: {
        double d = v.asReal();
        std::uint64_t bits;
        std::memcpy(&bits, &d, 8);
        appendVarint(types, 7);
        putBE(body, bits, 8);
        break;
      }
      case Type::Text:
        appendVarint(types, 13 + 2 * static_cast<std::int64_t>(v.bytes().size()));
        body.insert(body.end(), v.bytes().begin(), v.bytes().end());
        break;
      case Type::Blob:
        appendVarint(types, 12 + 2 * static_cast<std::int64_t>(v.bytes().size()));
        body.insert(body.end(), v.bytes().begin(), v.bytes().end());
        break;
    }
  }
  Bytes header;
  std::size_t hs = types.size() + 1;  // header-size varint is 1 byte for small headers
  if (hs > 127) throw std::runtime_error("record header too large for test builder");
  header.push_back(static_cast<std::uint8_t>(hs));
  header.insert(header.end(), types.begin(), types.end());
  header.insert(header.end(), body.begin(), body.end());
  return header;
}

std::uint32_t DbBuilder::allocate() {
  pages_.emplace_back(page_size_, 0);
  return static_cast<std::uint32_t>(pages_.size() + 1);
}

// Builds the bytes of a cell: `prefix` (child pointer / varints already
// encoded by the caller) + payload size varint (if applicable, included by
// caller in prefix) ... see callers. Here: prefix + local payload + overflow ptr.
Bytes DbBuilder::makeCell(bool table_leaf, const Bytes* prefix, const Bytes& payload) {
  std::uint32_t usable = page_size_;
  auto kind = table_leaf ? sqlitefile::CellKind::TableLeaf : sqlitefile::CellKind::Index;
  std::uint32_t local = sqlitefile::localPayloadSize(payload.size(), usable, kind);
  Bytes cell = *prefix;
  cell.insert(cell.end(), payload.begin(), payload.begin() + local);
  if (local < payload.size()) {
    std::size_t pos = local;
    std::uint32_t first = 0, prev = 0;
    while (pos < payload.size()) {
      std::uint32_t pg = allocate();
      if (!first) first = pg;
      else {
        Bytes& p = pageBytes(prev);
        p[0] = pg >> 24; p[1] = pg >> 16; p[2] = pg >> 8; p[3] = pg;
      }
      std::size_t chunk = std::min<std::size_t>(payload.size() - pos, usable - 4);
      std::memcpy(pageBytes(pg).data() + 4, payload.data() + pos, chunk);
      pos += chunk;
      prev = pg;
    }
    putBE(cell, first, 4);
  }
  return cell;
}

Bytes DbBuilder::layoutPage(std::uint8_t type, const std::vector<Bytes>& cells,
                            std::uint32_t right_child, std::size_t base) {
  Bytes page(page_size_, 0);
  bool interior = type == 0x02 || type == 0x05;
  std::size_t header = interior ? 12 : 8;
  page[base] = type;
  page[base + 3] = static_cast<std::uint8_t>(cells.size() >> 8);
  page[base + 4] = static_cast<std::uint8_t>(cells.size());
  if (interior) {
    page[base + 8] = right_child >> 24; page[base + 9] = right_child >> 16;
    page[base + 10] = right_child >> 8; page[base + 11] = right_child;
  }
  std::size_t end = page_size_;
  // Place cells from the end of the page, in reverse order, to exercise the
  // "cells are in arbitrary order" rule.
  for (std::size_t i = 0; i < cells.size(); ++i) {
    end -= cells[i].size();
    if (end < base + header + 2 * cells.size())
      throw std::runtime_error("cells do not fit on test page");
    std::memcpy(page.data() + end, cells[i].data(), cells[i].size());
    page[base + header + 2 * i] = static_cast<std::uint8_t>(end >> 8);
    page[base + header + 2 * i + 1] = static_cast<std::uint8_t>(end);
  }
  page[base + 5] = static_cast<std::uint8_t>((end % 65536) >> 8);
  page[base + 6] = static_cast<std::uint8_t>(end);
  return page;
}

std::uint32_t DbBuilder::writePage(std::uint8_t type, const std::vector<Bytes>& cells,
                                   std::uint32_t right_child) {
  std::uint32_t n = allocate();
  pageBytes(n) = layoutPage(type, cells, right_child, 0);
  return n;
}

std::uint32_t DbBuilder::addTableTree(const std::vector<Row>& rows, TreeShape shape) {
  struct Node { std::uint32_t page; std::int64_t max_rowid; };
  std::vector<Node> level;
  std::size_t i = 0;
  do {
    std::vector<Bytes> cells;
    std::int64_t last = 0;
    for (std::size_t k = 0; k < shape.leaf_cells && i < rows.size(); ++k, ++i) {
      Bytes payload = encodeRecord(rows[i].values);
      Bytes prefix;
      appendVarint(prefix, static_cast<std::int64_t>(payload.size()));
      appendVarint(prefix, rows[i].rowid);
      cells.push_back(makeCell(true, &prefix, payload));
      last = rows[i].rowid;
    }
    level.push_back({writePage(0x0d, cells, 0), last});
  } while (i < rows.size());

  while (level.size() > 1) {
    std::vector<Node> next;
    std::size_t j = 0;
    while (j < level.size()) {
      std::size_t m = std::min(shape.interior_cells, level.size() - j);
      if (level.size() - j - m == 1) ++m;
      std::vector<Bytes> cells;
      for (std::size_t t = 0; t + 1 < m; ++t) {
        Bytes c;
        putBE(c, level[j + t].page, 4);
        appendVarint(c, level[j + t].max_rowid);
        cells.push_back(c);
      }
      const Node& right = level[j + m - 1];
      next.push_back({writePage(0x05, cells, right.page), right.max_rowid});
      j += m;
    }
    level = std::move(next);
  }
  return level[0].page;
}

std::uint32_t DbBuilder::addIndexTree(const std::vector<std::vector<Value>>& entries,
                                      TreeShape shape) {
  auto leafCell = [&](const std::vector<Value>& e) {
    Bytes payload = encodeRecord(e);
    Bytes prefix;
    appendVarint(prefix, static_cast<std::int64_t>(payload.size()));
    return makeCell(false, &prefix, payload);
  };
  auto interiorCell = [&](std::uint32_t child, const std::vector<Value>& e) {
    Bytes payload = encodeRecord(e);
    Bytes prefix;
    putBE(prefix, child, 4);
    appendVarint(prefix, static_cast<std::int64_t>(payload.size()));
    return makeCell(false, &prefix, payload);
  };

  std::vector<std::uint32_t> nodes;
  std::vector<std::vector<Value>> seps;
  std::size_t i = 0;
  while (true) {
    std::vector<Bytes> cells;
    for (std::size_t k = 0; k < shape.leaf_cells && i < entries.size(); ++k, ++i)
      cells.push_back(leafCell(entries[i]));
    if (entries.size() - i == 1) cells.push_back(leafCell(entries[i++]));
    nodes.push_back(writePage(0x0a, cells, 0));
    if (i >= entries.size()) break;
    seps.push_back(entries[i++]);
  }

  while (nodes.size() > 1) {
    std::vector<std::uint32_t> next_nodes;
    std::vector<std::vector<Value>> next_seps;
    std::size_t j = 0;
    while (j < nodes.size()) {
      std::size_t m = std::min(shape.interior_cells, nodes.size() - j);
      if (nodes.size() - j - m == 1) ++m;
      std::vector<Bytes> cells;
      for (std::size_t t = 0; t + 1 < m; ++t) cells.push_back(interiorCell(nodes[j + t], seps[j + t]));
      next_nodes.push_back(writePage(0x02, cells, nodes[j + m - 1]));
      if (j + m < nodes.size()) next_seps.push_back(seps[j + m - 1]);
      j += m;
    }
    nodes = std::move(next_nodes);
    seps = std::move(next_seps);
  }
  return nodes[0];
}

void DbBuilder::addSchemaRow(const std::string& type, const std::string& name,
                             const std::string& tbl_name, std::int64_t rootpage,
                             const std::optional<std::string>& sql) {
  schema_.push_back({type, name, tbl_name, rootpage, sql});
}

std::uint32_t DbBuilder::addTable(const std::string& name, const std::string& sql,
                                  const std::vector<Row>& rows, TreeShape shape) {
  std::uint32_t root = addTableTree(rows, shape);
  addSchemaRow("table", name, name, root, sql);
  return root;
}

std::uint32_t DbBuilder::addIndex(const std::string& name, const std::string& table,
                                  const std::string& sql,
                                  const std::vector<std::vector<Value>>& entries, TreeShape shape) {
  std::uint32_t root = addIndexTree(entries, shape);
  addSchemaRow("index", name, table, root, sql);
  return root;
}

Bytes DbBuilder::build() {
  std::vector<Bytes> cells;
  std::int64_t rowid = 1;
  for (const SchemaRow& r : schema_) {
    std::vector<Value> rec = {
        Value::text(r.type), Value::text(r.name), Value::text(r.tbl), Value::integer(r.root),
        r.sql ? Value::text(*r.sql) : Value::null()};
    Bytes payload = encodeRecord(rec);
    Bytes prefix;
    appendVarint(prefix, static_cast<std::int64_t>(payload.size()));
    appendVarint(prefix, rowid++);
    cells.push_back(makeCell(true, &prefix, payload));
  }
  Bytes page1 = layoutPage(0x0d, cells, 0, 100);
  static const char magic[] = "SQLite format 3";
  std::memcpy(page1.data(), magic, 16);  // includes the NUL
  std::uint32_t ps = page_size_ == 65536 ? 1 : page_size_;
  page1[16] = ps >> 8; page1[17] = ps;
  page1[18] = 1; page1[19] = 1;
  std::uint32_t total = static_cast<std::uint32_t>(pages_.size() + 1);
  page1[28] = total >> 24; page1[29] = total >> 16; page1[30] = total >> 8; page1[31] = total;
  page1[59] = 1;  // text encoding: UTF-8
  Bytes out = page1;
  for (const Bytes& p : pages_) out.insert(out.end(), p.begin(), p.end());
  return out;
}

}  // namespace testsupport
