#include <gtest/gtest.h>

#include "db_builder.hpp"
#include "sqlitefile/btree.hpp"
#include "sqlitefile/error.hpp"
#include "sqlitefile/pager.hpp"

using namespace sqlitefile;
using testsupport::DbBuilder;
using testsupport::Row;
using testsupport::TreeShape;

namespace {

std::vector<Row> numberedRows(int n, std::int64_t first = 1) {
  std::vector<Row> rows;
  for (int i = 0; i < n; ++i)
    rows.push_back({first + i, {Value::integer(i), Value::text("row" + std::to_string(i))}});
  return rows;
}

std::vector<std::int64_t> scanRowids(const BTreeReader& r, std::uint32_t root) {
  std::vector<std::int64_t> out;
  r.scanTable(root, [&](std::int64_t id, const Payload&) { out.push_back(id); return true; });
  return out;
}

}  // namespace

TEST(LocalPayload, ThresholdsForU4096) {
  // M = 489, table-leaf X = 4061, index X = 1002.
  EXPECT_EQ(localPayloadSize(4061, 4096, CellKind::TableLeaf), 4061u);
  // One byte past X: K = 489 + (4062-489) % 4092 = 4062 > X, so M.
  EXPECT_EQ(localPayloadSize(4062, 4096, CellKind::TableLeaf), 489u);
  EXPECT_EQ(localPayloadSize(1002, 4096, CellKind::Index), 1002u);
  // K = 489 + (1003-489) % 4092 = 1003 > X, so M.
  EXPECT_EQ(localPayloadSize(1003, 4096, CellKind::Index), 489u);
}

TEST(LocalPayload, KBelowXIsKept) {
  // U=512: M=((500*32)/255)-23=39, index X=((500*64)/255)-23=102.
  // P=200: K = 39 + (161 % 508) = 200 > 102 -> M.
  EXPECT_EQ(localPayloadSize(200, 512, CellKind::Index), 39u);
  // P = 39 + 508 + 10 = 557: K = 39 + 10 = 49 <= X -> 49.
  EXPECT_EQ(localPayloadSize(557, 512, CellKind::Index), 49u);
}

TEST(TableTree, ScansInRowidOrderAcrossLevels) {
  DbBuilder b(512);
  auto root = b.addTableTree(numberedRows(100), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  auto ids = scanRowids(r, root);
  ASSERT_EQ(ids.size(), 100u);
  for (int i = 0; i < 100; ++i) EXPECT_EQ(ids[i], i + 1);
  EXPECT_EQ(r.countTableRows(root), 100u);
}

TEST(TableTree, EarlyStop) {
  DbBuilder b(512);
  auto root = b.addTableTree(numberedRows(50), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  int seen = 0;
  r.scanTable(root, [&](std::int64_t, const Payload&) { return ++seen < 7; });
  EXPECT_EQ(seen, 7);
}

TEST(TableTree, EmptyTable) {
  DbBuilder b;
  auto root = b.addTableTree({});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  EXPECT_EQ(r.countTableRows(root), 0u);
  EXPECT_TRUE(scanRowids(r, root).empty());
}

TEST(TableTree, NegativeAndExtremeRowids) {
  std::vector<Row> rows;
  for (std::int64_t id : std::initializer_list<std::int64_t>{INT64_MIN, -1000000, -1, 0, 1, 127, 128, INT64_MAX})
    rows.push_back({id, {Value::integer(1)}});
  DbBuilder b(512);
  auto root = b.addTableTree(rows, TreeShape{2, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  auto ids = scanRowids(r, root);
  ASSERT_EQ(ids.size(), rows.size());
  for (std::size_t i = 0; i < rows.size(); ++i) EXPECT_EQ(ids[i], rows[i].rowid);
  for (const Row& row : rows) EXPECT_TRUE(r.findTableRow(root, row.rowid).has_value());
}

TEST(TableTree, FindByRowid) {
  DbBuilder b(512);
  auto root = b.addTableTree(numberedRows(60, 10), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  for (int id = 10; id < 70; ++id) {
    auto p = r.findTableRow(root, id);
    ASSERT_TRUE(p.has_value()) << id;
    EXPECT_EQ(decodeRecord(p->bytes())[0], Value::integer(id - 10));
  }
  EXPECT_FALSE(r.findTableRow(root, 9).has_value());
  EXPECT_FALSE(r.findTableRow(root, 70).has_value());
  EXPECT_FALSE(r.findTableRow(root, INT64_MAX).has_value());
}

TEST(Overflow, PayloadsAroundTheThresholdsRoundTrip) {
  // U=512: table-leaf X = 477. Sweep sizes across the local/overflow boundary
  // and over multiple overflow pages.
  DbBuilder b(512);
  std::vector<Row> rows;
  std::vector<std::size_t> sizes = {1, 460, 470, 471, 472, 473, 474, 500, 507, 508, 509,
                                    1000, 1300, 3000};
  std::int64_t id = 1;
  for (std::size_t n : sizes) {
    std::string blob(n, '\0');
    for (std::size_t i = 0; i < n; ++i) blob[i] = static_cast<char>((i * 31 + n) & 0xff);
    rows.push_back({id++, {Value::blob(blob)}});
  }
  auto root = b.addTableTree(rows, TreeShape{1, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  std::size_t k = 0;
  r.scanTable(root, [&](std::int64_t, const Payload& p) {
    auto v = decodeRecord(p.bytes());
    EXPECT_EQ(v[0], rows[k].values[0]) << "size " << sizes[k];
    ++k;
    return true;
  });
  EXPECT_EQ(k, sizes.size());
}

TEST(Overflow, BrokenChainThrows) {
  DbBuilder b(512);
  std::vector<Row> rows = {{1, {Value::blob(std::string(2000, 'x'))}}};
  auto root = b.addTableTree(rows);
  auto bytes = b.build();
  // Zero every overflow page's "next" pointer (pages 2..): the chain ends early.
  for (std::size_t pg = 1; pg + 1 < bytes.size() / 512; ++pg)
    for (int i = 0; i < 4; ++i) bytes[pg * 512 + i] = 0;
  auto pager = Pager::fromBytes(bytes);
  BTreeReader r(pager);
  EXPECT_THROW(r.scanTable(root, [](std::int64_t, const Payload&) { return true; }), FormatError);
}

namespace {

std::vector<std::vector<Value>> indexEntries(const std::vector<int>& keys) {
  std::vector<std::vector<Value>> e;
  std::int64_t rowid = 1;
  for (int k : keys) e.push_back({Value::integer(k), Value::integer(rowid++)});
  return e;
}

std::vector<std::int64_t> lookup(const BTreeReader& r, std::uint32_t root, int key,
                                 bool desc = false) {
  std::vector<std::int64_t> out;
  r.scanIndexEqual(root, Value::integer(key), desc,
                   [&](const std::vector<Value>& e) { out.push_back(e.back().asInteger()); });
  return out;
}

}  // namespace

TEST(IndexTree, FindsEntriesIncludingInteriorCells) {
  std::vector<int> keys;
  for (int i = 0; i < 200; ++i) keys.push_back(i / 2);  // each key twice
  DbBuilder b(512);
  auto root = b.addIndexTree(indexEntries(keys), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  for (int k = 0; k < 100; ++k) {
    auto ids = lookup(r, root, k);
    ASSERT_EQ(ids.size(), 2u) << k;
    EXPECT_EQ(ids[0], 2 * k + 1);
    EXPECT_EQ(ids[1], 2 * k + 2);
  }
  EXPECT_TRUE(lookup(r, root, -1).empty());
  EXPECT_TRUE(lookup(r, root, 100).empty());
}

TEST(IndexTree, OneKeyRunSpansWholeSubtrees) {
  std::vector<int> keys(300, 7);
  keys.insert(keys.begin(), 3);
  keys.push_back(9);
  DbBuilder b(512);
  auto root = b.addIndexTree(indexEntries(keys), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  auto ids = lookup(r, root, 7);
  ASSERT_EQ(ids.size(), 300u);
  for (std::size_t i = 0; i < ids.size(); ++i) EXPECT_EQ(ids[i], static_cast<std::int64_t>(i) + 2);
  EXPECT_EQ(lookup(r, root, 3).size(), 1u);
  EXPECT_EQ(lookup(r, root, 9).size(), 1u);
}

TEST(IndexTree, DescendingKeyOrder) {
  std::vector<int> keys;
  for (int i = 50; i > 0; --i) keys.push_back(i);
  DbBuilder b(512);
  auto root = b.addIndexTree(indexEntries(keys), TreeShape{3, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  for (int k = 1; k <= 50; ++k) {
    auto ids = lookup(r, root, k, /*desc=*/true);
    ASSERT_EQ(ids.size(), 1u) << k;
    EXPECT_EQ(ids[0], 51 - k);
  }
}

TEST(IndexTree, OverflowingKeys) {
  std::vector<std::vector<Value>> entries;
  for (int i = 0; i < 6; ++i) {
    std::string key(600 + i, static_cast<char>('a' + i));  // > index X for U=512
    entries.push_back({Value::text(key), Value::integer(i + 1)});
  }
  DbBuilder b(512);
  auto root = b.addIndexTree(entries, TreeShape{1, 2});
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  for (int i = 0; i < 6; ++i) {
    std::vector<std::int64_t> ids;
    r.scanIndexEqual(root, entries[i][0], false,
                     [&](const std::vector<Value>& e) { ids.push_back(e.back().asInteger()); });
    ASSERT_EQ(ids.size(), 1u);
    EXPECT_EQ(ids[0], i + 1);
  }
}

TEST(Pager, RejectsGarbage) {
  EXPECT_THROW(Pager::fromBytes(std::vector<std::uint8_t>(200, 0)), FormatError);
  EXPECT_THROW(Pager::fromBytes({}), FormatError);
}

TEST(Pager, PageOutOfRangeThrows) {
  DbBuilder b;
  auto pager = Pager::fromBytes(b.build());
  EXPECT_THROW(pager.page(0), FormatError);
  EXPECT_THROW(pager.page(99), FormatError);
  EXPECT_NO_THROW(pager.page(1));
}

TEST(BTree, WrongPageTypeThrows) {
  DbBuilder b(512);
  auto idx = b.addIndexTree(indexEntries({1, 2, 3}));
  auto pager = Pager::fromBytes(b.build());
  BTreeReader r(pager);
  EXPECT_THROW(r.countTableRows(idx), FormatError);
}
